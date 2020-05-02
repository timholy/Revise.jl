## Analyzing lowered code

function add_docexpr!(docexprs::AbstractDict{Module,V}, mod::Module, ex) where V
    docexs = get(docexprs, mod, nothing)
    if docexs === nothing
        docexs = docexprs[mod] = V()
    end
    push!(docexs, ex)
    return docexprs
end

function lookup_callexpr(frame, stmt)
    fargs = JuliaInterpreter.collect_args(frame, stmt)
    return Expr(:call, fargs...)
end

function assign_this!(frame, value)
    frame.framedata.ssavalues[frame.pc] = value
end

# This defines the API needed to store signatures using methods_by_execution!
# This default version is simple; there's a more involved one in the file Revise.jl
# that interacts with CodeTracking.
const MethodInfo = IdDict{Type,LineNumberNode}
add_signature!(methodinfo::MethodInfo, @nospecialize(sig), ln) = push!(methodinfo, sig=>ln)
push_expr!(methodinfo::MethodInfo, mod::Module, ex::Expr) = methodinfo
pop_expr!(methodinfo::MethodInfo) = methodinfo
add_dependencies!(methodinfo::MethodInfo, be::BackEdges, src, chunks) = methodinfo
add_includes!(methodinfo::MethodInfo, filename) = methodinfo

function minimal_evaluation!(methodinfo, frame)
    src = frame.framecode.src
    be = BackEdges(src)
    chunks = toplevel_chunks(be)
    musteval = falses(length(src.code))
    for chunk in chunks
        if hastrackedexpr(frame.framecode.src, chunk)
            musteval[chunk] .= true
        end
    end
    # Conservatively, we need to step in to each Core.eval in case the expression defines a method.
    hadeval = false
    for id in eachindex(src.code)
        stmt = src.code[id]
        me = false
        if isa(stmt, Expr)
            if stmt.head == :call
                f = stmt.args[1]
                me |= f === :include
                me |= JuliaInterpreter.hasarg(isequal(:eval), stmt.args)
            end
        end
        if me
            chunkid = findfirst(chunk->id∈chunk, chunks)
            musteval[chunks[chunkid]] .= true
        end
    end
    add_dependencies!(methodinfo, be, src, chunks)
    return musteval
end

function methods_by_execution(mod::Module, ex::Expr; kwargs...)
    methodinfo = MethodInfo()
    docexprs = Dict{Module,Vector{Expr}}()
    value, frame = methods_by_execution!(finish_and_return!, methodinfo, docexprs, mod, ex; kwargs...)
    return methodinfo, docexprs, frame
end

function methods_by_execution!(@nospecialize(recurse), methodinfo, docexprs, mod::Module, ex::Expr; always_rethrow=false, define=true, kwargs...)
    lwr = Meta.lower(mod, ex)
    isa(lwr, Expr) || return nothing, nothing
    frame = prepare_thunk(mod, copy(lwr), true)
    frame === nothing && return nothing, nothing
    define || LoweredCodeUtils.rename_framemethods!(recurse, frame)
    # Determine whether we need interpreted mode
    musteval = minimal_evaluation!(methodinfo, frame)
    if !any(musteval)
        # We can evaluate the entire expression in compiled mode
        if define
            ret = try
                Core.eval(mod, ex) # evaluate in compiled mode if we don't need to interpret
            catch err
                (always_rethrow || isa(err, InterruptException)) && rethrow(err)
                loc = location_string(whereis(frame)...)
                @error "(compiled mode) evaluation error starting at $loc" mod ex exception=(err, trim_toplevel!(catch_backtrace()))
                nothing
            end
        else
            ret = nothing
        end
    else
        # Use the interpreter
        # We have to turn off all active breakpoints, https://github.com/timholy/CodeTracking.jl/issues/27
        bp_refs = JuliaInterpreter.breakpoints()
        if eltype(bp_refs) !== JuliaInterpreter.BreakpointRef
            bp_refs = JuliaInterpreter.BreakpointRef[]
            foreach(bp -> append!(bp_refs, bp.instances), bp_refs)
        end
        active_bp_refs = filter(bp->bp[].isactive, bp_refs)
        foreach(disable, active_bp_refs)
        ret = try
            methods_by_execution!(recurse, methodinfo, docexprs, frame, musteval; define=define, kwargs...)
        catch err
            (always_rethrow || isa(err, InterruptException)) && rethrow(err)
            loc = location_string(whereis(frame)...)
            @error "evaluation error starting at $loc" mod ex exception=(err, trim_toplevel!(catch_backtrace()))
            nothing
        end
        foreach(enable, active_bp_refs)
    end
    return ret, lwr
