## Analyzing lowered code

using JuliaInterpreter: @lookup, moduleof, pc_expr, _step_expr!, prepare_thunk, split_expressions
using LoweredCodeUtils: next_or_nothing, isanonymous_typedef, define_anonymous

lastpc(frame) = JuliaInterpreter.JuliaProgramCounter(length(frame.code.code.code))

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

# This defines the API needed to store signatures using methods_by_execution!
# This default version is simple; there's a more involved one in Revise.jl that interacts
# with CodeTracking.
const MethodInfo = IdDict{Type,LineNumberNode}
add_signature!(methodinfo::MethodInfo, sig, ln) = push!(methodinfo, sig=>ln)
push_expr!(methodinfo::MethodInfo, mod::Module, ex::Expr) = methodinfo
pop_expr!(methodinfo::MethodInfo) = methodinfo

function methods_by_execution(mod::Module, ex::Expr; define=true)
    methodinfo = MethodInfo()
    docexprs = Dict{Module,Vector{Expr}}()
    stack = JuliaStackFrame[]
    return methods_by_execution!(methodinfo, docexprs, stack, mod, ex; define=define)
end

function methods_by_execution!(methodinfo, docexprs, stack, mod::Module, ex::Expr; define=true)
    frame = prepare_thunk(mod, ex)
    frame === nothing && return methodsinfo, docexprs
    return methods_by_execution!(methodinfo, docexprs, stack, frame; define=define)
end

function methods_by_execution!(methodinfo, docexprs, stack, frame; define=true)
    code = frame.code.code
    mod = moduleof(frame)
    signatures = []  # temporary for method signature storage
    pc = frame.pc[]
    while true
        stmt = pc_expr(frame, pc)
        if isa(stmt, Expr)
            if stmt.head == :struct_type || stmt.head == :abstract_type || stmt.head == :primitive_type
                if define
                    pc = _step_expr!(stack, frame, stmt, pc, true)  # This should check that they are unchanged
                else
                    pc = next_or_nothing(frame, pc)
                end
            elseif stmt.head == :thunk && isanonymous_typedef(stmt.args[1])
                # Anonymous functions should just be defined anew, since there does not seem to be a practical
                # way to "find" them. They may be needed to define later signatures.
                # Note that named inner methods don't require special treatment
                pc = define_anonymous(stack, frame, stmt, pc)
            elseif stmt.head == :method
                empty!(signatures)
                ret = methoddef!(signatures, stack, frame, stmt, pc; define=define)
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
                        for sig in signatures
                            add_signature!(methodinfo, sig, lnn)
                        end
                    else
                        @warn "unhandled lambda expression"
                    end
                end
            elseif stmt.head == :(=) && isa(stmt.args[1], Symbol)
                # sym = stmt.args[1]
                # if isconst(mod, sym)
                    pc = next_or_nothing(frame, pc)
                # else
                #     # FIXME: what about x = []? This will then wipe any current contents of x.
                #     # Alternatively, something that changes later method definition does need to be redefined.
                #     pc = _step_expr!(stack, frame, stmt, pc, true)
                # end
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
                    for (newmod, newex) in thismodexs
                        newframe = prepare_thunk(newmod, newex)
                        push_expr!(methodinfo, newmod, newex)
                        methods_by_execution!(methodinfo, docexprs, stack, newframe; define=define)
                        pop_expr!(methodinfo)
                    end
                    pc = next_or_nothing(frame, pc)
                elseif f === getfield(mod, :include) || f === Base.include || f === Core.include || f === Base.__precompile__
                    # Skip include calls, otherwise we load new code
                    pc = next_or_nothing(frame, pc)
                elseif !define && f === Base.Docs.doc!
                    pc = next_or_nothing(frame, pc)
                else
                    # A :call Expr we don't want to intercept
                    try
                        pc = _step_expr!(stack, frame, stmt, pc, true)
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
                        @warn "omitting call expression $(lookup_callexpr(frame, stmt))"
                        pc = next_or_nothing(frame, pc)
                    end
                end
            else
                # An Expr we don't want to intercept
                pc = _step_expr!(stack, frame, stmt, pc, true)
            end
        else
            # A statement we don't want to intercept
            pc = _step_expr!(stack, frame, stmt, pc, true)
        end
        pc === nothing && break
        stmt = pc_expr(frame, pc)
    end
    return methodinfo, docexprs
end
