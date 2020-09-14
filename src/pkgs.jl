using Base: PkgId
using CodeTracking: basepath

if isdefined(Base, :pkgorigins)
    include("loading.jl")
else
    include("legacy_loading.jl")
end

"""
    parse_pkg_files(id::PkgId)

This function gets called by `watch_package` and runs when a package is first loaded.
Its job is to organize the files and expressions defining the module so that later we can
detect and process revisions.
"""
parse_pkg_files(id::PkgId)

"""
    parentfile, included_files = modulefiles(mod::Module)

Return the `parentfile` in which `mod` was defined, as well as a list of any
other files that were `include`d to define `mod`. If this operation is unsuccessful,
`(nothing, nothing)` is returned.

All files are returned as absolute paths.
"""
modulefiles(mod::Module)

# This is primarily used to parse non-precompilable packages.
# These lack a cache header that lists the files that constitute the package;
# they also lack the source cache, and so have to parsed immediately or
# we won't be able to compute a diff when a file is modified (we don't have a record
# of what the source was before the modification).
#
# The main trick here is that since `using` is recursive, `included_files`
# might contain files associated with many different packages. We have to figure
# out which correspond to a particular module `mod`, which we do by:
#   - checking the module in which each file is evaluated. This suffices to
#     detect "supporting" files, i.e., those `included` within the module
#     definition.
#   - checking the filename. Since the "top level" file is evaluated into Main,
#     we can't use the module-of-evaluation to find it. Here we hope that the
#     top-level filename follows convention and matches the module. TODO?: it's
#     possible that this needs to be supplemented with parsing.
function queue_includes!(pkgdata::PkgData, id::PkgId)
    modstring = id.name
    delids = Int[]
    for i = 1:length(included_files)
        mod, fname = included_files[i]
        if mod == Base.__toplevel__
            mod = Main
        end
        modname = String(Symbol(mod))
        if startswith(modname, modstring) || endswith(fname, modstring*".jl")
            modexsigs = parse_source(fname, mod)
            if modexsigs !== nothing
                fname = relpath(fname, pkgdata)
                push!(pkgdata, fname=>FileInfo(modexsigs))
            end
            push!(delids, i)
        end
    end
    deleteat!(included_files, delids)
    CodeTracking._pkgfiles[id] = pkgdata.info
    return pkgdata
end

function queue_includes(mod::Module)
    id = PkgId(mod)
    pkgdata = get(pkgdatas, id, nothing)
    if pkgdata === nothing
        pkgdata = PkgData(id)
    end
    queue_includes!(pkgdata, id)
    if has_writable_paths(pkgdata)
        init_watching(pkgdata)
    end
    pkgdatas[id] = pkgdata
    return pkgdata
end

# A near-duplicate of some of the functionality of queue_includes!
# This gets called for silenced packages, to make sure they don't "contaminate"
# included_files
function remove_from_included_files(modsym::Symbol)
    i = 1
    modstring = string(modsym)
    while i <= length(included_files)
        mod, fname = included_files[i]
        modname = String(Symbol(mod))
        if startswith(modname, modstring) || endswith(fname, modstring*".jl")
            deleteat!(included_files, i)
        else
            i += 1
        end
    end
end

function read_from_cache(pkgdata::PkgData, file::AbstractString)
    fi = fileinfo(pkgdata, file)
    filep = joinpath(basedir(pkgdata), file)
    if fi.cachefile == basesrccache
        # Get the original path
        filec = get(cache_file_key, filep, filep)
        return open(basesrccache) do io
            Base._read_dependency_src(io, filec)
        end
    end
    Base.read_dependency_src(fi.cachefile, filep)
end

function maybe_parse_from_cache!(pkgdata::PkgData, file::AbstractString)
    if startswith(file, "REPL[")
        return add_definitions_from_repl(file)
    end
    fi = fileinfo(pkgdata, file)
    if isempty(fi.modexsigs) && (!isempty(fi.cachefile) || !isempty(fi.cacheexprs))
        # Source was never parsed, get it from the precompile cache
        src = read_from_cache(pkgdata, file)
        filep = joinpath(basedir(pkgdata), file)
        filec = get(cache_file_key, filep, filep)
        topmod = first(keys(fi.modexsigs))
        if parse_source!(fi.modexsigs, src, filec, topmod) === nothing
            @error "failed to parse cache file source text for $file"
        end
        for (mod, rex) in fi.cacheexprs
            exsigs = get(fi.modexsigs, mod, nothing)
            if exsigs === nothing
                fi.modexsigs[mod] = exsigs = ExprsSigs()
            end
            pushex!(exsigs, rex)
        end
        empty!(fi.cacheexprs)
    end
    return fi
