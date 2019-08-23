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
# This default version is simple; there's a more involved one in Revise.jl that interacts
# with CodeTracking.
const MethodInfo = IdDict{Type,LineNumberNode}
add_signature!(methodinfo::MethodInfo, @nospecialize(sig), ln) = push!(methodinfo, sig=>ln)
push_expr!(methodinfo::MethodInfo, mod::Module, ex::Expr) = methodinfo
pop_expr!(methodinfo::MethodInfo) = methodinfo

function methods_by_execution(mod::Module, ex::Expr; kwargs...)
    methodinfo = MethodInfo()
    docexprs = Dict{Module,Vector{Expr}}()
    value = methods_by_execution!(finish_and_return!, methodinfo, docexprs, mod, ex; kwargs...)
    return methodinfo, docexprs
end

function methods_by_execution!(@nospecialize(recurse), methodinfo, docexprs, mod::Module, ex::Expr; kwargs...)
    # We have to turn off all active breakpoints, https://github.com/timholy/CodeTracking.jl/issues/27
    bp_refs = JuliaInterpreter.breakpoints()
    if eltype(bp_refs) !== JuliaInterpreter.BreakpointRef
        bp_refs = JuliaInterpreter.BreakpointRef[]
        foreach(bp -> append!(bp_refs, bp.instances), bp_refs)
    end
    active_bp_refs = filter(bp->bp[].isactive, bp_refs)
    foreach(disable, active_bp_refs)
    local ret
    try
        frame = prepare_thunk(mod, ex)
        frame === nothing && return nothing
        ret = methods_by_execution!(recurse, methodinfo, docexprs, frame; kwargs...)
    catch err
        isa(err, InterruptException) && rethrow(err)
        @error "evaluation error" mod ex exception=(err, catch_backtrace())
        ret = nothing
    finally
        foreach(enable, active_bp_refs)
    end
    return ret
end

function methods_by_execution!(@nospecialize(recurse), methodinfo, docexprs, frame; define=true, skip_include=true)
    mod = moduleof(frame)
    signatures = []  # temporary for method signature storage
    pc = frame.pc
    while true
        JuliaInterpreter.is_leaf(frame) || break
        stmt = pc_expr(frame, pc)
        if isa(stmt, Expr)
            if stmt.head == :struct_type || stmt.head == :abstract_type || stmt.head == :primitive_type
                if define
                    pc = step_expr!(recurse, frame, stmt, true)  # This should check that they are unchanged
                else
                    pc = next_or_nothing!(frame)
                end
            elseif stmt.head == :thunk && isanonymous_typedef(stmt.args[1])
                # Anonymous functions should just be defined anew, since there does not seem to be a practical
                # way to "find" them. They may be needed to define later signatures.
                # Note that named inner methods don't require special treatment
                pc = step_expr!(recurse, frame, stmt, true)
            elseif stmt.head == :method
                empty!(signatures)
                ret = methoddef!(recurse, signatures, frame, stmt, pc; define=define)
                if ret === nothing
                    # This was just `function foo end` or similar
                    @assert isempty(signatures)
                    pc = ret
                else
                    pc, pc3 = ret
                    # Get the line number from the body
                    stmt3 = pc_expr(frame, pc3)
                    bodycode = stmt3.args[end]
                    if !isa(bodycode, CodeInfo)
                        bodycode = @lookup(frame, bodycode)
                    end
                    if isa(bodycode, CodeInfo)
                        lnn = bodycode.linetable[1]
                        if lnn.line == 0 && lnn.file == :none && length(bodycode.code) > 1
                            # This may be a kwarg method. Mimic LoweredCodeUtils.bodymethod,
                            # except without having a method
                            stmt = bodycode.code[end-1]
                            if length(stmt.args) > 1
                                a = stmt.args[1]
                                hasself = any(i->LoweredCodeUtils.is_self_call(stmt, bodycode.slotnames, i), 2:length(stmt.args))
                                if hasself && isa(a, Symbol)
                                    f = getfield(mod, stmt.args[1])
                                    mths = methods(f)
                                    if length(mths) == 1
                                        mth = first(mths)
                                        lnn = LineNumberNode(Int(mth.line), mth.file)
                                    end
                                end
                            end
                        end
                        for sig in signatures
                            add_signature!(methodinfo, sig, lnn)
                        end
                    elseif isexpr(bodycode, :lambda)
                        lnn = bodycode.args[end][1]
                        for sig in signatures
                            add_signature!(methodinfo, sig, lnn)
                        end
                    else
                        error("unhandled bodycode ", bodycode)
                    end
                end
            elseif stmt.head == :(=) && isa(stmt.args[1], Symbol)
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
            elseif stmt.head == :call
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
                        push_expr!(methodinfo, newmod, newex)
                        value = methods_by_execution!(recurse, methodinfo, docexprs, newframe; define=define)
                        pop_expr!(methodinfo)
                    end
                    assign_this!(frame, value)
                    pc = next_or_nothing!(frame)
                elseif skip_include && (f === getfield(mod, :include) || f === Base.include || f === Core.include)
                    # Skip include calls, otherwise we load new code
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
                    try
                        pc = step_expr!(recurse, frame, stmt, true)
                    catch
                        # This can happen with functions defined in `let` blocks, e.g.,
                        #     let trynames(names) = begin
                        #         return root_path::AbstractString -> begin
                        #             # stuff
                        #         end
                        #     end # trynames
                        #         global projectfile_path = trynames(Base.project_names)
                        #         global manifestfile_path = trynames(Base.manifest_names)
                        #     end
                        # as found in Pkg.Types.
                        badstmt = lookup_callexpr(frame, stmt)
                        @warn "omitting call expression $badstmt in $(whereis(frame))"
                        assign_this!(frame, nothing)
                        pc = next_or_nothing!(frame)
                    end
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
        stmt = pc_expr(frame, pc)
    end
    return get_return(frame)
end
