# We will need to detect new function bodies, compare function bodies
# to see if they've changed, etc.  This has to be done "blind" to the
# line numbers at which the functions are defined.
#
# Now, we could just discard line numbers from expressions, but that
# would have a very negative effect on the quality of backtraces. So
# we keep them, but introduce machinery to compare expressions without
# concern for line numbers.

"""
A `RelocatableExpr` wraps an `Expr` to ensure that comparisons
between `RelocatableExpr`s ignore line numbering information.
This allows one to detect that two expressions are the same no matter
where they appear in a file.
"""
struct RelocatableExpr
    ex::Expr
end

const ExLike = Union{Expr,RelocatableExpr}

Base.convert(::Type{Expr}, rex::RelocatableExpr) = rex.ex
Base.convert(::Type{RelocatableExpr}, ex::Expr) = RelocatableExpr(ex)
# Expr(rex::RelocatableExpr) = rex.ex   # too costly (inference invalidation)

Base.copy(rex::RelocatableExpr) = RelocatableExpr(copy(rex.ex))

# Implement the required comparison functions. `hash` is needed for Dicts.
function Base.:(==)(ra::RelocatableExpr, rb::RelocatableExpr)
    a, b = ra.ex, rb.ex
    if a.head == b.head
    elseif a.head === :block
        a = unwrap(a)
    elseif b.head === :block
        b = unwrap(b)
    end
    return a.head == b.head && isequal(LineSkippingIterator(a.args), LineSkippingIterator(b.args))
end

const hashrex_seed = UInt == UInt64 ? 0x7c4568b6e99c82d9 : 0xb9c82fd8
Base.hash(x::RelocatableExpr, h::UInt) = hash(LineSkippingIterator(x.ex.args),
                                              hash(x.ex.head, h + hashrex_seed))

function Base.show(io::IO, rex::RelocatableExpr)
    show(io, striplines!(copy(rex.ex)))
end

function striplines!(ex::Expr)
    if ex.head === :macrocall
        # for macros, the show method in Base assumes the line number is there,
        # so don't strip it
        args3 = [a isa ExLike ? striplines!(a) : a for a in ex.args[3:end]]
        return Expr(ex.head, ex.args[1], nothing, args3...)
    end
    args = [a isa ExLike ? striplines!(a) : a for a in ex.args]
    fargs = collect(LineSkippingIterator(args))
    return Expr(ex.head, fargs...)
end
striplines!(rex::RelocatableExpr) = RelocatableExpr(striplines!(rex.ex))

# We could just collect all the non-line statements to a Vector, but
# doing things in-place will be more efficient.

struct LineSkippingIterator
    args::Vector{Any}
end

Base.IteratorSize(::Type{LineSkippingIterator}) = Base.SizeUnknown()

function Base.iterate(iter::LineSkippingIterator, i=0)
    i = skip_to_nonline(iter.args, i+1)
    i > length(iter.args) && return nothing
    return (iter.args[i], i)
end

function skip_to_nonline(args, i)
    while true
        i > length(args) && return i
        ex = args[i]
        if isa(ex, Expr) && ex.head === :line
            i += 1
        elseif isa(ex, LineNumberNode)
            i += 1
        elseif isa(ex, Pair) && (ex::Pair).first === :linenumber     # used in the doc system
            i += 1
        elseif isa(ex, Base.RefValue) && !isdefined(ex, :x)          # also in the doc system
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
        reta === nothing && retb === nothing && return true
        (reta === nothing || retb === nothing) && return false
        vala, ia = reta::Tuple{Any,Int}
        valb, ib = retb::Tuple{Any,Int}
        if isa(vala, Expr) && isa(valb, Expr)
            vala, valb = vala::Expr, valb::Expr
            vala.head == valb.head || return false
            isequal(LineSkippingIterator(vala.args), LineSkippingIterator(valb.args)) || return false
        elseif isa(vala, Symbol) && isa(valb, Symbol)
            vala, valb = vala::Symbol, valb::Symbol
            # two gensymed symbols do not need to match
            sa, sb = String(vala), String(valb)
            (startswith(sa, '#') && startswith(sb, '#')) || isequal(vala, valb) || return false
        elseif isa(vala, Number) && isa(valb, Number)
            vala === valb || return false    # issue #233
        else
            isequal(vala, valb) || return false
        end
        reta, retb = iterate(itera, ia), iterate(iterb, ib)
    end
end

const hashlsi_seed = UInt === UInt64 ? 0x533cb920dedccdae : 0x2667c89b
function Base.hash(iter::LineSkippingIterator, h::UInt)
    h += hashlsi_seed
    for x in iter
        if x isa Expr
            h += hash(LineSkippingIterator(x.args), hash(x.head, h + hashrex_seed))
        elseif x isa Symbol
            xs = String(x)
            if startswith(xs, '#')  # all gensymmed symbols are treated as identical
                h += hash("gensym", h)
            else
                h += hash(x, h)
            end
        elseif x isa Number
            h += hash(typeof(x), hash(x, h))::UInt
        else
            h += hash(x, h)::UInt
        end
    end
    h
end
