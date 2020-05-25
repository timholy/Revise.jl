function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    @assert precompile(Tuple{typeof(watch_manifest), String})
    @assert precompile(Tuple{typeof(revise_dir_queued), String})
    @assert precompile(Tuple{TaskThunk})
    @assert precompile(Tuple{typeof(revise)})
    @assert precompile(Tuple{typeof(includet), String})
    # setindex! doesn't fully precompile, but it's still beneficial to do it
    # (it shaves off a bit of the time)
    # See https://github.com/JuliaLang/julia/pull/31466
    @assert precompile(Tuple{typeof(setindex!), ExprsSigs, Nothing, RelocatableExpr})
    @assert precompile(Tuple{typeof(setindex!), ExprsSigs, Vector{Any}, RelocatableExpr})
    @assert precompile(Tuple{typeof(setindex!), ModuleExprsSigs, ExprsSigs, Module})
    @assert precompile(Tuple{typeof(setindex!), Dict{PkgId,PkgData}, PkgData, PkgId})
    @assert precompile(Tuple{typeof(setindex!), Dict{String,WatchList}, WatchList, String})

    MI = CodeTrackingMethodInfo
    @assert precompile(Tuple{typeof(minimal_evaluation!), MI, Core.CodeInfo})
    @assert precompile(Tuple{typeof(methods_by_execution!), Any, MI, DocExprs, Module, Expr})
    @assert precompile(Tuple{typeof(methods_by_execution!), Any, MI, DocExprs, JuliaInterpreter.Frame, Vector{Bool}})
    @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                            NamedTuple{(:skip_include,),Tuple{Bool}},
                            typeof(methods_by_execution!), Function, MI, DocExprs, Module, Expr})
    @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                            NamedTuple{(:define, :skip_include),Tuple{Bool,Bool}},
                            typeof(methods_by_execution!), Function, MI, DocExprs, Module, Expr})
    @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                            NamedTuple{(:define, :skip_include),Tuple{Bool,Bool}},
                            typeof(methods_by_execution!), Function, MI, DocExprs, JuliaInterpreter.Frame, Vector{Bool}})

    @assert precompile(Tuple{typeof(get_def), Method})
    @assert precompile(Tuple{typeof(parse_pkg_files), PkgId})
    @assert precompile(Tuple{typeof(Base.stale_cachefile), String, String})
    @assert precompile(Tuple{typeof(filter_valid_cachefiles), String, Vector{String}})
    @assert precompile(Tuple{typeof(pkg_fileinfo), PkgId})
    @assert precompile(Tuple{typeof(push!), WatchList, Pair{String,PkgId}})
    @assert precompile(Tuple{typeof(init_watching), PkgData, Vector{String}})
    @assert precompile(Tuple{Type{ModuleExprsSigs}, Module})
    @assert precompile(Tuple{Type{FileInfo}, Module, String})
    @assert precompile(Tuple{Type{PkgData}, PkgId})
    @assert precompile(Tuple{typeof(Base._deleteat!), Vector{Tuple{Module,String,Float64}}, Vector{Int}})

    @assert precompile(Tuple{typeof(track), Module, String})
    @assert precompile(Tuple{typeof(add_require), String, Module, String, String, Expr})
    @assert precompile(Tuple{typeof(_add_require), String, Module, String, String, Expr})
    return nothing
end