end

function maybe_extract_sigs!(fi::FileInfo)
    if !fi.extracted[]
        instantiate_sigs!(fi.modexsigs)
        fi.extracted[] = true
    end
    return fi
end
maybe_extract_sigs!(pkgdata::PkgData, file::AbstractString) = maybe_extract_sigs!(fileinfo(pkgdata, file))

function maybe_add_includes_to_pkgdata!(pkgdata::PkgData, file, includes)
    for (mod, inc) in includes
        inc = joinpath(splitdir(file)[1], inc)
        incrp = relpath(inc, pkgdata)
        hasfile = false
        for srcfile in srcfiles(pkgdata)
            if srcfile == incrp
                hasfile = true
                break
            end
        end
        if !hasfile
            # Add the file to pkgdata
            push!(pkgdata.info.files, incrp)
            fi = FileInfo(mod)
            push!(pkgdata.fileinfos, fi)
            # Parse the source of the new file
            fullfile = joinpath(basedir(pkgdata), incrp)
            if isfile(fullfile)
                parse_source!(fi.modexsigs, fullfile, mod)
                instantiate_sigs!(fi.modexsigs; mode=:eval)
            end
            # Add to watchlist
            init_watching(pkgdata, (incrp,))
        end
    end
end

function add_require(sourcefile::String, modcaller::Module, idmod::String, modname::String, expr::Expr)
    expr isa Expr || return
    arthunk = TaskThunk(_add_require, (sourcefile, modcaller, idmod, modname, expr))
    schedule(Task(arthunk))
    return nothing
end

# Use locking to prevent races between inner and outer @require blocks
const requires_lock = ReentrantLock()

function _add_require(sourcefile, modcaller, idmod, modname, expr)
    id = PkgId(modcaller)
    # If this fires when the module is first being loaded (because the dependency
    # was already loaded), Revise may not yet have the pkgdata for this package.
    while !haskey(pkgdatas, id)
        sleep(0.1)
    end

    lock(requires_lock)
    try
        # Get/create the FileInfo specifically for tracking @require blocks
        pkgdata = pkgdatas[id]
        filekey = relpath(sourcefile, pkgdata) * "__@require__"
        fileidx = fileindex(pkgdata, filekey)
        if fileidx === nothing
            files = srcfiles(pkgdata)
            fileidx = length(files) + 1
            push!(files, filekey)
            push!(pkgdata.fileinfos, FileInfo(modcaller))
        end
        fi = pkgdata.fileinfos[fileidx]
        # Tag the expr to ensure it is unique
        expr = Expr(:block, copy(expr))
        push!(expr.args, :(__pkguuid__ = $idmod))
        # Add the expression to the fileinfo
        if isempty(fi.modexsigs) && !has_include(expr)
            push!(fi.cacheexprs, (modcaller, expr))
        else
            Base.invokelatest(eval_require_now, pkgdata, fileidx, filekey, sourcefile, modcaller, expr)
        end
    finally
        unlock(requires_lock)
    end
end

# Scan for `include` statements without paying a big compile-time cost
function has_include(expr::Expr)
    if expr.head === :call
        if length(expr.args) >= 1
            if expr.args[1] === :include
                return true
            end
        end
        # Any eval statement is suspicious
        callee = expr.args[1]
        if callee === :eval || (isa(callee, Expr) && callee.head === :. && is_quotenode_egal(callee.args[2], :eval))
            return false
        end
    end
    expr.head === :macrocall && expr.args[1] === Symbol("@eval") && return true
    for a in expr.args
        a isa Expr || continue
        has_include(a) && return true
    end
    return false
end

