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

function skip_to_nonline(args::Vector{Any}, i::Int)
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

# Gensym counters do not reproduce across runs of macro expansion or lowering,
# so two structurally identical expressions can differ in the numeric part of
# generated names. Comparison and hashing therefore ignore the counters — but
# only the counters: the base name must match exactly, and the pairing between
# generated names must be consistent across the whole expression (wherever one
# expression repeats a generated name, the other must repeat the corresponding
# name). `'#'`-prefixed names without a counter (`var"#self#"`, a user's
# var"#x") are reproducible and compare exactly, like any other symbol; this
# keeps distinct global bindings distinct as `ExprsInfos` keys.

const anonymous_gensym_rex = r"^#+(\d+)$"        # gensym(): "##277"
const suffixed_gensym_rex  = r"^#+(.*)#(\d+)$"   # gensym(:name): "##name#123"; closures: "#f#42"; anonymous closures: "#1#2"
const hygiene_gensym_rex   = r"^#(?:\d+#)+(.+)$" # macro hygiene: "#28#t0"

"""
    base, iscounter = gensym_base(str)

Classify a `'#'`-prefixed variable name. If `str` contains a gensym counter
(`"##name#123"`, `"#f#42"`, `"#28#t0"`, `"##277"`, `"#1#2"`), return the
non-counter part of the name and `iscounter = true`; names that are purely
counters return `base = ""`. Otherwise (`"#self#"`, `"#x"`, ...) the name is
reproducible: return it unmodified, with `iscounter = false`.
"""
function gensym_base(str::AbstractString)
    m = match(anonymous_gensym_rex, str)
    m !== nothing && return "", true
    m = match(suffixed_gensym_rex, str)
    if m !== nothing
        base = m.captures[1]::AbstractString
        return (all(isdigit, base) ? "" : String(base)), true
    end
    m = match(hygiene_gensym_rex, str)
    m !== nothing && return String(m.captures[1]::AbstractString), true
    return String(str), false
end

# Correspondence between the counter-bearing generated names of two expressions
# under comparison. Consistency requires a bijection, so both directions are tracked.
struct GensymPairing
    fwd::Dict{Symbol,Symbol}
    rev::Dict{Symbol,Symbol}
end
GensymPairing() = GensymPairing(Dict{Symbol,Symbol}(), Dict{Symbol,Symbol}())

function isequal_sym(pairing::GensymPairing, a::Symbol, b::Symbol)
    sa, sb = String(a), String(b)
    if startswith(sa, '#') && startswith(sb, '#')
        basea, countera = gensym_base(sa)
        baseb, counterb = gensym_base(sb)
        countera == counterb || return false
        countera || return a === b
        basea == baseb || return false
        # the same pairing must hold at every occurrence, even when a === b
        return get!(pairing.fwd, a, b) === b && get!(pairing.rev, b, a) === a
    end
    return a === b
end

function Base.isequal(itera::LineSkippingIterator, iterb::LineSkippingIterator)
    return isequal_lsi(GensymPairing(), itera, iterb)
end

function isequal_lsi(pairing::GensymPairing, itera::LineSkippingIterator, iterb::LineSkippingIterator)
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
            isequal_lsi(pairing, LineSkippingIterator(vala.args), LineSkippingIterator(valb.args)) || return false
        elseif isa(vala, Symbol) && isa(valb, Symbol)
            isequal_sym(pairing, vala::Symbol, valb::Symbol) || return false
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
    return hash_lsi(Dict{Symbol,Int}(), iter, h)
end

function hash_lsi(gensym_indices::Dict{Symbol,Int}, iter::LineSkippingIterator, h::UInt)
    h += hashlsi_seed
    for x in iter
        if x isa Expr
            h += hash_lsi(gensym_indices, LineSkippingIterator(x.args), hash(x.head, h + hashrex_seed))
        elseif x isa Symbol
            xs = String(x)
            if startswith(xs, '#')
                base, iscounter = gensym_base(xs)
                if iscounter
                    # hash the base name and the order of first occurrence;
                    # this matches `isequal_sym`'s counter-insensitive pairing
                    idx = get!(gensym_indices, x, length(gensym_indices) + 1)
                    h += hash(base, hash(idx, h))
                    continue
                end
            end
            h += hash(x, h)
        elseif x isa Number
            h += hash(typeof(x), hash(x, h))::UInt
        else
            h += hash(x, h)::UInt
        end
    end
    h
end
