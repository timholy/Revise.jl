# COV_EXCL_START
macro warnpcfail(ex::Expr)
    modl = __module__
    file = __source__.file === nothing ? "?" : String(__source__.file)
    line = __source__.line
    quote
        $(esc(ex)) || @warn """precompile directive
     $($(Expr(:quote, ex)))
 failed. Please report an issue in $($modl) (after checking for duplicates) or remove this directive.""" _file=$file _line=$line
    end
end

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    @warnpcfail precompile(Tuple{TaskThunk})
    @warnpcfail precompile(Tuple{typeof(wait_changed), String})
    @warnpcfail precompile(Tuple{typeof(watch_package), PkgId})
    @warnpcfail precompile(Tuple{typeof(watch_includes), Module, String})
    @warnpcfail precompile(Tuple{typeof(watch_manifest), String})
    @warnpcfail precompile(Tuple{typeof(revise_dir_queued), String})
    @warnpcfail precompile(Tuple{typeof(revise_file_queued), PkgData, String})
    @warnpcfail precompile(Tuple{typeof(init_watching), PkgData, Vector{String}})
    @warnpcfail precompile(Tuple{typeof(add_revise_deps)})
    @warnpcfail precompile(Tuple{typeof(watch_package_callback), PkgId})

    @warnpcfail precompile(Tuple{typeof(revise)})
    @warnpcfail precompile(Tuple{typeof(revise_first), Expr})
    @warnpcfail precompile(Tuple{typeof(includet), String})
    @warnpcfail precompile(Tuple{typeof(track), Module, String})
    # setindex! doesn't fully precompile, but it's still beneficial to do it
    # (it shaves off a bit of the time)
    # See https://github.com/JuliaLang/julia/pull/31466
    @warnpcfail precompile(Tuple{typeof(setindex!), ExprsSigs, Nothing, RelocatableExpr})
    @warnpcfail precompile(Tuple{typeof(setindex!), ExprsSigs, Vector{Any}, RelocatableExpr})
    @warnpcfail precompile(Tuple{typeof(setindex!), ModuleExprsSigs, ExprsSigs, Module})
    @warnpcfail precompile(Tuple{typeof(setindex!), Dict{PkgId,PkgData}, PkgData, PkgId})
    @warnpcfail precompile(Tuple{Type{WatchList}})
    @warnpcfail precompile(Tuple{typeof(setindex!), Dict{String,WatchList}, WatchList, String})

    MI = CodeTrackingMethodInfo
    @warnpcfail precompile(Tuple{typeof(minimal_evaluation!), Any, MI, Module, Core.CodeInfo, Symbol})
    @warnpcfail precompile(Tuple{typeof(methods_by_execution!), Any, MI, DocExprs, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(methods_by_execution!), Any, MI, DocExprs, JuliaInterpreter.Frame, Vector{Bool}})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode,),Tuple{Symbol}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:skip_include,),Tuple{Bool}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode, :skip_include),Tuple{Symbol,Bool}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode,),Tuple{Symbol}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Frame, Vector{Bool}})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode, :skip_include),Tuple{Symbol,Bool}},
                             typeof(methods_by_execution!), Function, MI, DocExprs, Frame, Vector{Bool}})

    mex = which(methods_by_execution!, (Function, MI, DocExprs, Module, Expr))
    mbody = bodymethod(mex)
    # use `typeof(pairs(NamedTuple()))` here since it actually differs between Julia versions
    @warnpcfail precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, Bool, typeof(pairs(NamedTuple())), typeof(methods_by_execution!), Any, MI, DocExprs, Module, Expr})
    @warnpcfail precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, Bool, Iterators.Pairs{Symbol,Bool,Tuple{Symbol},NamedTuple{(:skip_include,),Tuple{Bool}}}, typeof(methods_by_execution!), Any, MI, DocExprs, Module, Expr})
    mfr = which(methods_by_execution!, (Function, MI, DocExprs, Frame, Vector{Bool}))
    mbody = bodymethod(mfr)
    @warnpcfail precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, typeof(methods_by_execution!), Any, MI, DocExprs, Frame, Vector{Bool}})

    @warnpcfail precompile(Tuple{typeof(hastrackedexpr), Expr})
    @warnpcfail precompile(Tuple{typeof(get_def), Method})
    @warnpcfail precompile(Tuple{typeof(parse_pkg_files), PkgId})
    if isdefined(Revise, :filter_valid_cachefiles)
        @warnpcfail precompile(Tuple{typeof(filter_valid_cachefiles), String, Vector{String}})
    end
    @warnpcfail precompile(Tuple{typeof(pkg_fileinfo), PkgId})
    @warnpcfail precompile(Tuple{typeof(push!), WatchList, Pair{String,PkgId}})
    @warnpcfail precompile(Tuple{typeof(pushex!), ExprsSigs, Expr})
    @warnpcfail precompile(Tuple{Type{ModuleExprsSigs}, Module})
    @warnpcfail precompile(Tuple{Type{FileInfo}, Module, String})
    @warnpcfail precompile(Tuple{Type{PkgData}, PkgId})
    @warnpcfail precompile(Tuple{typeof(Base._deleteat!), Vector{Tuple{Module,String,Float64}}, Vector{Int}})
    @warnpcfail precompile(Tuple{typeof(add_require), String, Module, String, String, Expr})
    @warnpcfail precompile(Tuple{Core.kwftype(typeof(maybe_add_includes_to_pkgdata!)),NamedTuple{(:eval_now,), Tuple{Bool}},typeof(maybe_add_includes_to_pkgdata!),PkgData,String,Vector{Pair{Module, String}}})

    for TT in (Tuple{Module,Expr}, Tuple{DataType,MethodSummary})
        @warnpcfail precompile(Tuple{Core.kwftype(typeof(Base.CoreLogging.handle_message)),NamedTuple{(:time, :deltainfo), Tuple{Float64, TT}},typeof(Base.CoreLogging.handle_message),ReviseLogger,LogLevel,String,Module,String,Symbol,String,Int})
    end
    return nothing
end
# COV_EXCL_STOP
