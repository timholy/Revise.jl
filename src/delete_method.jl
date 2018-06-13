### Core functionality for method deletion
using Core: MethodInstance
using Base: MethodList

### Parsing expressions to determine which method to delete
const ExLike = Union{Expr,RelocatableExpr}
# Much is taken from ExpressionUtils.jl but generalized to work with ExLike

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

function get_method(mod::Module, sig::ExLike)
    t = split_sig(mod, convert(Expr, sig))
    mths = Base._methods_by_ftype(t, -1, typemax(UInt))
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
    @warn "Revise failed to find any methods for signature $t\n  Most likely it was already deleted."
    nothing
end

function split_sig(mod::Module, ex::Expr)
    t = split_sig_expr(mod, ex)
    return Core.eval(mod, t) # fex), Core.eval(mod, argex)
end

function split_sig_expr(mod::Module, ex::Expr, wheres...)
    if ex.head == :where
        return split_sig_expr(mod, ex.args[1], ex.args[2:end], wheres...)
    end
    fex = ex.args[1]
    sigex = Expr(:curly, :Tuple, :(Core.Typeof($fex)), argtypeexpr(ex.args[2:end]...)...)
    for w in wheres
        sigex = Expr(:where, sigex, w...)
    end
    sigex
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
    (isa(stmt, ExLike) & (stmt.head == :line)) | isa(stmt, LineNumberNode)
end

argtypeexpr(s::Symbol, rest...) = (:Any, argtypeexpr(rest...)...)
function argtypeexpr(ex::ExLike, rest...)
    # Handle @nospecialize(x)
    if ex.head == :macrocall
        return argtypeexpr(ex.args[3])
    end
    if ex.head == :...
        # Handle varargs
        return (:(Vararg{$(argtypeexpr(ex.args[1]))}), argtypeexpr(rest...)...)
    end
    # Skip over keyword arguments
    ex.head == :parameters && return argtypeexpr(rest...)
    # Should be a type specification, check and then return the type
    ex.head == :(::) || throw(ArgumentError("expected :(::) expression, got ex.head = $(ex.head)"))
    1 <= length(ex.args) <= 2 || throw(ArgumentError("expected 1 or 2 args, got $(ex.args)"))
    return (ex.args[end], argtypeexpr(rest...)...)
end
argtypeexpr() = ()
