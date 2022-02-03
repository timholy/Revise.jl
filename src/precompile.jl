module __RInternal__
ftmp() = 1
end

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    # These are blocking so don't actually call them
    precompile(Tuple{TaskThunk})
    precompile(Tuple{typeof(wait_changed), String})
    precompile(Tuple{typeof(revise_dir_queued), String})
    precompile(Tuple{typeof(revise_file_queued), PkgData, String})
    precompile(Tuple{typeof(watch_manifest), String})
    # This excludes Revise itself
    precompile(Tuple{typeof(watch_package_callback), PkgId})
    # Too complicated to bother
    precompile(Tuple{typeof(includet), String})
    precompile(Tuple{typeof(track), Module, String})
    precompile(Tuple{typeof(get_def), Method})
    precompile(Tuple{typeof(entr), Any, Vector{String}})

    watch_package(REVISE_ID)
    watch_includes(Revise, "src/Revise.jl")
    add_revise_deps(true)
    revise()
    revise_first(:(1+1))
    eval_with_signatures(__RInternal__, :(f() = 1))
    eval_with_signatures(__RInternal__, :(f2() = 1); skip_include=true)
    add_require(pathof(LoweredCodeUtils), LoweredCodeUtils, "295af30f-e4ad-537b-8983-00126c2a3abe", "Revise", :(include("somefile.jl")))
    add_require(pathof(JuliaInterpreter), JuliaInterpreter, "295af30f-e4ad-537b-8983-00126c2a3abe", "Revise", :(f(x) = 7))
    pkgdata = pkgdatas[PkgId(LoweredCodeUtils)]
    eval_require_now(pkgdata, length(pkgdata.info.files), last(pkgdata.info.files)*"__@require__", joinpath(basedir(pkgdata), last(pkgdata.info.files)), Revise, :(__RInternal__.ftmp(::Int) = 0))
    # Now empty the stores to prevent them from being serialized
    empty!(watched_files)
    empty!(watched_manifests)
    empty!(pkgdatas)
    empty!(included_files)
    return nothing
end
