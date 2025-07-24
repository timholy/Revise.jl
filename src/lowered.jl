## Analyzing lowered code

function assign_this!(frame, value)
    frame.framedata.ssavalues[frame.pc] = value
end

# TODO Define abstract type MethodInfo end

# This defines the API needed to store signatures using methods_by_execution!
# This default version is simple and only used for testing purposes.
# The "real" one is CodeTrackingMethodInfo in Revise.jl.
const MethodInfo = IdDict{MethodInfoKey,LineNumberNode}
add_signature!(methodinfo, @nospecialize(sig), ln) = push!(methodinfo, sig=>ln)
push_expr!(methodinfo, mod::Module, ex::Expr) = methodinfo
pop_expr!(methodinfo) = methodinfo
add_includes!(methodinfo, mod::Module, filename) = methodinfo

function is_some_include(@nospecialize(f))
    @assert !isa(f, Core.SSAValue) && !isa(f, JuliaInterpreter.SSAValue)
    if isa(f, GlobalRef)
        return f.name === :include
    elseif isa(f, Symbol)
        return f === :include
    else
        if isa(f, QuoteNode)
            f = f.value
        end
        if isa(f, Function)
            if @static isdefined(Base, :IncludeInto) && isa(f, Base.IncludeInto)
                return true
            end
            mod = Base.typename(typeof(f)).module
            return isdefined(mod, :include) && f === (@isdefined(getglobal) ? getglobal(mod, :include) : getfield(mod, :include))
        end
    end
    return false
end

function is_defaultctors(@nospecialize(f))
    @assert !isa(f, Core.SSAValue) && !isa(f, JuliaInterpreter.SSAValue)
    if isa(f, GlobalRef)
        return f.mod === Core && f.name === :_defaultctors
    end
    return false
end

# This is not generally used, see `is_method_or_eval` instead
function hastrackedexpr(@nospecialize(stmt), code)
    haseval = false
    if isa(stmt, Expr)
        haseval = matches_eval(stmt)
        if stmt.head === :call
            f = stmt.args[1]
            while isa(f, Core.SSAValue) || isa(f, JuliaInterpreter.SSAValue)
                f = code[f.id]
            end
            callee_matches(f, Core, :_typebody!) && return true, haseval
            callee_matches(f, Core, :_setsuper!) && return true, haseval
            is_some_include(f) && return true, haseval
        elseif stmt.head === :thunk
            newcode = (stmt.args[1]::Core.CodeInfo).code
            any(s->any(hastrackedexpr(s, newcode)), newcode) && return true, haseval
        elseif stmt.head === :method
            return true, haseval
        end
    end
    return false, haseval
end

function matches_eval(stmt::Expr)
    stmt.head === :call || return false
    f = stmt.args[1]
    return f === :eval ||
           (callee_matches(f, Base, :getproperty) && is_quotenode_egal(stmt.args[end], :eval)) ||
           (isa(f, GlobalRef) && f.name === :eval) || is_quotenode_egal(f, Core.eval)
end

function categorize_stmt(@nospecialize(stmt), code::Vector{Any})
    ismeth, haseval, isinclude, isnamespace, istoplevel = false, false, false, false, false
    if isa(stmt, Expr)
        haseval = matches_eval(stmt)
        ismeth = stmt.head === :method || (stmt.head === :thunk && defines_function(only(stmt.args)))
        istoplevel = stmt.head === :toplevel
        isnamespace = stmt.head === :export || stmt.head === :import || stmt.head === :using
        isinclude = false
        if stmt.head === :call && length(stmt.args) >= 1
            callee = stmt.args[1]
            while isa(callee, Core.SSAValue) || isa(callee, JuliaInterpreter.SSAValue)
                callee = code[callee.id]
            end
            isinclude = is_some_include(callee)
            ismeth = is_defaultctors(callee)
        end
    end
    return ismeth, haseval, isinclude, isnamespace, istoplevel
end
# Check for thunks that define functions (fixes #792)
function defines_function(@nospecialize(ci))
    isa(ci, CodeInfo) || return false
    if length(ci.code) == 1
        stmt = ci.code[1]
        if isa(stmt, Core.ReturnNode)
            val = stmt.val
            isexpr(val, :method) && return true
        end
    end
    return false
end

