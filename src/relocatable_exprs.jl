# We will need to detect new function bodies, compare function bodies
# to see if they've changed, etc.  This has to be done "blind" to the
# line numbers at which the functions are defined.
#
# Now, we could just discard line numbers from expressions, but that
# would have a very negative effect on the quality of backtraces. So
# we keep them, but introduce machinery to compare expressions without
# concern for line numbers.
#
# To reduce the performance overhead of this package, we try to
# achieve this goal with minimal copying of data.

"""
A `RelocatableExpr` is exactly like an `Expr` except that comparisons
between `RelocatableExpr`s ignore line numbering information.

You can use `convert(Expr, rex::RelocatableExpr)` to convert to an `Expr`
and `convert(RelocatableExpr, ex::Expr)` for the converse. Beware that
the latter operates in-place and is intended only for internal use.
"""
mutable struct RelocatableExpr
    head::Symbol
    args::Vector{Any}

    RelocatableExpr(head::Symbol, args::Vector{Any}) = new(head, args)
    RelocatableExpr(head::Symbol, args...) = new(head, [args...])
end

# Works in-place and hence is unsafe. Only for internal use.
Base.convert(::Type{RelocatableExpr}, ex::Expr) = relocatable!(ex)

function relocatable!(ex::Expr)
    return RelocatableExpr(ex.head, relocatable!(ex.args))
end

function relocatable!(args::Vector{Any})
    for (i, a) in enumerate(args)
        if isa(a, Expr)
            args[i] = relocatable!(a::Expr)
        end   # do we need to worry about QuoteNodes?
    end
    args
end

function Base.convert(::Type{Expr}, rex::RelocatableExpr)
    # This makes a copy. Used for `eval`, where we don't want to
    # mutate the cached representation.
    ex = Expr(rex.head)
    ex.args = Any[a isa RelocatableExpr ? convert(Expr, a) : a for a in rex.args]
    ex
end

# Implement the required comparison functions. `hash` is needed for Dicts.
function Base.:(==)(a::RelocatableExpr, b::RelocatableExpr)
    a.head == b.head && isequal(LineSkippingIterator(a.args), LineSkippingIterator(b.args))
end

const hashrex_seed = UInt == UInt64 ? 0x7c4568b6e99c82d9 : 0xb9c82fd8
Base.hash(x::RelocatableExpr, h::UInt) = hash(LineSkippingIterator(x.args),
                                              hash(x.head, h + hashrex_seed))

function Base.show(io::IO, rex::RelocatableExpr)
    rexf = striplines!(deepcopy(rex))
    show(io, convert(Expr, rexf))
end

function striplines!(rex::RelocatableExpr)
    args = [a isa RelocatableExpr ? striplines!(a) : a for a in rex.args]
    fargs = collect(LineSkippingIterator(args))
    return RelocatableExpr(rex.head, fargs...)
end

# We could just collect all the non-line statements to a Vector, but
# doing things in-place will be more efficient.

struct LineSkippingIterator
    args::Vector{Any}
end

Base.IteratorSize(::Type{<:LineSkippingIterator}) = Base.SizeUnknown()

function Base.iterate(iter::LineSkippingIterator, i=0)
    i = skip_to_nonline(iter.args, i+1)
    i > length(iter.args) && return nothing
    return (iter.args[i], i)
end

function skip_to_nonline(args, i)
    while true
        i > length(args) && return i
        ex = args[i]
        if isa(ex, RelocatableExpr) && (ex::RelocatableExpr).head == :line
            i += 1
        elseif isa(ex, LineNumberNode)
            i += 1
        else
            return i
        end
    end
end

function Base.isequal(itera::LineSkippingIterator, iterb::LineSkippingIterator)
    # We could use `zip` here except that we want to insist that the
    # iterators also have the same length.
    reta, retb = iterate(itera), iterate(iterb)
    while true
        reta == nothing && retb == nothing && return true
        (reta == nothing || retb == nothing) && return false
        vala, ia = reta
        valb, ib = retb
        if isa(vala, RelocatableExpr) && isa(valb, RelocatableExpr)
            vala = vala::RelocatableExpr
            valb = valb::RelocatableExpr
            vala.head == valb.head || return false
            isequal(LineSkippingIterator(vala.args), LineSkippingIterator(valb.args)) || return false
        else
            isequal(vala, valb) || return false
        end
        reta, retb = iterate(itera, ia), iterate(iterb, ib)
    end
end

const hashlsi_seed = UInt == UInt64 ? 0x533cb920dedccdae : 0x2667c89b
function Base.hash(iter::LineSkippingIterator, h::UInt)
    h += hashlsi_seed
    for x in iter
        h += hash(x, h)
    end
    h
end
