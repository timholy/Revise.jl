const ExprsSigs = OrderedDict{RelocatableExpr,Union{Nothing,Vector{Any}}}

function Base.show(io::IO, exsigs::ExprsSigs)
    compact = get(io, :compact, false)
    if compact
        n = 0
        for (rex, sigs) in exsigs
            sigs === nothing && continue
            n += length(sigs)
        end
        print(io, "ExprsSigs(<$(length(exsigs)) expressions>, <$n signatures>)")
    else
        print(io, "ExprsSigs with the following expressions: ")
        for def in keys(exsigs)
            print(io, "\n  ")
            Base.show_unquoted(io, RelocatableExpr(unwrap(def)), 2)
        end
    end
end

"""
    is_global_ref(g, mod, name)

Tests whether `g` is equal to `GlobalRef(mod, name)`.
"""
is_global_ref(@nospecialize(g), mod::Module, name::Symbol) =
    isa(g, GlobalRef) && g.mod === mod && g.name == name

"""
    is_doc_expr(ex)

Test whether expression `ex` is a `@doc` expression.
"""
function is_doc_expr(@nospecialize(ex))
    docsym = Symbol("@doc")
    if isexpr(ex, :macrocall)
        ex::Expr
        length(ex.args) == 4 || return false
        a = ex.args[1]
        if isa(a, Symbol) && a === docsym
            return true
        elseif is_global_ref(a, Core, docsym)
            return true
        elseif isexpr(a, :.)
            mod, name = (a::Expr).args[1], (a::Expr).args[2]
            return mod === :Core && isa(name, QuoteNode) && name.value === docsym
        end
    end
    return false
end

function unwrap_where(ex::Expr)
    while isexpr(ex, :where)
        ex = ex.args[1]
    end
    return ex
end

function pushex!(exsigs::ExprsSigs, ex::Expr)
    uex = unwrap(ex)
    if is_doc_expr(uex)
        body = uex.args[4]
        # Don't trigger for exprs where the documented expression is just a signature
        # (e.g. `"docstr" f(x::Int)`, `"docstr" f(x::T) where T` etc.)
        if isa(body, Expr) && unwrap_where(body).head !== :call
            exsigs[RelocatableExpr(body)] = nothing
        end
        if length(uex.args) < 5
            push!(uex.args, false)
        else
            uex.args[5] = false
        end
    end
    exsigs[RelocatableExpr(ex)] = nothing
    return exsigs
end

"""
    ModuleExprsSigs

For a particular source file, the corresponding `ModuleExprsSigs` is a mapping
`mod=>exprs=>sigs` of the expressions `exprs` found in `mod` and the signatures `sigs`
that arise from them. Specifically, if `mes` is a `ModuleExprsSigs`, then `mes[mod][ex]`
is a list of signatures that result from evaluating `ex` in `mod`. It is possible that
this returns `nothing`, which can mean either that `ex` does not define any methods
or that the signatures have not yet been cached.

The first `mod` key is guaranteed to be the module into which this file was `include`d.

To create a `ModuleExprsSigs` from a source file, see [`Revise.parse_source`](@ref).
"""
const ModuleExprsSigs = OrderedDict{Module,ExprsSigs}

function Base.typeinfo_prefix(io::IO, mexs::ModuleExprsSigs)
    tn = typeof(mexs).name
    return string(tn.module, '.', tn.name), true
end

"""
    fm = ModuleExprsSigs(mod::Module)

Initialize an empty `ModuleExprsSigs` for a file that is `include`d into `mod`.
"""
ModuleExprsSigs(mod::Module) = ModuleExprsSigs(mod=>ExprsSigs())

Base.isempty(fm::ModuleExprsSigs) = length(fm) == 1 && isempty(first(values(fm)))