"""
    isrequired, evalassign = minimal_evaluation!([predicate,] methodinfo, src::Core.CodeInfo, mode::Symbol)

Mark required statements in `src`: `isrequired[i]` is `true` if `src.code[i]` should be evaluated.
Statements are analyzed by `isreq, haseval = predicate(stmt)`, and `predicate` defaults
to `Revise.is_method_or_eval`.
`haseval` is true if the statement came from `@eval` or `eval(...)` call.
Since the contents of such expression are difficult to analyze, it is generally
safest to execute all such evals.
"""
function minimal_evaluation!(@nospecialize(predicate), methodinfo, mod::Module, src::Core.CodeInfo, mode::Symbol)
    edges = CodeEdges(mod, src)
    # LoweredCodeUtils.print_with_code(stdout, src, edges)
    isrequired = fill(false, length(src.code))
    namedconstassigned = Dict{GlobalRef,Bool}()
    evalassign = false
    for (i, stmt) in enumerate(src.code)
        if !isrequired[i]
            isrequired[i], haseval = predicate(stmt, src.code)::Tuple{Bool,Bool}
            if haseval                              # line `i` may be the equivalent of `f = Core.eval`, so...
                isrequired[edges.succs[i]] .= true  # ...require each stmt that calls `eval` via `f(expr)`
                isrequired[i] = true
            end
        end
        if isexpr(stmt, :const)
            name = stmt.args[1]
            if isa(name, Symbol)
                name = GlobalRef(mod, name)
            end
            namedconstassigned[name::GlobalRef] = false
        elseif (lhs_rhs = LoweredCodeUtils.get_lhs_rhs(stmt); lhs_rhs !== nothing)
            lhs, _ = lhs_rhs
            if isa(lhs, Symbol)
                lhs = GlobalRef(mod, lhs)
            end
            if isa(lhs, GlobalRef)
                if haskey(namedconstassigned, lhs)
                    namedconstassigned[lhs] = true
                end
            end
            if mode === :evalassign
                evalassign = isrequired[i] = true
                if isa(lhs, GlobalRef)
                    isrequired[edges.byname[lhs].succs] .= true  # mark any `const` statements or other "uses" in this block
                end
            end
        end
    end
    if mode === :sigs
        for (name, isassigned) in namedconstassigned
            isassigned || continue
            if isdefined(name.mod, name.name)
                empty!(edges.byname[name].succs)   # avoid redefining `consts` in `:sigs` mode (fixes #789)
            end
        end
    end
    # Check for docstrings
    if length(src.code) > 1 && mode !== :sigs
        stmt = src.code[end-1]
        if isexpr(stmt, :call) && (stmt::Expr).args[1] === Base.Docs.doc!
            isrequired[end-1] = true
        end
    end
    # All tracked expressions are marked. Now add their dependencies.
    # LoweredCodeUtils.print_with_code(stdout, src, isrequired)
    lines_required!(isrequired, src, edges;)
                    # norequire=mode===:sigs ? LoweredCodeUtils.exclude_named_typedefs(src, edges) : ())
    # LoweredCodeUtils.print_with_code(stdout, src, isrequired)
    return isrequired, evalassign
end
@noinline minimal_evaluation!(@nospecialize(predicate), methodinfo, frame::Frame, mode::Symbol) =
    minimal_evaluation!(predicate, methodinfo, moduleof(frame), frame.framecode.src, mode)

function minimal_evaluation!(methodinfo, frame::Frame, mode::Symbol)
    minimal_evaluation!(methodinfo, frame, mode) do @nospecialize(stmt), code::Vector{Any}
        ismeth, haseval, isinclude, isnamespace, istoplevel = categorize_stmt(stmt, code)
        isreq = ismeth | isinclude | istoplevel
        return mode === :sigs ? (isreq, haseval) : (isreq | isnamespace, haseval)
    end
end

function methods_by_execution(mod::Module, ex::Expr; kwargs...)
    methodinfo = MethodInfo()
    value, thk = methods_by_execution!(JuliaInterpreter.Compiled(), methodinfo, mod, ex; kwargs...)
    return methodinfo, thk
end

