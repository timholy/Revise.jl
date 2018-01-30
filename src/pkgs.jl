using Base: PkgId

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
            provides, includes_requires = Base.parse_cache_header(path)
            mods_files_mtimes, _ = includes_requires
            for (pkgid, buildid) in provides
                if pkgid.uuid === uuid && pkgid.name == id.name
                    # found the right cache file
                    for (modid, fname, _) in mods_files_mtimes
                        mod = modid.uuid === nothing && modid.name == "" ? Main : Base.root_module(modid)
                        # For precompiled packages, we can read the source later (whenever we need it)
                        # from the *.ji cachefile.
                        push!(file2modules, fname=>FileModules(mod, ModDict(), path))
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
    # files. The main trick here is that since `using` is recursive, `included_files`
    # might contain files associated with many different packages. We have to figure
    # out which correspond to `modsym`, which we do by:
    #   - checking the module in which each file is evaluated. This suffices to
    #     detect "supporting" files, i.e., those `included` within the module
    #     definition.
    #   - checking the filename. Since the "top level" file is evaluated into Main,
    #     we can't use the module-of-evaluation to find it. Here we hope that the
    #     top-level filename follows convention and matches the module. TODO?: it's
    #     possible that this needs to be supplemented with parsing.
    i = 1
    modstring = id.name
    while i <= length(included_files)
        mod, fname = included_files[i]
        modname = String(Symbol(mod))
        if startswith(modname, modstring) || endswith(fname, modstring*".jl")
            pr = parse_source(fname, mod)
            if isa(pr, Pair)
                push!(file2modules, pr)
            end
            push!(files, fname)
            deleteat!(included_files, i)
        else
            i += 1
        end
    end
    module2files[modsym] = files
    files
end

# A near-duplicate of some of the functionality of parse_pkg_files
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

function watch_files_via_dir(dirname)
    watch_file(dirname)  # this will block until there is a modification
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
    watch_package(modsym)

This function gets called via a callback registered with `Base.require`, at the completion
of module-loading by `using` or `import`.
"""
function watch_package(id::PkgId)
    # Because the callbacks are made with `invokelatest`, for reasons of performance
    # we need to make sure this function is fast to compile. By hiding the real
    # work behind a @schedule, we truncate the chain of dependency.
    @schedule _watch_package(id)
end

function _watch_package(id::PkgId)
    modsym = Symbol(id.name)
    if modsym ∈ dont_watch_pkgs
        if modsym ∉ silence_pkgs
            warn("$modsym is excluded from watching by Revise. Use Revise.silence(\"$modsym\") to quiet this warning.")
        end
        remove_from_included_files(modsym)
        return nothing
    end
    files = parse_pkg_files(id)
    process_parsed_files(files)
end
