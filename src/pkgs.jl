using Base: PkgId
using CodeTracking: basepath

# A near-copy of the same method in `base/loading.jl`. However, this retains the full module path to the file.
function parse_cache_header(f::IO)
    modules = Vector{Pair{PkgId, UInt64}}()
    while true
        n = read(f, Int32)
        n == 0 && break
        sym = String(read(f, n)) # module name
        uuid = UUID((read(f, UInt64), read(f, UInt64))) # pkg UUID
        build_id = read(f, UInt64) # build UUID (mostly just a timestamp)
        push!(modules, PkgId(uuid, sym) => build_id)
    end
    totbytes = read(f, Int64) # total bytes for file dependencies
    # read the list of requirements
    # and split the list into include and requires statements
    includes = Tuple{Module, String, Float64}[]
    requires = Pair{Module, PkgId}[]
    while true
        n2 = read(f, Int32)
        n2 == 0 && break
        depname = String(read(f, n2))
        mtime = read(f, Float64)
        n1 = read(f, Int32)
        mod = (n1 == 0) ? Main : Base.root_module(modules[n1].first)
        if n1 != 0
            # determine the complete module path
            while true
                n1 = read(f, Int32)
                totbytes -= 4
                n1 == 0 && break
                submodname = String(read(f, n1))
                mod = getfield(mod, Symbol(submodname))
                totbytes -= n1
            end
        end
        if depname[1] != '\0'
            push!(includes, (mod, depname, mtime))
        end
        totbytes -= 4 + 4 + n2 + 8
    end
    @assert totbytes == 12 "header of cache file appears to be corrupt"
    # Determine which includes are included in the source-text cache.
    # These are the *.jl files that we need to track.
    srctextpos = read(f, Int64)
    if srctextpos == 0
        empty!(includes)
    else
        seek(f, srctextpos)
        keep = Set{String}()
        while !eof(f)
            filenamelen = read(f, Int32)
            filenamelen == 0 && break
            fn = String(read(f, filenamelen))
            len = read(f, UInt64)
            push!(keep, fn)
            seek(f, position(f) + len)
        end
        delids = Int[]
        for (i, inc) in enumerate(includes)
            inc[2] ∈ keep || push!(delids, i)
        end
        deleteat!(includes, delids)
    end
    return modules, (includes, requires)
end

function parse_cache_header(cachefile::String)
    io = open(cachefile, "r")
    try
        !Base.isvalid_cache_header(io) && throw(ArgumentError("Invalid header in cache file $cachefile."))
        return parse_cache_header(io)
    finally
        close(io)
    end
end

# This is an implementation of
#   filter(path->Base.stale_cachefile(sourcepath, path) !== true, paths)
# that's easier to precompile. (This is a hotspot in loading Revise.)
function filter_valid_cachefiles(sourcepath, paths)
    fpaths = String[]
    for path in paths
        if Base.stale_cachefile(sourcepath, path) !== true
            push!(fpaths, path)
        end
    end
    return fpaths
end

function pkg_fileinfo(id::PkgId)
    uuid, name = id.uuid, id.name
    # Try to find the matching cache file
    paths = Base.find_all_in_cache_path(id)
    sourcepath = Base.locate_package(id)
    if length(paths) > 1
        fpaths = filter_valid_cachefiles(sourcepath, paths)
        if isempty(fpaths)
            # Work-around for #371 (broken dependency prevents tracking):
            # find the most recent cache file. Presumably this is the one built
            # to load the package.
            sort!(paths; by=path->mtime(path), rev=true)
            deleteat!(paths, 2:length(paths))
        else
            paths = fpaths
        end
    end
    isempty(paths) && return nothing, nothing
    @assert length(paths) == 1
    path = first(paths)
    provides, includes_requires = try
        parse_cache_header(path)
    catch
        return nothing, nothing
    end
    mods_files_mtimes, _ = includes_requires
    for (pkgid, buildid) in provides
        if pkgid.uuid === uuid && pkgid.name == name
            return path, mods_files_mtimes
        end
    end
end

"""
    parentfile, included_files = modulefiles(mod::Module)

Return the `parentfile` in which `mod` was defined, as well as a list of any
other files that were `include`d to define `mod`. If this operation is unsuccessful,
`(nothing, nothing)` is returned.

All files are returned as absolute paths.
"""
function modulefiles(mod::Module)
    function keypath(filename)
        filename = fixpath(filename)
        return get(src_file_key, filename, filename)
    end
    parentfile = String(first(methods(getfield(mod, :eval))).file)
    id = PkgId(mod)
    if id.name == "Base" || Symbol(id.name) ∈ stdlib_names
        parentfile = normpath(Base.find_source_file(parentfile))
        filedata = Base._included_files
    else
        use_compiled_modules() || return nothing, nothing   # FIXME: support non-precompiled packages
        _, filedata = pkg_fileinfo(id)
    end
    filedata === nothing && return nothing, nothing
    included_files = filter(mf->mf[1] == mod, filedata)
    return keypath(parentfile), [keypath(mf[2]) for mf in included_files]
end

