function pkg_fileinfo(id::PkgId)
    origin = get(Base.pkgorigins, id, nothing)
    origin === nothing && return nothing, nothing, nothing
    cachepath = origin.cachepath
    cachepath === nothing && return nothing, nothing, nothing
    provides, includes_requires, required_modules = try
        @static if VERSION ≥ v"1.11.0-DEV.683" # https://github.com/JuliaLang/julia/pull/49866
            provides, (_, includes_srcfiles_only, requires), required_modules, _... =
                Base.parse_cache_header(cachepath)
            provides, (includes_srcfiles_only, requires), required_modules
        else
            Base.parse_cache_header(cachepath, srcfiles_only = true)
        end
    catch
        return nothing, nothing, nothing
    end
    includes, _ = includes_requires
    for (pkgid, buildid) in provides
        if pkgid.uuid === id.uuid && pkgid.name == id.name
            return cachepath, includes, first.(required_modules)
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
        cachefile, includes, reqs = pkg_fileinfo(id)
        if cachefile !== nothing
            @assert includes !== nothing
            @assert reqs !== nothing
            pkgdata.requirements = reqs
            for chi in includes
                mod = Base.root_module(id)
                for mpath in chi.modpath
                    mod = getfield(mod, Symbol(mpath))::Module
                end
                fname = relpath(chi.filename, pkgdata)
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
    Base.invokelatest(queue_includes!, pkgdata, id)
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
        if !startswith(parentfile, juliadir)
            parentfile = replace(parentfile, fallback_juliadir()=>juliadir)
        end
        filedata = Base._included_files
        included_files = filter(mf->mf[1] == mod, filedata)
        return keypath(parentfile), [keypath(mf[2]) for mf in included_files]
    end
    use_compiled_modules() || return nothing, nothing   # FIXME: support non-precompiled packages
    _, filedata, reqs = pkg_fileinfo(id)
    filedata === nothing && return nothing, nothing
    included_files = filter(mf->mf.id == id, filedata)
    return keypath(parentfile), [keypath(mf.filename) for mf in included_files]
end