"""
    methods_by_execution!([interp::Interpreter=JuliaInterpreter.Compiled(),] methodinfo, mod::Module, ex::Expr;
                          mode=:eval, disablebp=true, skip_include=mode!==:eval, always_rethrow=false)

Evaluate or analyze `ex` in the context of `mod`.
Depending on the setting of `mode` (see the Extended help), it supports full evaluation or just the minimal
evaluation needed to extract method signatures.
`interp` controls JuliaInterpreter's evaluation of any non-intercepted statement;
likely choices are `JuliaInterpreter.Compiled()` or `JuliaInterpreter.RecursiveInterpreter()`.
`methodinfo` is a cache for storing information about any method definitions (see [`CodeTrackingMethodInfo`](@ref)).

# Extended help

The action depends on `mode`:

- `:eval` evaluates the expression in `mod`, similar to `Core.eval(mod, ex)` except that `methodinfo`
  will be populated with information about any signatures. This mode is used to implement `includet`.
- `:sigs` analyzes `ex` and extracts signatures of methods (specifically, statements flagged by
  [`Revise.minimal_evaluation!`](@ref)), but does not evaluate `ex` in the traditional sense.
  It will selectively execute statements needed to form the signatures of defined methods.
  It will also expand any `@eval`ed expressions, since these might contain method definitions.
- `:evalmeth` analyzes `ex` and extracts signatures like `:sigs`, but takes the additional step of
  evaluating any `:method` statements.
- `:evalassign` acts similarly to `:evalmeth`, and also evaluates assignment statements.

When selectively evaluating an expression, Revise will incorporate required dependencies, even for
minimal-evaluation modes like `:sigs`. For example, the method definition

    max_values(T::Union{map(X -> Type{X}, Base.BitIntegerSmall_types)...}) = 1 << (8*sizeof(T))

found in `base/abstractset.jl` requires that it create the anonymous function in order to compute the
signature.

The other keyword arguments are more straightforward:

- `disablebp` controls whether JuliaInterpreter's breakpoints are disabled before stepping through the code.
  They are restored on exit.
- `skip_include` prevents execution of `include` statements, instead inserting them into `methodinfo`'s
  cache. This defaults to `true` unless `mode` is `:eval`.
- `always_rethrow`, if true, causes an error to be thrown if evaluating `ex` triggered an error.
  If false, the error is logged with `@error`. `InterruptException`s are always rethrown.
  This is primarily useful for debugging.
"""
function methods_by_execution!(interp::Interpreter, methodinfo, mod::Module, ex::Expr;
                               mode::Symbol=:eval, disablebp::Bool=true, always_rethrow::Bool=false, kwargs...)
    mode ∈ (:sigs, :eval, :evalmeth, :evalassign) || error("unsupported mode ", mode)
    lwr = Meta.lower(mod, ex)
    isa(lwr, Expr) || return Pair{Any,Union{Nothing,Expr}}(nothing, nothing)
    if lwr.head === :error || lwr.head === :incomplete
        throw(LoweringException(lwr))
    end
    if lwr.head !== :thunk
        mode === :sigs && return Pair{Any,Union{Nothing,Expr}}(nothing, nothing)
        return Pair{Any,Union{Nothing,Expr}}(Core.eval(mod, lwr), nothing)
    end
    frame = Frame(mod, lwr.args[1]::CodeInfo)
    mode === :eval || LoweredCodeUtils.rename_framemethods!(interp, frame)
    # Determine whether we need interpreted mode
    isrequired, evalassign = minimal_evaluation!(methodinfo, frame, mode)
    # LoweredCodeUtils.print_with_code(stdout, frame.framecode.src, isrequired)
    if !any(isrequired) && (mode===:eval || !evalassign)
        # We can evaluate the entire expression in compiled mode
        if mode===:eval
            ret = try
                Core.eval(mod, ex)
            catch err
                (always_rethrow || isa(err, InterruptException)) && rethrow(err)
                loc = location_string(whereis(frame))
                bt = trim_toplevel!(catch_backtrace())
                throw(ReviseEvalException(loc, err, Any[(sf, 1) for sf in stacktrace(bt)]))
            end
        else
            ret = nothing
        end
    else
        # Use the interpreter
        local active_bp_refs
        if disablebp
            # We have to turn off all active breakpoints, https://github.com/timholy/CodeTracking.jl/issues/27
            bp_refs = JuliaInterpreter.BreakpointRef[]
            for bp in JuliaInterpreter.breakpoints()
                append!(bp_refs, bp.instances)
            end
            active_bp_refs = filter(bp->bp[].isactive, bp_refs)
            foreach(disable, active_bp_refs)
        end
        ret = try
            _methods_by_execution!(interp, methodinfo, frame, isrequired; mode, kwargs...)
        catch err
            (always_rethrow || isa(err, InterruptException)) && (disablebp && foreach(enable, active_bp_refs); rethrow(err))
            loc = location_string(whereis(frame))
            sfs = []  # crafted for interaction with Base.show_backtrace
            frame = JuliaInterpreter.leaf(frame)
            while frame !== nothing
                push!(sfs, (Base.StackTraces.StackFrame(frame), 1))
                frame = frame.caller
            end
            throw(ReviseEvalException(loc, err, sfs))
        end
        if disablebp
            foreach(enable, active_bp_refs)
        end
    end
    return Pair{Any,Union{Nothing,Expr}}(ret, lwr)
