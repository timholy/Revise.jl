function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    # precompile(Tuple{typeof(watch_manifest), String})
    # precompile(Tuple{typeof(run_backend), REPL.REPLBackend})
    # precompile(Tuple{typeof(Revise._watch_package), Base.PkgId})
    # precompile(Tuple{typeof(Revise.watch_package), Base.PkgId})
    # precompile(Tuple{typeof(Revise.sig_type_exprs), Module, Expr})
    # precompile(Tuple{Rescheduler{typeof(revise_dir_queued),Tuple{PkgData,String}}})

    # # Here are other methods that require >10ms for inference but which do
    # # not successfully precompile
    # for dct in (watched_files, pkgdatas)
    #     precompile(Tuple{typeof(setindex!), typeof(dct), valtype(dct), keytype(dct)})
    # end
    # precompile(Tuple{typeof(setindex!), ModuleExprsSigs, FMMaps, Module})
    # precompile(Tuple{typeof(setindex!), Dict{String,FileInfo}, FileInfo, String})
    # precompile(Tuple{typeof(watch_file), String, Int})
    # precompile(Tuple{typeof(empty!), Dict{Tuple{PkgData,String},Nothing}})

    return nothing
end
