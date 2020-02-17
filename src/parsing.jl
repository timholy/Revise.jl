"""
    mexs = parse_source(filename::AbstractString, mod::Module)

Parse the source `filename`, returning a [`ModuleExprsSigs`](@ref) `mexs`.
`mod` is the "parent" module for the file (i.e., the one that `include`d the file);
if `filename` defines more module(s) then these will all have separate entries in `mexs`.

If parsing `filename` fails, `nothing` is returned.
"""
parse_source(filename::AbstractString, mod::Module) =
    parse_source!(ModuleExprsSigs(mod), filename, mod)

"""
    parse_source!(mexs::ModuleExprsSigs, filename, mod::Module)

Top-level parsing of `filename` as included into module
`mod`. Successfully-parsed expressions will be added to `mexs`. Returns
`mexs` if parsing finished successfully, otherwise `nothing` is returned.

See also [`Revise.parse_source`](@ref).
"""
function parse_source!(mod_exprs_sigs::ModuleExprsSigs, filename::AbstractString, mod::Module)
    if !isfile(filename)
        @warn "$filename is not a file, omitting from revision tracking"
        return nothing
    end
    parse_source!(mod_exprs_sigs, read(filename, String), filename, mod)
end

"""
    success = parse_source!(mod_exprs_sigs::ModuleExprsSigs, src::AbstractString, filename::AbstractString, mod::Module)

Parse a string `src` obtained by reading `file` as a single
string. `pos` is the 1-based byte offset from which to begin parsing `src`.

See also [`Revise.parse_source`](@ref).
"""
function parse_source!(mod_exprs_sigs::ModuleExprsSigs, src::AbstractString, filename::AbstractString, mod::Module)
    startswith(src, "# REVISE: DO NOT PARSE") && return nothing
    ex = Base.parse_input_line(src; filename=filename)
    ex === nothing && return mod_exprs_sigs
    if isexpr(ex, :error) || isexpr(ex, :incomplete)
        prevex, pos = first_bad_position(src)
        ln = count(isequal('\n'), SubString(src, 1, pos)) + 1
        throw(LoadError(filename, ln, ex.args[1]))
    end
    modexs, docexprs = Tuple{Module,Expr}[], DocExprs()
    JuliaInterpreter.split_expressions!(modexs, docexprs, mod, ex; extract_docexprs=true)
    for (mod, ex) in modexs
        exprs_sigs = get(mod_exprs_sigs, mod, nothing)
        if exprs_sigs === nothing
            mod_exprs_sigs[mod] = exprs_sigs = ExprsSigs()
        end
        # exprs_sigs[unwrap(ex)] = nothing
        exprs_sigs[ex] = nothing
    end
    for (mod, docexs) in docexprs
        exprs_sigs = get(mod_exprs_sigs, mod, nothing)
        for dex in docexs
            if length(dex.args) < 5
                push!(dex.args, false)  # Don't redefine
            else
                dex.args[5] = false
            end
            exprs_sigs[unwrap(dex)] = nothing
            # exprs_sigs[dex] = nothing
        end
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
