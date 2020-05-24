using Core.Compiler: CodeInfo, NewvarNode, GotoNode
using Base.Meta: isexpr
using JuliaInterpreter: is_global_ref

const SSAValues = Union{Core.Compiler.SSAValue, JuliaInterpreter.SSAValue}

const structheads = VERSION >= v"1.5.0-DEV.702" ? () : (:struct_type, :abstract_type, :primitive_type)
const trackedheads = (:method, structheads...)

isssa(stmt) = isa(stmt, Core.Compiler.SSAValue) | isa(stmt, JuliaInterpreter.SSAValue)
isslotnum(stmt) = isa(stmt, Core.Compiler.SlotNumber) | isa(stmt, JuliaInterpreter.SlotNumber)

"""
`SlotDep` is an internal type used for holding information about dependencies of a SlotNumber
variable. If `sd` is a `SlotDep`, then
- `sd.lineassigned` is the statement number on which the SlotNumber was most recently assigned
- `sd.linedeps` is the set of previous SSAValues upon which this assigment depends (encoded as Int)
"""
mutable struct SlotDep
    lineassigned::Int
    linedeps::Vector{Int}  # we use Int to handle Core.Compiler.SSAValue & JuliaInterpreter.SSAValue
end
function SlotDep(i::Int, stmt, slotdeps)
    deps = add_deps!(Int[], stmt, slotdeps)
    SlotDep(i, deps)
end
function add_deps!(linedeps, stmt, slotdeps)
    if isssa(stmt)
        push!(linedeps, stmt.id)
    elseif isslotnum(stmt)
        append!(linedeps, slotdeps[stmt.id].linedeps)
        push!(linedeps, slotdeps[stmt.id].lineassigned)
    elseif isa(stmt, Expr)
        for a in stmt.args
            if isssa(a) || isslotnum(a) || isa(a, Expr)
                add_deps!(linedeps, a, slotdeps)
            end
        end
    end
    return linedeps
end

# See docs below for `BackEdges(ci::CodeInfo)`
mutable struct Uses
    ids::Vector{Int}        # lines where it is used
    defined::Vector{Int}    # lines where it is defined
end
Uses() = Uses(Int[], Int[])
Base.push!(uses::Uses, loc::Int) = push!(uses.ids, loc)

struct BackEdges
    byid::Vector{Vector{Int}}
    byname::Dict{Union{GlobalRef,Symbol},Uses}
end
BackEdges(n::Integer) = BackEdges([Int[] for i = 1:n], Dict{Union{GlobalRef,Symbol},Uses}())

id_loc(pr::Pair) = pr.first, pr.second
id_loc(pr::Pair{<:SSAValues,Int}) = pr.first.id, pr.second
id_loc(pr::Pair{Bool,Int}) = pr.second - 1, pr.second # handles statements like `if true f() = 1 else f() = 2 end`
function Base.push!(be::BackEdges, pr::Pair{<:Union{Integer,SSAValues},Int})
    @noinline errorder(y, x) = throw(ArgumentError("SSA form requires that dependencies come after the statement, got $y and $x"))

    id, loc = id_loc(pr)
    loc > id || errorder(loc, id)
    push!(be.byid[id], loc)
    return be
end
function Base.push!(be::BackEdges, pr::Pair{named,Int}) where named <: Union{Symbol,GlobalRef}
    id, loc = pr
    if isa(id, GlobalRef)
        obj = getfield(id.mod, id.name)
        isa(obj, Core.Builtin) && return be
    end
    ref = get(be.byname, id, nothing)
    if ref === nothing
        be.byname[id] = ref = Uses()
    end
    push!(ref, loc)
    return be
end

function add_to_backedges!(backedges::BackEdges, slotdeps, loc, stmt)
    if isssa(stmt)
        push!(backedges, stmt=>loc)
    elseif isslotnum(stmt)
        isassigned(slotdeps, stmt.id) || return backedges # issue #428 (it's inside an `if false...end`)
        sd = slotdeps[stmt.id]
        if sd.lineassigned != 0
            push!(backedges, sd.lineassigned=>loc)
        end
        for id in sd.linedeps
            push!(backedges, id=>loc)
        end
    elseif stmt isa GlobalRef
        push!(backedges, stmt=>loc)
    elseif stmt isa Symbol
        push!(backedges, stmt=>loc)
    elseif stmt isa Expr
        head = stmt.head
        if head === :call && !(isssa(stmt.args[1]) || isslotnum(stmt.args[1]))
            for a in Iterators.drop(stmt.args, 1)  # don't track the callee
                add_to_backedges!(backedges, slotdeps, loc, a)
            end
        elseif head ∈ trackedheads && (name = stmt.args[1]; isa(name, Symbol) | isa(name, GlobalRef))
            push!(backedges, name=>loc)
            push!(backedges.byname[name].defined, loc)
            for a in Iterators.drop(stmt.args, 1)
                add_to_backedges!(backedges, slotdeps, loc, a)
            end
        elseif head === :(=) && (lhs = stmt.args[1]; isa(lhs, Symbol) || isa(lhs, GlobalRef))
            add_to_backedges!(backedges, slotdeps, loc, lhs)
            push!(backedges.byname[lhs].defined, loc)
            add_to_backedges!(backedges, slotdeps, loc, stmt.args[2])
        else
            for a in stmt.args
                add_to_backedges!(backedges, slotdeps, loc, a)
            end
        end
    elseif stmt isa Pair
        add_to_backedges!(backedges, slotdeps, loc, stmt.first)
        add_to_backedges!(backedges, slotdeps, loc, stmt.second)
    elseif stmt isa Tuple
        for item in stmt
            add_to_backedges!(backedges, slotdeps, loc, item)
        end
    # elseif isa(stmt, QuoteNode) || isa(stmt, NewvarNode) || isa(stmt, GotoNode) ||
    #        isa(stmt, Real) || isa(stmt, CodeInfo) || isa(stmt, Nothing) ||
    #        isa(stmt, Module) || isa(stmt, String) || isa(stmt, Char) || isa(stmt, Type) ||
    #        isa(stmt, LineNumberNode)
    # else
    #     error("unhandled stmt ", stmt, " of type ", typeof(stmt), " at ", loc)
    end
    return backedges