end
methods_by_execution!(methodinfo, mod::Module, ex::Expr; kwargs...) =
    methods_by_execution!(Compiled(), methodinfo, mod, ex; kwargs...)

function _methods_by_execution!(interp::Interpreter, methodinfo, frame::Frame, isrequired::AbstractVector{Bool};
                                mode::Symbol=:eval, skip_include::Bool=true)
    isok(lnn::LineTypes) = !iszero(lnn.line) || lnn.file !== :none   # might fail either one, but accept anything

    mod = moduleof(frame)
    # Hoist this lookup for performance. Don't throw even when `mod` is a baremodule:
    modinclude = isdefined(mod, :include) ? getfield(mod, :include) : nothing
    signatures = MethodInfoKey[]  # temporary for method signature storage
    pc = frame.pc
    while true
        JuliaInterpreter.is_leaf(frame) || (@warn("not a leaf"); break)
        stmt = pc_expr(frame, pc)
        if !isrequired[pc] && mode !== :eval && !(mode === :evalassign && LoweredCodeUtils.get_lhs_rhs(stmt) !== nothing)
            pc = next_or_nothing!(frame)
            pc === nothing && break
            continue
        end
        if isa(stmt, Expr)
            head = stmt.head
            if head === :toplevel
                local value
                for ex in stmt.args
                    ex isa Expr || continue
                    value, _ = methods_by_execution!(interp, methodinfo, mod, ex; mode, disablebp=false, skip_include)
                end
                isassign(frame, pc) && assign_this!(frame, value)
                pc = next_or_nothing!(frame)
            elseif head === :thunk && defines_function(only(stmt.args))
                mode !== :sigs && Core.eval(mod, stmt)
                pc = next_or_nothing!(frame)
            # elseif head === :thunk && isanonymous_typedef(stmt.args[1])
            #     # Anonymous functions should just be defined anew, since there does not seem to be a practical
            #     # way to find them within the already-defined module.
            #     # They may be needed to define later signatures.
            #     # Note that named inner methods don't require special treatment.
            #     pc = step_expr!(interp, frame, stmt, true)
            elseif head === :method
                empty!(signatures)
                ret = methoddef!(interp, signatures, frame, stmt, pc; define=mode!==:sigs)
                if ret === nothing
                    # This was just `function foo end` or similar.
                    # However, it might have been followed by a thunk that defined a
                    # method (issue #435), so we still need to check for additions.
                    if !isempty(signatures)
                        loc = whereis(frame.framecode, pc)
                        if loc !== nothing
                            file, line = loc
                            lnn = LineNumberNode(Int(line), Symbol(file))
                            for sig in signatures
                                add_signature!(methodinfo, sig, lnn)
                            end
                        end
                    end
                    @assert length(stmt.args) == 1
                    pc = mode !== :sigs ? step_expr!(interp, frame, stmt, true) :
                        next_or_nothing!(frame)
                else
                    pc, pc3 = ret
                    # Get the line number from the body
                    stmt3 = pc_expr(frame, pc3)::Expr
                    lnn = nothing
                    sigcode = lookup(interp, frame, stmt3.args[2])::Core.SimpleVector
                    lnn = sigcode[end]
                    if !isa(lnn, LineNumberNode)
                        lnn = nothing
                    end
                    if lnn === nothing
                        bodycode = stmt3.args[end]
                        if !isa(bodycode, CodeInfo)
                            bodycode = lookup(interp, frame, bodycode)
                        end
                        if isa(bodycode, CodeInfo)
                            lnn = linetable(bodycode, 1)
                            if !isok(lnn)
                                lnn = nothing
                                if length(bodycode.code) > 1
                                    # This may be a kwarg method. Mimic LoweredCodeUtils.bodymethod,
                                    # except without having a method
                                    stmt = bodycode.code[end-1]
                                    if isa(stmt, Expr) && length(stmt.args) > 1
                                        stmt = stmt::Expr
                                        a = stmt.args[1]
                                        nargs = length(stmt.args)
                                        hasself = let stmt = stmt, slotnames::Vector{Symbol} = bodycode.slotnames
                                            any(i->LoweredCodeUtils.is_self_call(stmt, slotnames, i), 2:nargs)
                                        end
                                        if isa(a, Core.SlotNumber)
                                            a = bodycode.slotnames[a.id]
                                        end
                                        if hasself && (isa(a, Symbol) || isa(a, GlobalRef))
                                            thismod, thisname = isa(a, Symbol) ? (mod, a) : (a.mod, a.name)
                                            if isdefined(thismod, thisname)
                                                f = getfield(thismod, thisname)
                                                mths = methods(f)
                                                if length(mths) == 1
                                                    mth = first(mths)
                                                    lnn = LineNumberNode(Int(mth.line), mth.file)
                                                end
                                            end
                                        end
                                    end
                                end
                                if lnn === nothing
                                    # Just try to find *any* line number
                                    for lnntmp in linetable(bodycode)
                                        lnntmp = lnntmp::LineTypes
                                        if isok(lnntmp)
                                            lnn = lnntmp
                                            break
                                        end
                                    end
                                end
                            end
                        elseif isexpr(bodycode, :lambda)
                            bodycode = bodycode::Expr
                            lnntmp = bodycode.args[end][1]::LineTypes
                            if isok(lnntmp)
                                lnn = lnntmp
                            end
                        end
                    end
                    if lnn === nothing
                        i = codelocs(frame, pc3)
                        while i > 0
                            lnntmp = linetable(frame, i)
                            if isok(lnntmp)
                                lnn = lnntmp
                                break
                            end
                            i -= 1
                        end
                    end
                    if lnn !== nothing && isok(lnn)
                        for sig in signatures
                            add_signature!(methodinfo, sig, lnn)
                        end
                    end
                end
            elseif LoweredCodeUtils.get_lhs_rhs(stmt) !== nothing
                if mode === :sigs && stmt.head === :const && (a = stmt.args[1]) isa GlobalRef && @invokelatest(isdefined(mod, a.name))
                    # avoid redefining types unless we have to
                    pc = next_or_nothing!(frame)
                else
                    pc = step_expr!(interp, frame, stmt, true)
                end
            elseif head === :call
                f = lookup(interp, frame, stmt.args[1])
                if isdefined(Core, :_defaultctors) && f === Core._defaultctors && length(stmt.args) == 3
                    T = lookup(interp, frame, stmt.args[2])
                    lnn = lookup(interp, frame, stmt.args[3])
                    if T isa Type && lnn isa LineNumberNode
                        empty!(signatures)
                        uT = Base.unwrap_unionall(T)::DataType
                        ft = uT.types
                        sig1 = Tuple{Base.rewrap_unionall(Type{uT}, T), Any[Any for i in 1:length(ft)]...}
                        push!(signatures, nothing => sig1)
                        sig2 = Base.rewrap_unionall(Tuple{Type{T}, ft...}, T)
                        while T isa UnionAll
                            sig2 isa UnionAll || (sig2 = sig1; break) # sig2 doesn't define all parameters, so drop it
                            T = T.body
                        end
                        sig1 == sig2 || push!(signatures, nothing => sig2)
                        for sig in signatures
                            add_signature!(methodinfo, sig, lnn)
                        end
                    end
                    if mode===:sigs
                        pc = next_or_nothing!(frame)
                    else # also execute this call
                        pc = step_expr!(interp, frame, stmt, true)
                    end
                elseif f === Core.eval
                    # an @eval or eval block: this may contain method definitions, so intercept it.
                    evalmod = lookup(interp, frame, stmt.args[2])::Module
                    evalex = lookup(interp, frame, stmt.args[3])
                    value = nothing
                    for (newmod, newex) in ExprSplitter(evalmod, evalex)
                        if is_doc_expr(newex)
                            newex = newex.args[4]
                        end
                        newex = unwrap(newex)
                        push_expr!(methodinfo, newmod, newex)
                        value, _ = methods_by_execution!(interp, methodinfo, newmod, newex; mode, skip_include, disablebp=false)
                        pop_expr!(methodinfo)
                    end
                    assign_this!(frame, value)
                    pc = next_or_nothing!(frame)
                elseif skip_include && (f === modinclude || f === Core.include)
                    # include calls need to be managed carefully from several standpoints, including
                    # path management and parsing new expressions
                    if length(stmt.args) == 2
                        add_includes!(methodinfo, mod, lookup(interp, frame, stmt.args[2]))
                    elseif length(stmt.args) == 3
                        mod_or_mapexpr = lookup(interp, frame, stmt.args[2])
                        if isa(mod_or_mapexpr, Module)
                            add_includes!(methodinfo, mod_or_mapexpr, lookup(interp, frame, stmt.args[3]))
                        else
                            add_includes!(methodinfo, mod, MapExprFile(mod_or_mapexpr, lookup(interp, frame, stmt.args[3])))
                        end
                    else
                        error("Bad call to Core.include")
                    end
                    assign_this!(frame, nothing)  # FIXME: the file might return something different from `nothing`
                    pc = next_or_nothing!(frame)
                elseif skip_include && f === Base.include
                    if length(stmt.args) == 2
                        add_includes!(methodinfo, mod, lookup(interp, frame, stmt.args[2]))
                    else # either include(module, path) or include(mapexpr, path)
                        mod_or_mapexpr = lookup(interp, frame, stmt.args[2])
                        if isa(mod_or_mapexpr, Module)
                            add_includes!(methodinfo, mod_or_mapexpr, lookup(interp, frame, stmt.args[3]))
                        else
                            add_includes!(methodinfo, mod, MapExprFile(mod_or_mapexpr, lookup(interp, frame, stmt.args[3])))
                        end
                    end
                    assign_this!(frame, nothing)  # FIXME: the file might return something different from `nothing`
                    pc = next_or_nothing!(frame)
                elseif f === Base.Docs.doc! # && mode !== :eval
                    fargs = JuliaInterpreter.collect_args(interp, frame, stmt)
                    popfirst!(fargs)
                    length(fargs) == 3 && push!(fargs, Union{})  # add the default sig
                    dmod::Module, b::Base.Docs.Binding, str::Base.Docs.DocStr, sig = fargs
                    if isdefined(b.mod, b.var)
                        tmpvar = getfield(b.mod, b.var)
                        if isa(tmpvar, Module)
                            dmod = tmpvar
                        end
                    end
                    # Workaround for julia#38819 on older Julia versions
                    if !isdefined(dmod, Base.Docs.META)
                        Base.Docs.initmeta(dmod)
                    end
                    m = get!(Base.Docs.meta(dmod), b, Base.Docs.MultiDoc())::Base.Docs.MultiDoc
                    if haskey(m.docs, sig)
                        currentstr = m.docs[sig]::Base.Docs.DocStr
                        redefine = currentstr.text != str.text
                    else
                        push!(m.order, sig)
                        redefine = true
                    end
                    # (Re)assign without the warning
                    if redefine
                        m.docs[sig] = str
                        str.data[:binding] = b
                        str.data[:typesig] = sig
                    end
                    assign_this!(frame, Base.Docs.doc(b, sig))
                    pc = next_or_nothing!(frame)
                else
                    # A :call Expr we don't want to intercept
                    pc = step_expr!(interp, frame, stmt, true)
                end
            else
                # An Expr we don't want to intercept
                frame.pc = pc
                pc = step_expr!(interp, frame, stmt, true)
            end
        else
            # A statement we don't want to intercept
            pc = step_expr!(interp, frame, stmt, true)
        end
        pc === nothing && break
    end
    return isrequired[frame.pc] ? get_return(frame) : nothing
end
