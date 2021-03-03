function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    @assert precompile(Tuple{TaskThunk})
    @assert precompile(Tuple{typeof(wait_changed), String})
    @assert precompile(Tuple{typeof(watch_package), PkgId})
    @assert precompile(Tuple{typeof(_watch_package), PkgId})
    @assert precompile(Tuple{typeof(watch_includes), Module, String})
    @assert precompile(Tuple{typeof(watch_manifest), String})
    @assert precompile(Tuple{typeof(revise_dir_queued), String})
    @assert precompile(Tuple{typeof(revise_file_queued), PkgData, String})
    @assert precompile(Tuple{typeof(init_watching), PkgData, Vector{String}})
    @assert precompile(Tuple{typeof(add_revise_deps)})
    @assert precompile(Tuple{typeof(swap_watch_package), PkgId})

    @assert precompile(Tuple{typeof(revise)})
    @assert precompile(Tuple{typeof(revise_first), Expr})
    @assert precompile(Tuple{typeof(includet), String})
    @assert precompile(Tuple{typeof(track), Module, String})
    # setindex! doesn't fully precompile, but it's still beneficial to do it
    # (it shaves off a bit of the time)
    # See https://github.com/JuliaLang/julia/pull/31466
    @assert precompile(Tuple{typeof(setindex!), ExprsSigs, Nothing, RelocatableExpr})
    @assert precompile(Tuple{typeof(setindex!), ExprsSigs, Vector{Any}, RelocatableExpr})
    @assert precompile(Tuple{typeof(setindex!), ModuleExprsSigs, ExprsSigs, Module})
    @assert precompile(Tuple{typeof(setindex!), Dict{PkgId,PkgData}, PkgData, PkgId})
    @assert precompile(Tuple{Type{WatchList}})
    @assert precompile(Tuple{typeof(setindex!), Dict{String,WatchList}, WatchList, String})

    MI = CodeTrackingMethodInfo
    @assert precompile(Tuple{typeof(minimal_evaluation!), MI, Core.CodeInfo, Symbol})
    @assert precompile(Tuple{typeof(minimal_evaluation!), Any, MI, Core.CodeInfo, Symbol})
    @assert precompile(Tuple{typeof(methods_by_execution!), Any, MI, DocExprs, Module, Expr})
    @assert precompile(Tuple{typeof(methods_by_execution!), Any, MI, DocExprs, JuliaInterpreter.Frame, Vector{Bool}})
    @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode,),Tuple{Symbol}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Module, Expr})
    @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:skip_include,),Tuple{Bool}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Module, Expr})
    @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode, :skip_include),Tuple{Symbol,Bool}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Module, Expr})
    @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode,),Tuple{Symbol}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Frame, Vector{Bool}})
    @assert precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode, :skip_include),Tuple{Symbol,Bool}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Frame, Vector{Bool}})

    mex = which(methods_by_execution!, (Function, MI, DocExprs, Module, Expr))
    mbody = bodymethod(mex)
    if Sys.islinux() || Base.VERSION <= v"1.7.0-DEV"
        @assert precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, Bool, Iterators.Pairs{Union{},Union{},Tuple{},NamedTuple{(),Tuple{}}}, typeof(methods_by_execution!), Any, MI, DocExprs, Module, Expr})
        @assert precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, Bool, Iterators.Pairs{Symbol,Bool,Tuple{Symbol},NamedTuple{(:skip_include,),Tuple{Bool}}}, typeof(methods_by_execution!), Any, MI, DocExprs, Module, Expr})
    end
    mfr = which(methods_by_execution!, (Function, MI, DocExprs, Frame, Vector{Bool}))
    mbody = bodymethod(mfr)
    @assert precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, typeof(methods_by_execution!), Any, MI, DocExprs, Frame, Vector{Bool}})

    @assert precompile(Tuple{typeof(hastrackedexpr), Expr})
    @assert precompile(Tuple{typeof(get_def), Method})
    @assert precompile(Tuple{typeof(parse_pkg_files), PkgId})
    if isdefined(Revise, :filter_valid_cachefiles)
        @assert precompile(Tuple{typeof(filter_valid_cachefiles), String, Vector{String}})
    end
    @assert precompile(Tuple{typeof(pkg_fileinfo), PkgId})
    @assert precompile(Tuple{typeof(push!), WatchList, Pair{String,PkgId}})
    @assert precompile(Tuple{typeof(pushex!), ExprsSigs, Expr})
    @assert precompile(Tuple{Type{ModuleExprsSigs}, Module})
    @assert precompile(Tuple{Type{FileInfo}, Module, String})
    @assert precompile(Tuple{Type{PkgData}, PkgId})
    @assert precompile(Tuple{typeof(Base._deleteat!), Vector{Tuple{Module,String,Float64}}, Vector{Int}})
    @assert precompile(Tuple{typeof(add_require), String, Module, String, String, Expr})
    @assert precompile(Tuple{typeof(_add_require), String, Module, String, String, Expr})
    @assert precompile(Tuple{Core.kwftype(typeof(maybe_add_includes_to_pkgdata!)),NamedTuple{(:eval_now,), Tuple{Bool}},typeof(maybe_add_includes_to_pkgdata!),PkgData,String,Vector{Pair{Module, String}}})

    for TT in (Tuple{Module,Expr}, Tuple{DataType,MethodSummary})
        @assert precompile(Tuple{Core.kwftype(typeof(Base.CoreLogging.handle_message)),NamedTuple{(:time, :deltainfo), Tuple{Float64, TT}},typeof(Base.CoreLogging.handle_message),ReviseLogger,LogLevel,String,Module,String,Symbol,String,Int})
    end
    return nothing
end