function eval_require_now(pkgdata::PkgData, fileidx::Int, filekey::String, sourcefile::String, modcaller::Module, expr::Expr)
    fi = pkgdata.fileinfos[fileidx]
    exsnew = ExprsSigs()
    exsnew[expr] = nothing
    mexsnew = ModuleExprsSigs(modcaller=>exsnew)
    # Before executing the expression we need to set the load path appropriately
    prev = Base.source_path(nothing)
    tls = task_local_storage()
    tls[:SOURCE_PATH] = sourcefile
    # Now execute the expression
    mexsnew, includes = try
        eval_new!(mexsnew, fi.modexsigs)
    finally
        if prev === nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    end
    # Add any new methods or `include`d files to tracked objects
    pkgdata.fileinfos[fileidx] = FileInfo(mexsnew, fi)
    ret = maybe_add_includes_to_pkgdata!(pkgdata, filekey, includes)
    return ret
end

function watch_files_via_dir(dirname)
    try
        wait_changed(dirname)  # this will block until there is a modification
    catch e
        # issue #459
        (isa(e, InterruptException) && throwto_repl(e)) || throw(e)
    end
    latestfiles = Pair{String,PkgId}[]
    # Check to see if we're still watching this directory
    stillwatching = haskey(watched_files, dirname)
    if stillwatching
        wf = watched_files[dirname]
        for (file, id) in wf.trackedfiles
            fullpath = joinpath(dirname, file)
            if isdir(fullpath)
                # Detected a modification in a directory that we're watching in
                # itself (not as a container for watched files)
                push!(latestfiles, file=>id)
                continue
            elseif !file_exists(fullpath)
                # File may have been deleted. But be very sure.
                sleep(0.1)
                if !file_exists(fullpath)
                    push!(latestfiles, file=>id)
                    continue
                end
            end
            if newer(mtime(fullpath), wf.timestamp)
                push!(latestfiles, file=>id)
            end
        end
        isempty(latestfiles) || updatetime!(wf)  # ref issue #341
    end
    return latestfiles, stillwatching
end

"""
    watch_package(id::Base.PkgId)

Start watching a package for changes to the files that define it.
This function gets called via a callback registered with `Base.require`, at the completion
of module-loading by `using` or `import`.
"""
function watch_package(id::PkgId)
    # Because the callbacks are made with `invokelatest`, for reasons of performance
    # we need to make sure this function is fast to compile. By hiding the real
    # work behind a @async, we truncate the chain of dependency.
    schedule(Task(TaskThunk(_watch_package, (id,))))
    sleep(0.001)
end

@noinline function _watch_package(id::PkgId)
    modsym = Symbol(id.name)
    if modsym ∈ dont_watch_pkgs
        if modsym ∉ silence_pkgs
            @warn "$modsym is excluded from watching by Revise. Use Revise.silence(\"$modsym\") to quiet this warning."
        end
        remove_from_included_files(modsym)
        return nothing
    end
    pkgdata = parse_pkg_files(id)
    if has_writable_paths(pkgdata)
        init_watching(pkgdata, srcfiles(pkgdata))
    end
    pkgdatas[id] = pkgdata
end

function has_writable_paths(pkgdata::PkgData)
    haswritable = false
    for file in srcfiles(pkgdata)
        haswritable |= iswritable(joinpath(basedir(pkgdata), file))
    end
    return haswritable
end

function watch_includes(mod::Module, fn::AbstractString)
    push!(included_files, (mod, normpath(abspath(fn))))
end

## Working with Pkg and code-loading

# Much of this is adapted from base/loading.jl

function manifest_file(project_file)
    if project_file isa String
        mfile = @static if isdefined(Base, :TOMLCache)
            Base.project_file_manifest_path(project_file, Base.TOMLCache())
        else
            Base.project_file_manifest_path(project_file)
        end
        if mfile isa String
            return mfile
        end
    end
    return nothing
end
manifest_file() = manifest_file(Base.active_project())

