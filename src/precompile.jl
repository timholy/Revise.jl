# COV_EXCL_START

const PRECOMPILE_ERRORS = Ref(false)

macro warnpcfail(ex::Expr)
    modl = __module__
    file = __source__.file === nothing ? "?" : String(__source__.file)
    line = __source__.line

    quote

        $(esc(ex)) || begin
            @warn """precompile directive

                $($(Expr(:quote, ex)))

            failed. Please report an issue in $($modl) (after checking for duplicates) or remove this directive.
            """ _file=$file _line=$line

            $PRECOMPILE_ERRORS[] = true
        end
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
    # `frozen` reaches these bodies by a runtime dispatch, so precompiling the entry points does not compile them.
    @warnpcfail precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:throw,), Tuple{Bool}}, typeof(_revise)})
    @warnpcfail precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:force,), Tuple{Bool}}, typeof(_revise), Module})
    @warnpcfail precompile(Tuple{typeof(revise_first), Expr})
    @warnpcfail precompile(Tuple{typeof(includet), String})
    @warnpcfail precompile(Tuple{typeof(_includet), typeof(identity), Module, String})
    @warnpcfail precompile(Tuple{typeof(track), Module, String})
    # setindex! doesn't fully precompile, but it's still beneficial to do it
    # (it shaves off a bit of the time)
    # See https://github.com/JuliaLang/julia/pull/31466
    @warnpcfail precompile(Tuple{typeof(setindex!), ExprsInfos, Nothing, RelocatableExpr})
    @warnpcfail precompile(Tuple{typeof(setindex!), ExprsInfos, Vector{Any}, RelocatableExpr})
    @warnpcfail precompile(Tuple{typeof(setindex!), ModuleExprsInfos, ExprsInfos, Module})
    @warnpcfail precompile(Tuple{typeof(setindex!), OrderedDict{PkgId,PkgData}, PkgData, PkgId})
    @warnpcfail precompile(Tuple{Type{WatchList}})
    @warnpcfail precompile(Tuple{typeof(setindex!), Dict{String,WatchList}, WatchList, String})

    MI = ExInfo
    @warnpcfail precompile(Tuple{typeof(minimal_evaluation!), Any, Module, Core.CodeInfo, Symbol})
    @warnpcfail precompile(Tuple{typeof(methods_by_execution!), Compiled, MI, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(_methods_by_execution!), Compiled, MI, Frame, Vector{Bool}})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode,),Tuple{Symbol}},
                             typeof(methods_by_execution!), Compiled, MI, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:skip_include,),Tuple{Bool}},
                             typeof(methods_by_execution!), Compiled, MI, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(methods_by_execution!)),
                             NamedTuple{(:mode, :skip_include),Tuple{Symbol,Bool}},
                             typeof(methods_by_execution!), Compiled, MI, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(_methods_by_execution!)),
                             NamedTuple{(:mode,),Tuple{Symbol}},
                             typeof(_methods_by_execution!), Compiled, MI, Frame, Vector{Bool}})
    @warnpcfail precompile(Tuple{typeof(Core.kwfunc(_methods_by_execution!)),
                             NamedTuple{(:mode, :skip_include),Tuple{Symbol,Bool}},
                             typeof(_methods_by_execution!), Compiled, MI, Frame, Vector{Bool}})

    mex = which(methods_by_execution!, (Compiled, MI, Module, Expr))
    mbody = bodymethod(mex)
    # use `typeof(pairs(NamedTuple()))` here since it actually differs between Julia versions
    @warnpcfail precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, Bool, Bool, typeof(pairs(NamedTuple())), typeof(methods_by_execution!), Compiled, MI, Module, Expr})
    if VERSION >= v"1.12-"
        @warnpcfail precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, Bool, Bool, Iterators.Pairs{Symbol,Bool,Nothing,NamedTuple{(:skip_include,),Tuple{Bool}}}, typeof(methods_by_execution!), Compiled, MI, Module, Expr})
    else
        @warnpcfail precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, Bool, Bool, Iterators.Pairs{Symbol,Bool,Tuple{Symbol},NamedTuple{(:skip_include,),Tuple{Bool}}}, typeof(methods_by_execution!), Compiled, MI, Module, Expr})
    end
    mfr = which(_methods_by_execution!, (Compiled, MI, Frame, Vector{Bool}))
    mbody = bodymethod(mfr)
    @warnpcfail precompile(Tuple{mbody.sig.parameters[1], Symbol, Bool, Bool, typeof(_methods_by_execution!), Compiled, MI, Frame, Vector{Bool}})
    # Reached through dynamic dispatch: the intercepted `eval`, the forwarded keywords, `invokelatest`
    @warnpcfail precompile(Tuple{typeof(Core.kwcall),
                             NamedTuple{(:mode, :skip_include, :eval_namespace, :disablebp),Tuple{Symbol,Bool,Bool,Bool}},
                             typeof(methods_by_execution!), Compiled, MI, Module, Expr})
    @warnpcfail precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:mode, :eval_namespace, :skip_include),Tuple{Symbol,Bool,Bool}},
                             typeof(_methods_by_execution!), Compiled, MI, Frame, Vector{Bool}})
    @warnpcfail precompile(Tuple{typeof(JuliaInterpreter.finish!), Compiled, Frame, Bool})
    @warnpcfail precompile(Tuple{typeof(get!), Type{Vector{Tuple{LineNumberNode,Expr}}}, typeof(CodeTracking.method_info), Any})
    @warnpcfail precompile(Tuple{typeof(isequal), QuoteNode, QuoteNode})
    @warnpcfail precompile(Tuple{typeof(isequal), Expr, Expr})
    for T in (DataType, UnionAll)
        @warnpcfail precompile(Tuple{typeof(push!), Set{Tuple{Type}}, Tuple{T}})
        @warnpcfail precompile(Tuple{typeof(in), Tuple{T}, Set{Tuple{Type}}})
    end
    @warnpcfail precompile(Tuple{typeof(_errors), Vector{Tuple{PkgData,String}}})
    @warnpcfail precompile(Tuple{typeof(run_idle_work), Function})

    @warnpcfail precompile(Tuple{typeof(get_def), Method})
    @warnpcfail precompile(Tuple{typeof(parse_pkg_files), PkgId})
    if isdefined(Revise, :filter_valid_cachefiles)
        @warnpcfail precompile(Tuple{typeof(filter_valid_cachefiles), String, Vector{String}})
    end
    @warnpcfail precompile(Tuple{typeof(Revise.iswritable), String})
    @warnpcfail precompile(Tuple{typeof(Revise.active_repl_backend_available)})
    @warnpcfail precompile(Tuple{typeof(wait_for_repl_backend)})
    @warnpcfail precompile(Tuple{typeof(add_repl_transform!), REPL.REPLBackend})
    @warnpcfail precompile(Tuple{typeof(throwto_repl), InterruptException})
    @warnpcfail precompile(Tuple{typeof(isempty), typeof(revision_queue)})
    @warnpcfail precompile(Tuple{typeof(pkg_fileinfo), PkgId})
    @warnpcfail precompile(Tuple{typeof(push!), WatchList, Pair{String,PkgId}})
    @warnpcfail precompile(Tuple{typeof(pushex!), ExprsInfos, Expr})
    @warnpcfail precompile(Tuple{Type{ModuleExprsInfos}, Module})
    @warnpcfail precompile(Tuple{Type{FileInfo}, Module, String})
    @warnpcfail precompile(Tuple{Type{PkgData}, PkgId})
    @warnpcfail precompile(Tuple{typeof(Base._deleteat!), Vector{Tuple{Module,String,Float64}}, Vector{Int}})
    @warnpcfail precompile(Tuple{typeof(add_require), String, Module, String, String, Expr})
    @warnpcfail precompile(Tuple{typeof(_add_require), String, Module, String, String, Expr})
    @warnpcfail precompile(Tuple{Core.kwftype(typeof(maybe_add_includes_to_pkgdata!)),NamedTuple{(:eval_now,), Tuple{Bool}},typeof(maybe_add_includes_to_pkgdata!),PkgData,String,Vector{Tuple{Module, Function, String}}})

    for TT in (Tuple{Module,Expr}, Tuple{DataType,MethodSummary})
        @warnpcfail precompile(Tuple{Core.kwftype(typeof(Base.CoreLogging.handle_message)),NamedTuple{(:time, :deltainfo), Tuple{Float64, TT}},typeof(Base.CoreLogging.handle_message),ReviseLogger,LogLevel,String,Module,String,Symbol,String,Int})
    end

    # Analyzed, not evaluated: compiles the dependency analysis for `revise_dependents`.
    if dependents_supported
        global_deps(@__MODULE__, :(let v = watched_files
            isa(v, Dict) && push!(get!(Dict{Int,Any}(), 1, v), length(v) + 1)
        end))
        global_deps(@__MODULE__, :(@doc "A docstring." function _dependents_workload end))
        # Results refer to code instances of this session
        empty!(summary_cache)
        empty!(tracked_snapshot)
        empty!(specializations)
        empty!(global_table.bindings)
        empty!(global_table.ids)
        empty!(global_table.raw)
        empty!(global_table.named)
        empty!(global_table.namedids)
        reset_inference_caches!(typemax(UInt))
        Changes = Vector{TrackedStmt}
        @warnpcfail precompile(Tuple{typeof(prepare_dependents!), Changes, Changes})
        @warnpcfail precompile(Tuple{typeof(reeval_dependent_statements!), Vector{Tuple{PkgData,String}}, Changes, Changes, UInt})
        @warnpcfail precompile(Tuple{typeof(cache_global_deps!), Vector{StmtKey}})
        @warnpcfail precompile(Tuple{typeof(current_deps), StmtKey, Set{Tuple{Module,Symbol}}, UInt})
        @warnpcfail precompile(Tuple{typeof(invalid_since), CallCheck})
        # The workload makes no sentinels while generating output.
        @warnpcfail precompile(Tuple{typeof(lookup_sentinel), Type, Vector{Method}})
        @warnpcfail precompile(Tuple{typeof(methods_by_type), Walk})
        @warnpcfail precompile(Tuple{typeof(run_analysis_ahead)})
        # Reached through `invokelatest` or with parameters of unknown type
        @warnpcfail precompile(Tuple{typeof(assumed_hold), Vector{Pair{Tuple{Module,Symbol},Any}}})
        @warnpcfail precompile(Tuple{typeof(changed_assumptions), Dict{Tuple{Module,Symbol},IdDict{Any,Set{Int}}}})
        @warnpcfail precompile(Tuple{typeof(stream_summary), Walk, Core.SimpleVector, Int, Bool})
        @warnpcfail precompile(Tuple{typeof(inert_call), Method, Core.SimpleVector, Walk})
        @warnpcfail precompile(Tuple{typeof(typed_methods_entry), Walk})
        # Looking up an expansion hashes it, with the pairs that expanded docstrings hold.
        for D in (Dict{Any,Any}, IdDict{Any,Any})
            @warnpcfail precompile(Tuple{typeof(haskey), D, Expr})
        end
        for T in (String, Int, Module)
            @warnpcfail precompile(Tuple{typeof(hash), Pair{Symbol,T}, UInt})
        end
        # Reached only through dynamic dispatch, so the workload does not store them. They are
        # internal: one a Julia version lacks is skipped.
        CC = Core.Compiler
        internal = Any[Tuple{typeof(in), Type, Set{DataType}}]
        for f in (:_builtin_effects, :_builtin_return_type)
            isdefined(Base, f) && push!(internal, Tuple{typeof(getglobal(Base, f)), Nothing, CC.NativeInterpreter, Core.Builtin, Any})
        end
        if isdefined(Base, :invoke_interp_compiler) && isdefined(CC, :fallback_lattice)
            L = typeof(CC.fallback_lattice)
            push!(internal, Tuple{typeof(Base.invoke_interp_compiler), Nothing, Symbol, Core.Const},
                  Tuple{typeof(Base.invoke_interp_compiler), Nothing, Symbol, Core.PartialStruct},
                  Tuple{typeof(Base.invoke_interp_compiler), Nothing, Symbol, Type},
                  Tuple{typeof(Base.invoke_interp_compiler), Nothing, Symbol, L, Vararg{Any}})
            isdefined(Base, :invoke_default_compiler) &&
                push!(internal, Tuple{typeof(Base.invoke_default_compiler), Symbol, L, Vararg{Any}})
        end
        if isdefined(Base, :fl_lower)
            for T in (Nothing, GlobalRef)
                push!(internal, Tuple{typeof(Base.fl_lower), T, Module, String, Int, UInt64, Bool},
                      Tuple{typeof(Base.fl_lower), Module, T, UInt64, Bool, LineNumberNode})
            end
        end
        foreach(precompile, internal)
        # The first analysis expands the macros of all tracked top-level statements. Expanding
        # does not store them, so these are typical calls of common macros.
        S = (LineNumberNode, Module)
        for (m, argtypes) in ((Core.var"@doc", (String, Expr, Bool)), (Core.var"@doc", (String, Symbol, Bool)),
                              (Core.var"@__doc__", (Expr,)), (Base.var"@__MODULE__", ()),
                              (Base.var"@nospecialize", (Symbol,)), (Base.var"@nospecialize", (Expr,)),
                              (Base.var"@static", (Expr,)), (Base.var"@isdefined", (Symbol,)),
                              (Base.var"@assert", (Expr,)), (Base.var"@assert", (Expr, String)),
                              (Base.var"@inline", (Expr,)), (Base.var"@noinline", (Expr,)),
                              (Base.var"@lock", (Symbol, Expr)), (Base.var"@lock", (Expr, Expr)),
                              (Base.var"@invokelatest", (Expr,)), (Base.var"@enum", (Symbol, Symbol, Symbol)),
                              (Base.var"@r_str", (String,)), (Base.var"@v_str", (String,)),
                              (Base.var"@MIME_str", (String,)), (Base.var"@warn", (String,)),
                              (Base.var"@warn", (Expr,)), (Base.var"@debug", (String, Expr)))
            @warnpcfail precompile(Tuple{typeof(m), S..., argtypes...})
        end
    end

    if get(ENV, "REVISE_PRECOMPILE_ERROR", "false") == "true" && PRECOMPILE_ERRORS[]
        error("Precompile statements failed. See output above for details")
    end

    return nothing
end
# COV_EXCL_STOP
