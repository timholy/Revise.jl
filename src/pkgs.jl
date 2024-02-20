using Base: PkgId

include("loading.jl")

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
        add_modexs!(fi, fi.cacheexprs)
        empty!(fi.cacheexprs)
    end
    return fi
end

function add_modexs!(fi::FileInfo, modexs)
    for (mod, rex) in modexs
        exsigs = get(fi.modexsigs, mod, nothing)
        if exsigs === nothing
            fi.modexsigs[mod] = exsigs = ExprsSigs()
        end
        pushex!(exsigs, rex)
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

function maybe_add_includes_to_pkgdata!(pkgdata::PkgData, file::AbstractString, includes; eval_now::Bool=false)
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
                if eval_now
                    # Use runtime dispatch to reduce latency
                    Base.invokelatest(instantiate_sigs!, fi.modexsigs; mode=:eval)
                end
            end
            # Add to watchlist
            init_watching(pkgdata, (incrp,))
            yield()
        end
    end
end

# Use locking to prevent races between inner and outer @require blocks
const requires_lock = ReentrantLock()

function add_require(sourcefile::String, modcaller::Module, idmod::String, modname::String, expr::Expr)
    id = PkgId(modcaller)
    # If this fires when the module is first being loaded (because the dependency
    # was already loaded), Revise may not yet have the pkgdata for this package.
    if !haskey(pkgdatas, id)
        watch_package(id)
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
        complex = true     # is this too complex to delay?
        if !fi.extracted[]
            # If we haven't yet extracted signatures, do our best to avoid it now in case the
            # signature-extraction code has not yet been compiled (latency reduction)
            includes, complex = deferrable_require(expr)
            if !complex
                # [(modcaller, inc) for inc in includes] but without precompiling a Generator
                modincludes = Tuple{Module,String}[]
                for inc in includes
                    push!(modincludes, (modcaller, inc))
                end
                maybe_add_includes_to_pkgdata!(pkgdata, filekey, modincludes)
                if isempty(fi.modexsigs)
                    # Source has not even been parsed
                    push!(fi.cacheexprs, (modcaller, expr))
                else
                    add_modexs!(fi, [(modcaller, expr)])
                end
            end
        end
        if complex
            Base.invokelatest(eval_require_now, pkgdata, fileidx, filekey, sourcefile, modcaller, expr)
        end
    finally
        unlock(requires_lock)
    end
end

function deferrable_require(expr)
    includes = String[]
    complex = deferrable_require!(includes, expr)
    return includes, complex
end
function deferrable_require!(includes, expr::Expr)
    if expr.head === :call
        callee = expr.args[1]
        if callee === :include
            if isa(expr.args[2], AbstractString)
                push!(includes, expr.args[2])
            else
                return true
            end
        elseif callee === :eval || (isa(callee, Expr) && callee.head === :. && is_quotenode_egal(callee.args[2], :eval))
            # Any eval statement is suspicious and requires immediate action
            return false
        end
    end
    expr.head === :macrocall && expr.args[1] === Symbol("@eval") && return true
    for a in expr.args
        a isa Expr || continue
        deferrable_require!(includes, a) && return true
    end
    return false
end

function eval_require_now(pkgdata::PkgData, fileidx::Int, filekey::String, sourcefile::String, modcaller::Module, expr::Expr)
    fi = pkgdata.fileinfos[fileidx]
    exsnew = ExprsSigs()
    exsnew[RelocatableExpr(expr)] = nothing
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
    ret = maybe_add_includes_to_pkgdata!(pkgdata, filekey, includes; eval_now=true)
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

const wplock = ReentrantLock()

"""
    watch_package(id::Base.PkgId)

Start watching a package for changes to the files that define it.
This function gets called via a callback registered with `Base.require`, at the completion
of module-loading by `using` or `import`.
"""
function watch_package(id::PkgId)
    # we may have switched environments, so make sure we're watching the right manifest
    active_project_watcher()

    pkgdata = get(pkgdatas, id, nothing)
    pkgdata !== nothing && return pkgdata
    lock(wplock)
    try
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
    finally
        unlock(wplock)
    end
    return pkgdata