end

function toplevel_blocks(bbs::Core.Compiler.CFG)
    istoplevel = falses(length(bbs.blocks))
    next = 1
    for (i, block) in enumerate(bbs.blocks)
        if i == 1
            istoplevel[i] = true
        elseif i < next
        else
            istoplevel[i] = sum(block.preds .< i) == 2
        end
        if istoplevel[i] && !isempty(block.succs)
            next = maximum(block.succs)
        end
    end
    return istoplevel
end

function add_block_dependents!(backedges::BackEdges, bbs, istoplevel, i, bbidx)
    for s in bbs.blocks[bbidx].succs
        s > bbidx || continue  # follow only in the forward direction
        istoplevel[s] && continue
        r = bbs.blocks[s].stmts
        for j = Core.Compiler.first(r):Core.Compiler.last(r)
            push!(backedges, i=>j)
        end
        add_block_dependents!(backedges, bbs, istoplevel, i, s)
    end
    return backedges
end

"""
    backedges = BackEdges(code::CodeInfo)

Analyze `code` and determine the chain of dependencies.
`backedges.byid[i]` lists the succeeding lines that depend on `i`.
(In addition to SSAValue dependencies, this includes basic-block control flow
dependencies.)
`backedges.byname[sym]` lists the lines that depend on a particular symbol.
"""
function BackEdges(ci::CodeInfo)
    ci.inferred && error("supply lowered but not inferred code")
    bbs = Core.Compiler.compute_basic_blocks(ci.code)
    istoplevel = toplevel_blocks(bbs)
    codelocs = ci.codelocs
    n = length(ci.code)
    backedges = BackEdges(n)
    slotdeps = Vector{SlotDep}(undef, length(ci.slotnames))
    slotassign = zeros(Int, length(ci.slotnames))
    i, n = 1, length(ci.code)
    while i < n
        stmt = ci.code[i]
        if isa(stmt, Expr)
            head = stmt.head
            if head === :(=) && isslotnum(stmt.args[1])
                id = stmt.args[1].id
                slotdeps[id] = SlotDep(i, stmt.args[2], slotdeps)
                i += 1
            elseif head === :gotoifnot
                dep, _ = stmt.args
                add_to_backedges!(backedges, slotdeps, i, dep)
                # Add the non-toplevel successor basic blocks as dependents of this line
                bbidx = searchsortedlast(bbs.index, i) + 1 # bb index of this line
                add_block_dependents!(backedges, bbs, istoplevel, i, bbidx)
                i += 1
            elseif head === :thunk
                ci_thunk = stmt.args[1]
                if isa(ci_thunk, CodeInfo)
                    bethunk = BackEdges(ci_thunk)
                    for (name, uses) in bethunk.byname
                        add_to_backedges!(backedges, slotdeps, i, name)
                        if !isempty(uses.defined)
                            push!(backedges.byname[name].defined, i)
                        end
                    end
                end
                i += 1
            else
                add_to_backedges!(backedges, slotdeps, i, stmt)
                i += 1
            end
        else
            add_to_backedges!(backedges, slotdeps, i, stmt)
            i += 1
        end
    end
    return backedges
end

## Now that we can construct BackEdges, let's use them for analysis

function toplevel_chunks(backedges::BackEdges)
    be = [copy(usedby) for usedby in backedges.byid]
    n = length(be)
    for (name, uses) in backedges.byname
        isempty(uses.defined) && continue
        id = minimum(uses.ids)
        append!(be[id], uses.ids)
    end
    chunkid = collect(1:n)
    for i = n:-1:1
        if !isempty(be[i])
            chunkid[i] = maximum(chunkid[be[i]])
        end
    end
    chunks = UnitRange{Int}[]
    i = 1
    while i <= n
        push!(chunks, i:chunkid[i])
        i = chunkid[i]+1
    end
    return chunks
end

"""
    hastrackedexpr(src, chunk=1:length(src.code))

Detect whether the specified `chunk` of `src` contains a definition tracked
by Revise. By default these are methods and type definitions (the latter because
they might contain constructors).
"""
function hastrackedexpr(code::CodeInfo, chunk::AbstractUnitRange=axes(code.code, 1); heads=trackedheads)
    for stmtidx in chunk
        stmt = code.code[stmtidx]
        if isa(stmt, Expr)
            stmt.head == :call && is_global_ref(stmt.args[1], Core, :_typebody!) && return true
            stmt.head ∈ heads && return true
            if stmt.head == :thunk
                hastrackedexpr(stmt.args[1]; heads=heads) && return true
            end
        end
    end
    return false
end
