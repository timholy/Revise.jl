### Core functionality for method deletion
using Core: MethodInstance
using Base: MethodList

### Parsing expressions to determine which method to delete
const ExLike = Union{Expr,RelocatableExpr}
# Much is taken from ExpressionUtils.jl but generalized to work with ExLike

"""
    m = get_method(mod::Module, sig)

Get the method `m` with signature `sig` from module `mod`. This is used to provide
the method to `Base.delete_method`. See also [`get_signature`](@ref).
"""
function get_method(mod::Module, sig::ExLike)::Method
    t = Core.eval(mod, convert(Expr, sig))
    mths = Base._methods_by_ftype(t, -1, typemax(UInt))
    length(mths) == 1 && return mths[1][3]
    if !isempty(mths)
        # There might be many methods, but the one that should match should be the
        # last one, since methods are ordered by specificity
        i = lastindex(mths)
        while i > 0
            m = mths[i][3]
            m.sig == t && return m
            i -= 1
        end
    end
    io = IOBuffer()
    println(io, "signature:")
    dump(io, convert(Expr, sig))
    println(io, "Extracted method table:")
    println(io, mths)
    info = String(take!(io))
    @warn "Revise failed to find any methods for signature $t\n  Most likely it was already deleted.\n$info"
    nothing
end

"""
    sig = get_signature(expr)

Extract the signature from an expression `expr` that defines a function.

If `expr` does not define a function, returns `nothing`.
"""
function get_signature(ex::E) where E <: ExLike
    while ex.head == :macrocall && isa(ex.args[end], E) || is_trivial_block_wrapper(ex)
        ex = ex.args[end]::E
    end
    if ex.head == :function
        return ex.args[1]
    elseif ex.head == :(=) && isa(ex.args[1], E)
        ex = ex.args[1]::E
        if ex.head == :where || ex.head == :call
            return ex
        end
    end
    nothing
end

"""
    typexs = sig_type_exprs(ex::Expr)

From a function signature `ex` (see [`get_signature`](@ref)), generate a list `typexs` of
concrete signature type expressions.
This list will have length 1 unless `ex` has default arguments,
in which case it will produce one type signature per valid number of supplied arguments.

These type-expressions can be evaluated in the appropriate module to obtain a Tuple-type.

# Examples

```julia
julia> Revise.sig_type_exprs(:(foo(x::Int, y::String)))
1-element Array{Expr,1}:
:(Tuple{Core.Typeof(foo), Int, String})

julia> Revise.sig_type_exprs(:(foo(x::Int, y::String="hello")))
2-element Array{Expr,1}:
 :(Tuple{Core.Typeof(foo), Int})
 :(Tuple{Core.Typeof(foo), Int, String})
```
"""
function sig_type_exprs(ex::Expr, wheres...)
    if ex.head == :where
        return sig_type_exprs(ex.args[1], ex.args[2:end], wheres...)
    end
    typexs = Expr[_sig_type_exprs(ex, wheres)]
    # If the method has default arguments, generate one type signature
    # for each valid call. This replicates the syntactic sugar that defines
    # multiple methods from a single definition.
    while has_default_args(ex)
        ex = Expr(ex.head, ex.args[1:end-1]...)
        push!(typexs, _sig_type_exprs(ex, wheres))
    end
    return reverse!(typexs)  # method table is organized in increasing # of args
end
sig_type_exprs(ex::RelocatableExpr) = sig_type_exprs(convert(Expr, ex))

function _sig_type_exprs(ex, @nospecialize(wheres))
    fex = ex.args[1]
    sigex = Expr(:curly, :Tuple, :(Core.Typeof($fex)), argtypeexpr(ex.args[2:end]...)...)
    for w in wheres
        sigex = Expr(:where, sigex, w...)
    end
    sigex
end

function has_default_args(ex::Expr)
    a = ex.args[end]
    return isa(a, Expr) && a.head == :kw
end

function is_trivial_block_wrapper(ex::ExLike)
    if ex.head == :block
        return length(ex.args) == 1 ||
            (length(ex.args) == 2 && (is_linenumber(ex.args[1]) || ex.args[1]===nothing))
    end
    false
end
is_trivial_block_wrapper(@nospecialize arg) = false

function is_linenumber(@nospecialize stmt)
    isa(stmt, LineNumberNode) || (isa(stmt, ExLike) & (stmt.head == :line))
end

argtypeexpr(s::Symbol, rest...) = (:Any, argtypeexpr(rest...)...)
function argtypeexpr(ex::ExLike, rest...)
    # Handle @nospecialize(x)
    if ex.head == :macrocall
        return argtypeexpr(ex.args[3])
    end
    if ex.head == :...
        # Handle varargs (those expressed with dots rather than Vararg{T,N})
        @assert isempty(rest)
        @assert length(ex.args) == 1
        T = argtypeexpr(ex.args[1])[1]
        return (:(Vararg{$T}),)
    end
    # Skip over keyword arguments
    ex.head == :parameters && return argtypeexpr(rest...)
    # Handle default arguments
    (ex.head == :(=) || ex.head == :kw) && return (argtypeexpr(ex.args[1])..., argtypeexpr(rest...)...)
    # Handle a destructured argument like foo(x, (count, name))
    ex.head == :tuple && return (:Any, argtypeexpr(rest...)...)
    # Should be a type specification, check and then return the type
    ex.head == :(::) || throw(ArgumentError("expected :(::) expression, got $ex"))
    1 <= length(ex.args) <= 2 || throw(ArgumentError("expected 1 or 2 args, got $(ex.args)"))
    return (ex.args[end], argtypeexpr(rest...)...)
end
argtypeexpr() = ()
