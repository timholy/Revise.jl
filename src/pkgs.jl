using Base: PkgId

# A near-copy of `base/loading.jl`. However, this retains the full module path to the file.
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

"""
    parse_pkg_files(modsym)

This function gets called by `watch_package` and runs when a package is first loaded.
Its job is to organize the files and expressions defining the module so that later we can
detect and process revisions.
"""
function parse_pkg_files(id::PkgId)
    files = String[]
    modsym = Symbol(id.name)
    if use_compiled_modules()
        # We probably got the top-level file from the precompile cache
        # Try to find the matching cache file
        uuid = id.uuid
        paths = Base.find_all_in_cache_path(id)
        for path in paths
            provides, includes_requires = parse_cache_header(path)
            mods_files_mtimes, _ = includes_requires
            for (pkgid, buildid) in provides
                if pkgid.uuid === uuid && pkgid.name == id.name
                    # found the right cache file
                    for (mod, fname, _) in mods_files_mtimes
                        # For precompiled packages, we can read the source later (whenever we need it)
                        # from the *.ji cachefile.
                        fileinfos[fname] = FileInfo(mod, path)
                        push!(files, fname)
                        module2files[modsym] = files
                    end
                    return files
                end
            end
        end
    end
    # Non-precompiled package(s). Here we rely on the `include` callbacks to have
    # already populated `included_files`; all we have to do is collect the relevant
    # files.
    queue_includes!(files, id.name)
    module2files[modsym] = files
    files
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
function queue_includes!(files, modstring)
    delids = Int[]
    for i = 1:length(included_files)
        mod, fname = included_files[i]
        modname = String(Symbol(mod))
        if startswith(modname, modstring) || endswith(fname, modstring*".jl")
            fm = parse_source(fname, mod)
            instantiate_sigs!(fm)
            if fm != nothing
                fileinfos[fname] = FileInfo(fm)
            end
            push!(files, fname)
            push!(delids, i)
        end
    end
    deleteat!(included_files, delids)
    return files
end

function queue_includes(mod::Module)
    files = queue_includes!(String[], String(Symbol(mod)))
    init_watching(files)
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

function read_from_cache(fi::FileInfo, file::AbstractString)
    if fi.cachefile == basesrccache
        # Get the original path
        filec = get(cache_file_key, file, file)
        return open(basesrccache) do io
            Base._read_dependency_src(io, filec)
        end
    end
    Base.read_dependency_src(fi.cachefile, file)
end

function maybe_parse_from_cache!(fi::FileInfo, file::AbstractString)
    if isempty(fi.fm)
        # Source was never parsed, get it from the precompile cache
        src = read_from_cache(fi, file)
        topmod = first(keys(fi.fm))
        if parse_source!(fi.fm, src, Symbol(file), 1, topmod) === nothing
            @error "failed to parse cache file source text for $file"
        end
        instantiate_sigs!(fi.fm)
    end
    return fi
end

function watch_files_via_dir(dirname)
    wait_changed(dirname)  # this will block until there is a modification
    latestfiles = String[]
    wf = watched_files[dirname]
    for file in wf.trackedfiles
        path = joinpath(dirname, file)
        if mtime(path) + 1 >= floor(wf.timestamp) # OSX rounds mtime up, see #22
            push!(latestfiles, path)
        end
    end
    updatetime!(wf)
    latestfiles
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

function _watch_package(id::PkgId)
    modsym = Symbol(id.name)
    if modsym ∈ dont_watch_pkgs
        if modsym ∉ silence_pkgs
            @warn "$modsym is excluded from watching by Revise. Use Revise.silence(\"$modsym\") to quiet this warning."
        end
        remove_from_included_files(modsym)
        return nothing
    end
    files = parse_pkg_files(id)
    init_watching(files)
end
