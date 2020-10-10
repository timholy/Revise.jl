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
    srctextpos = read(f, Int64)
    # read the list of modules that are required to be present during loading
    # this helps us determine revision order
    required_modules = Pair{PkgId, UInt64}[]
    while true
        n = read(f, Int32)
        n == 0 && break
        sym = String(read(f, n)) # module name
        uuid = UUID((read(f, UInt64), read(f, UInt64))) # pkg UUID
        build_id = read(f, UInt64) # build id
        push!(required_modules, PkgId(uuid, sym) => build_id)
    end
    # Determine which includes are included in the source-text cache.
    # These are the *.jl files that we need to track.
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

    return modules, (includes, requires), required_modules
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
    sourcepath === nothing && return fpaths
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
        paths = isempty(fpaths) ? paths : fpaths
        # Work-around for #371 (broken dependency prevents tracking):
        # find the most recent cache file. Presumably this is the one built
        # to load the package.
        sort!(paths; by=path->mtime(path), rev=true)
    end
    isempty(paths) && return nothing, nothing, nothing
    path = first(paths)
    provides, includes_requires, required_modules = try
        parse_cache_header(path)
    catch
        return nothing, nothing, nothing
    end
    mods_files_mtimes, _ = includes_requires
    for (pkgid, buildid) in provides
        if pkgid.uuid === uuid && pkgid.name == name
            return path, mods_files_mtimes, first.(required_modules)
        end
    end
end

function parse_pkg_files(id::PkgId)
    pkgdata = get(pkgdatas, id, nothing)
    if pkgdata === nothing
        pkgdata = PkgData(id)
    end
    modsym = Symbol(id.name)
    if use_compiled_modules()
        cachefile, mods_files_mtimes, reqs = pkg_fileinfo(id)
        if cachefile !== nothing
            pkgdata.requirements = reqs
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
            return pkgdata
        end
    end
    # Non-precompiled package(s). Here we rely on the `include` callbacks to have
    # already populated `included_files`; all we have to do is collect the relevant
    # files.
    # To reduce compiler latency, use runtime dispatch for `queue_includes!`.
    # `queue_includes!` requires compilation of the whole parsing/expression-splitting infrastructure,
    # and it's better to wait to compile it until we actually need it.
    worldage[] = Base.get_world_counter()
    invoke_revisefunc(queue_includes!, pkgdata, id)
    return pkgdata
end

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
        _, filedata, reqs = pkg_fileinfo(id)
    end
    filedata === nothing && return nothing, nothing
    included_files = filter(mf->mf[1] == mod, filedata)
    return keypath(parentfile), [keypath(mf[2]) for mf in included_files]
end