"""
    parse_pkg_files(id::PkgId)

This function gets called by `watch_package` and runs when a package is first loaded.
Its job is to organize the files and expressions defining the module so that later we can
detect and process revisions.
"""
function parse_pkg_files(id::PkgId)
    if !haskey(pkgdatas, id)
        pkgdatas[id] = PkgData(id)
    end
    pkgdata = pkgdatas[id]
    modsym = Symbol(id.name)
    if use_compiled_modules()
        cachefile, mods_files_mtimes = pkg_fileinfo(id)
        if cachefile !== nothing
            for (mod, fname, _) in mods_files_mtimes
                if mod === Main && !isdefined(mod, modsym)  # issue #312
                    mod = Base.root_module(PkgId(pkgdata))
                end
                fname = relpath(fname, pkgdata)
                # For precompiled packages, we can read the source later (whenever we need it)
                # from the *.ji cachefile.
                push!(pkgdata, fname=>FileInfo(mod, cachefile))
            end
            CodeTracking._pkgfiles[id] = pkgdata.info
            return srcfiles(pkgdata)
        end
    end
    # Non-precompiled package(s). Here we rely on the `include` callbacks to have
    # already populated `included_files`; all we have to do is collect the relevant
    # files.
    queue_includes!(pkgdata, id)
    return srcfiles(pkgdata)
end

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
                instantiate_sigs!(modexsigs)
                fname = relpath(fname, pkgdata)
                push!(pkgdata, fname=>FileInfo(modexsigs))
            end
            push!(delids, i)
        end
    end
    deleteat!(included_files, delids)
    CodeTracking._pkgfiles[id] = pkgdata.info
    return srcfiles(pkgdata)
end

function queue_includes(mod::Module)
    id = PkgId(mod)
    if !haskey(pkgdatas, id)
        pkgdatas[id] = PkgData(id)
    end
    pkgdata = pkgdatas[id]
    files = queue_includes!(pkgdata, id)
    if has_writable_paths(pkgdata)
        init_watching(pkgdata, files)
    end
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
    if isempty(fi.modexsigs) && !isempty(fi.cachefile)
        # Source was never parsed, get it from the precompile cache
        src = read_from_cache(pkgdata, file)
        filep = joinpath(basedir(pkgdata), file)
        filec = get(cache_file_key, filep, filep)
        topmod = first(keys(fi.modexsigs))
        if parse_source!(fi.modexsigs, src, filec, topmod) === nothing
            @error "failed to parse cache file source text for $file"
        end
        instantiate_sigs!(fi.modexsigs)
    end
    return fi
end

function maybe_add_includes_to_pkgdata!(pkgdata::PkgData, file, includes)
    for (mod, incs) in includes
        for inc in incs
            inc = joinpath(splitdir(file)[1], inc)
            hasfile = false
            for srcfile in srcfiles(pkgdata)
                if srcfile == inc
                    hasfile = true
                    break
                end
            end
            if !hasfile
                # Add the file to pkgdata
                push!(pkgdata.info.files, inc)
                fi = FileInfo(mod)
                push!(pkgdata.fileinfos, fi)
                # Parse the source of the new file
                fullfile = joinpath(basedir(pkgdata), inc)
                if isfile(fullfile)
                    parse_source!(fi.modexsigs, fullfile, mod)
                    instantiate_sigs!(fi.modexsigs; define=true)
                end
                # Add to watchlist
                init_watching(pkgdata, (inc,))
            end
        end
    end
end

function add_require(sourcefile, modcaller, idmod, modname, expr)
    expr isa Expr || return
    id = PkgId(modcaller)
    @async begin
        # If this fires when the module is first being loaded (because the dependency
        # was already loaded), Revise may not yet have the pkgdata for this package.
        while !haskey(pkgdatas, id)
            sleep(0.1)
        end
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
        expr = copy(expr)
        push!(expr.args, :(__pkguuid__ = $idmod))
        # Add the expression to the fileinfo
        exsnew = ExprsSigs()
        exsnew[expr] = nothing
        mexsnew = ModuleExprsSigs(modcaller=>exsnew)
        mexsnew, includes = eval_new!(mexsnew, fi.modexsigs)
        pkgdata.fileinfos[fileidx] = FileInfo(mexsnew, fi)
        maybe_add_includes_to_pkgdata!(pkgdata, filekey, includes)
    end
    return nothing
end

function watch_files_via_dir(dirname)
    wait_changed(dirname)  # this will block until there is a modification
    latestfiles = Pair{String,PkgId}[]
    # Check to see if we're still watching this directory
    stillwatching = haskey(watched_files, dirname)
    if stillwatching
        wf = watched_files[dirname]
        for (file, id) in wf.trackedfiles
            fullpath = joinpath(dirname, file)
            if !file_exists(fullpath)
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
    @async _watch_package(id)
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
    files = parse_pkg_files(id)
    pkgdata = pkgdatas[id]
    if has_writable_paths(pkgdata)
        init_watching(pkgdata, files)
    end
end

function has_writable_paths(pkgdata::PkgData)
    haswritable = false
    for file in srcfiles(pkgdata)
        haswritable |= iswritable(joinpath(basedir(pkgdata), file))
    end
    return haswritable
end

## Working with Pkg and code-loading

# Much of this is adapted from base/loading.jl

function manifest_file(project_file)
    if project_file isa String
        mfile = Base.project_file_manifest_path(project_file)
        if mfile isa String
            return mfile
        end
    end
    return nothing
end
manifest_file() = manifest_file(Base.active_project())

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
                path = normpath(abspath(dirname(manifest_file), path))
            elseif (m = match(Base.re_hash_to_string, line)) != nothing
                hash = Base.SHA1(m.captures[1])
            end
        end
    end
    return pkgpaths
end

manifest_paths(manifest_file::String) =
    manifest_paths!(Dict{PkgId,String}(), manifest_file)

function find_from_hash(name, uuid, hash)
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
    wait_changed(mfile)
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
                            maybe_parse_from_cache!(pkgdata, file)
                            push!(revision_queue, (pkgdata, file))
                            push!(files, file)
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
    return true
end
