const badfile = (nothing, nothing, nothing, UInt128(0))
function pkg_fileinfo(id::PkgId)
    origin = get(Base.pkgorigins, id, nothing)
    origin === nothing && return badfile
    cachepath = origin.cachepath
    cachepath === nothing && return badfile
    local checksum
    provides, includes_requires, required_modules = try
        ret = @static if VERSION ≥ v"1.11.0-DEV.683" # https://github.com/JuliaLang/julia/pull/49866
            io = open(cachepath, "r")
            checksum = Base.isvalid_cache_header(io)
            iszero(checksum) && (close(io); return badfile)
            provides, (_, includes_srcfiles_only, requires), required_modules, _... =
                Base.parse_cache_header(io, cachepath)
            close(io)
            provides, (includes_srcfiles_only, requires), required_modules
        else
            checksum = UInt64(0) # Buildid prior to v"1.12.0-DEV.764", and the `srcfiles_only` API does not take `io`
            Base.parse_cache_header(cachepath, srcfiles_only = true)
        end
        ret
    catch err
        return badfile
    end
    includes, _ = includes_requires
    for (pkgid, buildid) in provides
        if pkgid.uuid === id.uuid && pkgid.name == id.name
            return cachepath, includes, first.(required_modules), (UInt128(checksum) << 64 | buildid)
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
        cachefile, includes, reqs, buildid = pkg_fileinfo(id)
        if cachefile !== nothing
            @assert includes !== nothing
            @assert reqs !== nothing
            pkgdata.requirements = reqs
            for chi in includes
                if isdefined(Base, :maybe_loaded_precompile) && Base.maybe_loaded_precompile(id, buildid) isa Module
                    mod = Base.maybe_loaded_precompile(id, buildid)
                elseif isdefined(Base, :loaded_precompiles) && haskey(Base.loaded_precompiles, id => buildid)
                    mod = Base.loaded_precompiles[id => buildid]
                else
                    mod = Base.root_module(id)
                end
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
    if isdefined(Base, :moduleloc)
        parentfile = String(Base.moduleloc(mod).file)
    else
        parentfile = String(first(methods(getfield(mod, :eval))).file)
    end
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
