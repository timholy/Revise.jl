function pkg_fileinfo(id::PkgId)
    origin = get(Base.pkgorigins, id, nothing)
    origin === nothing && return nothing
    cachepath = origin.cachepath
    cachepath === nothing && return nothing
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
            Base.parse_cache_header(cachepath; srcfiles_only = true)
        end
        ret
    catch err
        return nothing
    end
    includes, _ = includes_requires
    for (pkgid, buildid) in provides
        if pkgid.uuid === id.uuid && pkgid.name == id.name
            return cachepath, includes, first.(required_modules), (UInt128(checksum) << 64 | buildid)
        end
    end
    return nothing
end

"""
    parse_pkg_files(id::PkgId)

This function gets called by `watch_package` and runs when a package is first loaded.
Its job is to organize the files and expressions defining the module so that later we can
detect and process revisions.
"""
function parse_pkg_files(id::PkgId)
    pkgdata = get!(()->PkgData(id), pkgdatas, id)
    if use_compiled_modules()
        cachefile_includes_reqs_buildid = pkg_fileinfo(id)
        if cachefile_includes_reqs_buildid !== nothing
            cachefile, includes, reqs, buildid = cachefile_includes_reqs_buildid
            pkgdata.requirements = reqs
            for chi in includes
                if isdefined(Base, :maybe_loaded_precompile) && (mod′ = Base.maybe_loaded_precompile(id, buildid); mod′ isa Module)
                    mod = mod′
                elseif isdefined(Base, :loaded_precompiles) && haskey(Base.loaded_precompiles, id => buildid)
                    mod = Base.loaded_precompiles[id => buildid]
                else
                    mod = Base.root_module(id)
                end
                for mpath in chi.modpath
                    mod = getglobal(mod, Symbol(mpath))::Module
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
    @invokelatest queue_includes!(pkgdata, id)
    return pkgdata
end

"""
    parentfile, included_files = modulefiles(mod::Module)

Return the `parentfile` in which `mod` was defined, as well as a list of any
other files that were `include`d to define `mod`. If this operation is unsuccessful,
`(nothing, nothing)` is returned.

All files are returned as absolute paths.
"""
function modulefiles(mod::Module)
    function keypath(filename::AbstractString)
        filename = fixpath(filename)
        return get(src_file_key, filename, filename)
    end
    @static if isdefined(Base, :moduleloc)
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
    cachefile_includes_reqs_buildid = pkg_fileinfo(id)
    cachefile_includes_reqs_buildid === nothing && return nothing, nothing
    _, includes, _, _ = cachefile_includes_reqs_buildid
    included_files = filter(mf->mf.id == id, includes)
    return keypath(parentfile), [keypath(mf.filename) for mf in included_files]
end
