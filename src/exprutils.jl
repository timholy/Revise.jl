# Much is taken from ExpressionUtils.jl but generalized to work with ExLike

using Core: MethodInstance
using Base: MethodList

const ExLike = Union{Expr,RelocatableExpr}

"""
    exf = funcdef_expr(ex)

Recurse, if necessary, into `ex` until the first function definition expression is found.

# Example

```jldoctest; setup=(using Revise), filter=r"#=.*=#"
julia> Revise.funcdef_expr(quote
       \"\"\"
       A docstring
       \"\"\"
       @inline foo(x) = 5
       end)
:(foo(x) = begin
          #= REPL[31]:5 =#
          5
      end)
```
"""
function funcdef_expr(ex)
    if ex.head == :macrocall
        if ex.args[1] isa GlobalRef && ex.args[1].name == Symbol("@doc")
            return funcdef_expr(ex.args[end])
        elseif ex.args[1] ∈ (Symbol("@inline"), Symbol("@noinline"), Symbol("@propagate_inbounds"))
            return funcdef_expr(ex.args[3])
        elseif ex.args[1] == Symbol("@eval")
            return funcdef_expr(ex.args[end])
        else
            io = IOBuffer()
            dump(io, ex)
            throw(ArgumentError(string("unrecognized macro expression:\n", String(take!(io)))))
        end
    end
    if ex.head == :block
        return funcdef_expr(first(LineSkippingIterator(ex.args)))
    end
    if ex.head == :function || ex.head == :(=)
        return ex
    end
    dump(ex)
    throw(ArgumentError(string("expected function definition expression, got ", ex)))
end

function funcdef_body(ex)
    fex = funcdef_expr(ex)
    if fex.head == :function || fex.head == :(=)
        return fex.args[end]
    end
    throw(ArgumentError(string("expected function definition expression, got ", ex)))
end

"""
    sigex = get_signature(expr)

Extract the signature from an expression `expr` that defines a function.

If `expr` does not define a function, returns `nothing`.

# Examples

```jldoctest; setup = :(using Revise)
julia> Revise.get_signature(quote
       function count_different(x::AbstractVector{T}, y::AbstractVector{S}) where {S,T}
           sum(x .!= y)
       end
       end)
:(count_different(x::AbstractVector{T}, y::AbstractVector{S}) where {S, T})
```
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
    callex = get_callexpr(sigex::ExLike)

Return the "call" expression for a signature-expression `sigex`.
(This strips out `:where` statements.)

# Example

```jldoctest; setup=:(using Revise)
julia> Revise.get_callexpr(:(nested(x::A) where A<:AbstractVector{T} where T))
:(nested(x::A))
```
"""
function get_callexpr(sigex::ExLike)
    while sigex.head == :where
        sigex = sigex.args[1]
    end
    sigex.head == :call || throw(ArgumentError(string("expected call expression, got ", sigex)))
    return sigex
end

"""
    typexs = sig_type_exprs(sigex::Expr)

From a function signature-expression `sigex` (see [`get_signature`](@ref)), generate a list
`typexs` of concrete signature type expressions.
This list will have length 1 unless `sigex` has default arguments,
in which case it will produce one type signature per valid number of supplied arguments.

These type-expressions can be evaluated in the appropriate module to obtain a Tuple-type.

# Examples

```jldoctest; setup=:(using Revise)
julia> Revise.sig_type_exprs(:(foo(x::Int, y::String)))
1-element Array{Expr,1}:
 :(Tuple{Core.Typeof(foo), Int, String})

julia> Revise.sig_type_exprs(:(foo(x::Int, y::String="hello")))
2-element Array{Expr,1}:
 :(Tuple{Core.Typeof(foo), Int})
 :(Tuple{Core.Typeof(foo), Int, String})

julia> Revise.sig_type_exprs(:(foo(x::AbstractVector{T}, y) where T))
1-element Array{Expr,1}:
 :(Tuple{Core.Typeof(foo), AbstractVector{T}, Any} where T)
```
"""
function sig_type_exprs(sigex::Expr, wheres...)
    if sigex.head == :(::)
        # return type annotation
        sigex = sigex.args[1]
    end
    if sigex.head == :where
        return sig_type_exprs(sigex.args[1], sigex.args[2:end], wheres...)
    end
    typexs = Expr[_sig_type_exprs(sigex, wheres)]
    # If the method has default arguments, generate one type signature
    # for each valid call. This replicates the syntactic sugar that defines
    # multiple methods from a single definition.
    while has_default_args(sigex)
        sigex = Expr(sigex.head, sigex.args[1:end-1]...)
        push!(typexs, _sig_type_exprs(sigex, wheres))
    end
    return reverse!(typexs)  # method table is organized in increasing # of args
end
sig_type_exprs(sigex::RelocatableExpr) = sig_type_exprs(convert(Expr, sigex))

function _sig_type_exprs(ex, @nospecialize(wheres))
    fex = ex.args[1]
    if isa(fex, Expr) && fex.head == :(::)
        fexTex = fex.args[end]
    else
        fexTex = :(Core.Typeof($fex))
    end
    sigex = Expr(:curly, :Tuple, fexTex, argtypeexpr(ex.args[2:end]...)...)
    for w in wheres
        sigex = Expr(:where, sigex, w...)
    end
    sigex
end

"""
    typeex1, typeex2, ... = argtypeexpr(ex...)

Return expressions that specify the types assigned to each argument in a method signature.
Returns `:Any` if no type is assigned to a specific argument. It also skips
keyword arguments.

`ex...` should be arguments `2:end` of a `:call` expression (i.e., skipping over the
function name).

# Examples

```jldoctest; setup=:(using Revise), filter=r"#=.*=#"
julia> sigex = :(varargs(x, rest::Int...))
:(varargs(x, rest::Int...))

julia> Revise.argtypeexpr(Revise.get_callexpr(sigex).args[2:end]...)
(:Any, :(Vararg{Int}))

julia> sigex = :(complexargs(w::Vector{T}, @nospecialize(x::Integer), y, z::String=""; kwarg::Bool=false) where T)
:(complexargs(w::Vector{T}, #= REPL[39]:1 =# @nospecialize(x::Integer), y, z::String=""; kwarg::Bool=false) where T)

julia> Revise.argtypeexpr(Revise.get_callexpr(sigex).args[2:end]...)
(:(Vector{T}), :Integer, :Any, :String)
```
"""
function argtypeexpr(ex::ExLike, rest...)
    # Handle @nospecialize(x)
    if ex.head == :macrocall
        return (argtypeexpr(ex.args[3])..., argtypeexpr(rest...)...)
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
argtypeexpr(s::Symbol, rest...) = (:Any, argtypeexpr(rest...)...)
argtypeexpr() = ()

function has_default_args(sigex::Expr)
    a = sigex.args[end]
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
    isa(stmt, LineNumberNode) || (isa(stmt, ExLike) && (stmt.head == :line))
end

function firstlineno(rex::ExLike)
    for a in rex.args
        if is_linenumber(a)
            isa(a, LineNumberNode) && return a.line
            return a.args[1]
        end
        if isa(a, ExLike)
            lineno = firstlineno(a)
            isa(lineno, Integer) && return lineno
        end
    end
    return nothing
end

