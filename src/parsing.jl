"""
    mexs = parse_source(filename::AbstractString, mod::Module)

Parse the source `filename`, returning a [`ModuleExprsSigs`](@ref) `mexs`.
`mod` is the "parent" module for the file (i.e., the one that `include`d the file);
if `filename` defines more module(s) then these will all have separate entries in `mexs`.

If parsing `filename` fails, `nothing` is returned.
"""
parse_source(filename::AbstractString, mod::Module; kwargs...) =
    parse_source!(ModuleExprsSigs(mod), filename, mod; kwargs...)

"""
    parse_source!(mexs::ModuleExprsSigs, filename, mod::Module)

Top-level parsing of `filename` as included into module
`mod`. Successfully-parsed expressions will be added to `mexs`. Returns
`mexs` if parsing finished successfully, otherwise `nothing` is returned.

See also [`Revise.parse_source`](@ref).
"""
function parse_source!(mod_exprs_sigs::ModuleExprsSigs, filename::AbstractString, mod::Module; kwargs...)
    if !isfile(filename)
        @warn "$filename is not a file, omitting from revision tracking"
        return nothing
    end
    parse_source!(mod_exprs_sigs, read(filename, String), filename, mod; kwargs...)
end

"""
    success = parse_source!(mod_exprs_sigs::ModuleExprsSigs, src::AbstractString, filename::AbstractString, mod::Module)

Parse a string `src` obtained by reading `file` as a single
string. `pos` is the 1-based byte offset from which to begin parsing `src`.

See also [`Revise.parse_source`](@ref).
"""
function parse_source!(mod_exprs_sigs::ModuleExprsSigs, src::AbstractString, filename::AbstractString, mod::Module; mode::Symbol=:sigs)
    startswith(src, "# REVISE: DO NOT PARSE") && return nothing
    ex = Base.parse_input_line(src; filename=filename)
    ex === nothing && return mod_exprs_sigs
    if isexpr(ex, :error) || isexpr(ex, :incomplete)
        prevex, pos = first_bad_position(src)
        ln = count(isequal('\n'), SubString(src, 1, min(pos, length(src)))) + 1
        throw(LoadError(filename, ln, ex.args[1]))
    end
    modexs, docexprs = Tuple{Module,Expr}[], DocExprs()
    for (mod, ex) in ExprSplitter(mod, ex)
        mode === :includet && Core.eval(mod, ex)
        exprs_sigs = get(mod_exprs_sigs, mod, nothing)
        if exprs_sigs === nothing
            mod_exprs_sigs[mod] = exprs_sigs = ExprsSigs()
        end
        uex = unwrap(ex)
        if is_doc_expr(uex)
            body = uex.args[4]
            if isa(body, Expr) && body.head !== :call   # don't trigger for docexprs like `"docstr" f(x::Int)`
                exprs_sigs[body] = nothing
            end
            if length(uex.args) < 5
                push!(uex.args, false)
            else
                uex.args[5] = false
            end
        end
        exprs_sigs[ex] = nothing
    end
    return mod_exprs_sigs
end

function first_bad_position(str)
    ex, pos, n = nothing, 1, length(str)
    while pos < n
        ex, pos = Meta.parse(str, pos; greedy=true, raise=false)
        if isexpr(ex, :error) || isexpr(ex, :incomplete)
            return ex, pos
        end
    end
    error("expected an error, finished without one")
end