if isdefined(Base, :TOMLCache)
function manifest_paths!(pkgpaths::Dict, manifest_file::String)
    c = Base.TOMLCache()
    d = Base.parsed_toml(c, manifest_file)
    for (name, entries) in d
        entries::Vector{Any}
        for info in entries
            name::String
            info::Dict{String, Any}
            uuid = UUID(info["uuid"]::String)
            hash = get(info, "git-tree-sha1", nothing)::Union{String, Nothing}
            path = nothing
            if hash !== nothing
                path = find_from_hash(name, uuid, Base.SHA1(hash))
                path === nothing && error("no path found for $id and hash $hash")
            end
            maybe_path = get(info, "path", nothing)::Union{String, Nothing}
            if maybe_path !== nothing
                path = abspath(dirname(manifest_file), maybe_path)
            end
            if path !== nothing
                pkgpaths[PkgId(Base.UUID(uuid), name)] = path
            end
        end
    end
    return pkgpaths
end
else
function manifest_paths!(pkgpaths::Dict, manifest_file::String)
    open(manifest_file) do io
        uuid = name = path = hash = id = nothing
        for line in eachline(io)
            if (m = match(Base.re_section_capture, line)) != nothing
                name = String(m.captures[1])
                path = hash = nothing
            elseif (m = match(Base.re_uuid_to_string, line)) != nothing
                uuid = UUID(m.captures[1])
                name === nothing && error("name not set for $uuid")
                id = PkgId(uuid, name)
                # UUID is last, so time to store
                if path !== nothing
                    pkgpaths[id] = path
                elseif hash !== nothing
                    path = find_from_hash(name, uuid, hash)
                    path === nothing && error("no path found for $id and hash $hash")
                    pkgpaths[id] = path
                end
                uuid = name = path = hash = id = nothing
            elseif (m = match(Base.re_path_to_string, line)) != nothing
                path = String(m.captures[1])
                path = abspath(dirname(manifest_file), path)
            elseif (m = match(Base.re_hash_to_string, line)) != nothing
                hash = Base.SHA1(m.captures[1])
            end
        end
    end
    return pkgpaths
end
end

manifest_paths(manifest_file::String) =
    manifest_paths!(Dict{PkgId,String}(), manifest_file)

function find_from_hash(name::String, uuid::Base.UUID, hash::Base.SHA1)
    for slug in (Base.version_slug(uuid, hash, 4), Base.version_slug(uuid, hash))
        for depot in DEPOT_PATH
            path = abspath(depot, "packages", name, slug)
            if ispath(path)
                return path
            end
        end
    end
    return nothing
end

function watch_manifest(mfile)
    while true
        try
            wait_changed(mfile)
        catch e
            # issue #459
            (isa(e, InterruptException) && throwto_repl(e)) || throw(e)
        end
        try
            with_logger(_debug_logger) do
                @debug "Pkg" _group="manifest_update" manifest_file=mfile
                isfile(mfile) || return nothing
                pkgdirs = manifest_paths(mfile)
                for (id, pkgdir) in pkgdirs
                    if haskey(pkgdatas, id)
                        pkgdata = pkgdatas[id]
                        if pkgdir != basedir(pkgdata)
                            ## The package directory has changed
                            @debug "Pkg" _group="pathswitch" oldpath=basedir(pkgdata) newpath=pkgdir
                            # Stop all associated watching tasks
                            for dir in unique_dirs(srcfiles(pkgdata))
                                @debug "Pkg" _group="unwatch" dir=dir
                                delete!(watched_files, joinpath(basedir(pkgdata), dir))
                                # Note: if the file is revised, the task(s) will run one more time.
                                # However, because we've removed the directory from the watch list this will be a no-op,
                                # and then the tasks will be dropped.
                            end
                            # Revise code as needed
                            files = String[]
                            for file in srcfiles(pkgdata)
                                maybe_extract_sigs!(maybe_parse_from_cache!(pkgdata, file))
                                push!(revision_queue, (pkgdata, file))
                                push!(files, file)
                                notify(revision_event)
                            end
                            # Update the directory
                            pkgdata.info.basedir = pkgdir
                            # Restart watching, if applicable
                            if has_writable_paths(pkgdata)
                                init_watching(pkgdata, files)
                            end
                        end
                    end
                end
            end
        catch err
            @static if VERSION >= v"1.2.0-DEV.253"
                put!(Base.active_repl_backend.response_channel, (Base.catch_stack(), true))
            else
                put!(Base.active_repl_backend.response_channel, (err, catch_backtrace()))
            end
        end
    end
end
