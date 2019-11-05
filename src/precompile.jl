function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    @assert precompile(Tuple{typeof(watch_manifest), String})
    @assert precompile(Tuple{typeof(watch_file), String, Int})
    @assert precompile(Tuple{Rescheduler{typeof(watch_manifest), String}})
    @assert precompile(Tuple{Rescheduler{typeof(revise_dir_queued),Tuple{String}}})
    @assert precompile(Tuple{typeof(revise)})
    @assert precompile(Tuple{typeof(setindex!), ExprsSigs, Nothing, RelocatableExpr})
    @assert precompile(Tuple{typeof(setindex!), ExprsSigs, Vector{Any}, RelocatableExpr})
    @assert precompile(Tuple{typeof(setindex!), ModuleExprsSigs, ExprsSigs, Module})
    @assert precompile(Tuple{typeof(setindex!), Dict{PkgId,PkgData}, PkgData, PkgId})
    @assert precompile(Tuple{typeof(setindex!), Dict{String,WatchList}, WatchList, String})
    # @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)), NamedTuple{(:define,),Tuple{Bool}}, typeof(Revise.methods_by_execution!), Function, CodeTrackingMethodInfo, Dict{Module,Vector{Expr}}, Frame})
    # m = bodymethod(which(methods_by_execution!, (Function, CodeTrackingMethodInfo, Dict{Module,Vector{Expr}}, Module, Expr)))
    # @assert precompile(getfield(Revise, m.name), (Bool, typeof(methods_by_execution!), Function, CodeTrackingMethodInfo, Dict{Module,Vector{Expr}}, Module, Expr))
    @assert precompile(Tuple{typeof(get_def), Method})
    # precompile(Tuple{typeof(run_backend), REPL.REPLBackend})
    # precompile(Tuple{typeof(Revise._watch_package), Base.PkgId})
    # precompile(Tuple{typeof(Revise.watch_package), Base.PkgId})
    # precompile(Tuple{typeof(Revise.sig_type_exprs), Module, Expr})

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