end

function has_writable_paths(pkgdata::PkgData)
    dir = basedir(pkgdata)
    isdir(dir) || return true
    haswritable = false
    # Compatibility note:
    # The following can be written in cd(dir) do ... end block
    # but that would trigger Julia to crash for some corner cases.
    # This is identified on Julia 1.7.3 + modified ubuntu 18.04, and it is
    # verified that doesn't happen for Julia 1.9.2 on the same machine.
    current_dir = pwd()
    try
        cd(dir)
        for file in srcfiles(pkgdata)
            haswritable |= iswritable(file)
        end
    finally
        cd(current_dir)
    end
    return haswritable
end

function watch_includes(mod::Module, fn::AbstractString)
    push!(included_files, (mod, normpath(abspath(fn))))
end

## Working with Pkg and code-loading

# Much of this is adapted from base/loading.jl

function manifest_file(project_file)
    if project_file isa String && isfile(project_file)
        mfile = Base.project_file_manifest_path(project_file)
        if mfile isa String
            return mfile
        end
    end
    return nothing
end
manifest_file() = manifest_file(Base.active_project())

function manifest_paths!(pkgpaths::Dict, manifest_file::String)
    d = if isdefined(Base, :get_deps) # `get_deps` is present in versions that support new manifest formats
        Base.get_deps(Base.parsed_toml(manifest_file))
    else
        Base.parsed_toml(manifest_file)
    end
    for (name, entries) in d
        entries::Vector{Any}
        for entry in entries
            id = PkgId(UUID(entry["uuid"]::String), name)
            path = Base.explicit_manifest_entry_path(manifest_file, id, entry)
            if path !== nothing
                if isfile(path)
                    # Workaround for #802
                    path = dirname(dirname(path))
                end
                pkgpaths[id] = path
            end
        end
    end
    return pkgpaths
end

manifest_paths(manifest_file::String) =
    manifest_paths!(Dict{PkgId,String}(), manifest_file)

function watch_manifest(mfile)
    while true
        try
            wait_changed(mfile)
        catch e
            # issue #459
            (isa(e, InterruptException) && throwto_repl(e)) || throw(e)
        end
        manifest_file() == mfile || continue   # process revisions only if this is the active manifest
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
                            mustnotify = false
                            for file in srcfiles(pkgdata)
                                fi = try
                                    maybe_parse_from_cache!(pkgdata, file)
                                catch err
                                    # https://github.com/JuliaLang/julia/issues/42404
                                    # Get the source-text from the package source instead
                                    fi = fileinfo(pkgdata, file)
                                    if isempty(fi.modexsigs) && (!isempty(fi.cachefile) || !isempty(fi.cacheexprs))
                                        filep = joinpath(basedir(pkgdata), file)
                                        src = read(filep, String)
                                        topmod = first(keys(fi.modexsigs))
                                        if parse_source!(fi.modexsigs, src, filep, topmod) === nothing
                                            @error "failed to parse source text for $filep"
                                        end
                                        add_modexs!(fi, fi.cacheexprs)
                                        empty!(fi.cacheexprs)
                                    end
                                    fi
                                end
                                maybe_extract_sigs!(fi)
                                push!(revision_queue, (pkgdata, file))
                                push!(files, file)
                                mustnotify = true
                            end
                            mustnotify && notify(revision_event)
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
            @error "Error watching manifest" exception=(err, trim_toplevel!(catch_backtrace()))
        end
    end
end

function active_project_watcher()
    mfile = manifest_file()
    if !isnothing(mfile) && mfile ∉ watched_manifests
        push!(watched_manifests, mfile)
        wmthunk = TaskThunk(watch_manifest, (mfile,))
        schedule(Task(wmthunk))
    end
    return
end