end

function methods_by_execution!(@nospecialize(recurse), methodinfo, docexprs, frame, musteval; define=true, skip_include=true)
    mod = moduleof(frame)
    # Hoist this lookup for performance. Don't throw even when `mod` is a baremodule:
    modinclude = isdefined(mod, :include) ? getfield(mod, :include) : nothing
    signatures = []  # temporary for method signature storage
    pc = frame.pc
    while true
        JuliaInterpreter.is_leaf(frame) || (@warn("not a leaf"); break)
        if !musteval[pc] && !define
            pc = next_or_nothing!(frame)
            pc === nothing && break
            continue
        end
        stmt = pc_expr(frame, pc)
        if isa(stmt, Expr)
            head = stmt.head
            if head ∈ structheads
                if define
                    pc = step_expr!(recurse, frame, stmt, true)  # This should check that they are unchanged
                else
                    pc = next_or_nothing!(frame)
                end
            elseif head === :thunk && isanonymous_typedef(stmt.args[1])
                # Anonymous functions should just be defined anew, since there does not seem to be a practical
                # way to "find" them. They may be needed to define later signatures.
                # Note that named inner methods don't require special treatment
                pc = step_expr!(recurse, frame, stmt, true)
            elseif head === :method
                empty!(signatures)
                ret = methoddef!(recurse, signatures, frame, stmt, pc; define=define)
                if ret === nothing
                    # This was just `function foo end` or similar.
                    # However, it might have been followed by a thunk that defined a
                    # method (issue #435), so we still need to check for additions.
                    if !isempty(signatures)
                        file, line = whereis(frame.framecode, pc)
                        lnn = LineNumberNode(Int(line), Symbol(file))
                        for sig in signatures
                            add_signature!(methodinfo, sig, lnn)
                        end
                    end
                    pc = ret
                else
                    pc, pc3 = ret
                    # Get the line number from the body
                    stmt3 = pc_expr(frame, pc3)
                    lnn = nothing
                    if line_is_decl
                        sigcode = @lookup(frame, stmt3.args[2])
                        lnn = sigcode[end]
                        if !isa(lnn, LineNumberNode)
                            lnn = nothing
                        end
                    end
                    if lnn === nothing
                        bodycode = stmt3.args[end]
                        if !isa(bodycode, CodeInfo)
                            bodycode = @lookup(frame, bodycode)
                        end
                        if isa(bodycode, CodeInfo)
                            lnn = bodycode.linetable[1]
                            if lnn.line == 0 && lnn.file == :none
                                lnn = nothing
                                if length(bodycode.code) > 1
                                    # This may be a kwarg method. Mimic LoweredCodeUtils.bodymethod,
                                    # except without having a method
                                    stmt = bodycode.code[end-1]
                                    if isa(stmt, Expr) && length(stmt.args) > 1
                                        a = stmt.args[1]
                                        hasself = any(i->LoweredCodeUtils.is_self_call(stmt, bodycode.slotnames, i), 2:length(stmt.args))
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
                                    for lnntmp in bodycode.linetable
                                        if lnntmp.line != 0 || lnntmp.file != :none
                                            lnn = lnntmp
                                            break
                                        end
                                    end
                                end
                            end
                        elseif isexpr(bodycode, :lambda)
                            lnntmp = bodycode.args[end][1]
                            if lnntmp.line != 0 || lnntmp.file != :none
                                lnn = lnntmp
                            end
                        end
                    end
                    if lnn === nothing
                        i = frame.framecode.src.codelocs[pc3]
                        while i > 0
                            lnntmp = frame.framecode.src.linetable[i]
                            if lnntmp.line != 0 || lnntmp.file != :none
                                lnn = lnntmp
                                break
                            end
                            i -= 1
                        end
                    end
                    if lnn !== nothing && (lnn.line != 0 || lnn.file != :none)
                        for sig in signatures
                            add_signature!(methodinfo, sig, lnn)
                        end
                    end
                end
            elseif head === :(=) && isa(stmt.args[1], Symbol)
                if define
                    pc = step_expr!(recurse, frame, stmt, true)
                else
                    # FIXME: Code that initializes a global, performs some operations that
                    # depend on the value, and then mutates it will run into serious trouble here.
                    # sym = stmt.args[1]
                    # if isconst(mod, sym)
                    rhs = stmt.args[2]
                    val = isa(rhs, Expr) ? JuliaInterpreter.eval_rhs(recurse, frame, rhs) : @lookup(frame, rhs)
                    assign_this!(frame, val)
                    pc = next_or_nothing!(frame)
                    # else
                    #     pc = step_expr!(recurse, frame, stmt, true)
                    # end
                end
            elseif head === :call
                f = @lookup(frame, stmt.args[1])
                if f === Core.eval
                    # an @eval or eval block: this may contain method definitions, so intercept it.
                    evalmod = @lookup(frame, stmt.args[2])
                    evalex = @lookup(frame, stmt.args[3])
                    thismodexs, thisdocexprs = split_expressions(evalmod, evalex; extract_docexprs=true)
                    for (m, docexs) in thisdocexprs
                        for docex in docexs
                            add_docexpr!(docexprs, m, docex)
                        end
                    end
                    value = nothing
                    for (newmod, newex) in thismodexs
                        newex = unwrap(newex)
                        newframe = prepare_thunk(newmod, newex)
                        newframe === nothing && continue
                        define || LoweredCodeUtils.rename_framemethods!(recurse, newframe)
                        newmusteval = minimal_evaluation!(methodinfo, newframe)
                        push_expr!(methodinfo, newmod, newex)
                        value = methods_by_execution!(recurse, methodinfo, docexprs, newframe, newmusteval; define=define)
                        pop_expr!(methodinfo)
                    end
                    assign_this!(frame, value)
                    pc = next_or_nothing!(frame)
                elseif skip_include && (f === modinclude || f === Base.include || f === Core.include)
                    # Skip include calls, otherwise we load new code
                    add_includes!(methodinfo, @lookup(frame, stmt.args[2]))
                    assign_this!(frame, nothing)  # FIXME: the file might return something different from `nothing`
                    pc = next_or_nothing!(frame)
                elseif !define && f === Base.Docs.doc!
                    fargs = JuliaInterpreter.collect_args(frame, stmt)
                    popfirst!(fargs)
                    length(fargs) == 3 && push!(fargs, Union{})  # add the default sig
                    dmod, b, str, sig = fargs
                    m = get!(Base.Docs.meta(dmod), b, Base.Docs.MultiDoc())
                    if haskey(m.docs, sig)
                        currentstr = m.docs[sig]
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
                    pc = step_expr!(recurse, frame, stmt, true)
                end
            else
                # An Expr we don't want to intercept
                pc = step_expr!(recurse, frame, stmt, true)
            end
        else
            # A statement we don't want to intercept
            pc = step_expr!(recurse, frame, stmt, true)
        end
        pc === nothing && break
    end
    return musteval[frame.pc] ? get_return(frame) : nothing
end
