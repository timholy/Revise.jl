struct DoNotParse end

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
    return parse_source!(mod_exprs_sigs, read(filename, String), filename, mod; kwargs...)
end

function parse_source!(mod_exprs_sigs::ModuleExprsSigs, src::AbstractString, filename::AbstractString, mod::Module; kwargs...)
    if startswith(src, "# REVISE: DO NOT PARSE")
        return DoNotParse()
    end
    ex = Base.parse_input_line(src; filename)
    if ex === nothing
        return mod_exprs_sigs
    elseif ex isa Expr
        return process_ex!(mod_exprs_sigs, ex, filename, mod; kwargs...)
    else # literals
        return nothing
    end
end

function process_ex!(mod_exprs_sigs::ModuleExprsSigs, ex::Expr, filename::AbstractString, mod::Module; mode::Symbol=:sigs)
    if isexpr(ex, :error) || isexpr(ex, :incomplete)
        return eval(ex)
    end
    for (mod, ex) in ExprSplitter(mod, ex)
        if mode === :includet
            try
                Core.eval(mod, ex)
            catch err
                bt = trim_toplevel!(catch_backtrace(), @__MODULE__)
                lnn = firstline(ex)
                loc = location_string((lnn.file, lnn.line))
                throw(ReviseEvalException(loc, err, Any[(sf, 1) for sf in stacktrace(bt)]))
            end
        end
        exprs_sigs = get!(ExprsSigs, mod_exprs_sigs, mod)
        if ex.head === :toplevel
            lnn = nothing
            for a in ex.args
                if isa(a, LineNumberNode)
                    lnn = a
                else
                    pushex!(exprs_sigs, Expr(:toplevel, lnn, a))
                end
            end
        else
            pushex!(exprs_sigs, ex)
        end
    end
    return mod_exprs_sigs
end
