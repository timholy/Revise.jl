"""
    mexs = parse_source(filename::AbstractString, mod::Module)

Parse the source `filename`, returning a [`ModuleExprsSigs`](@ref) `mexs`.
`mod` is the "parent" module for the file (i.e., the one that `include`d the file);
if `filename` defines more module(s) then these will all have separate entries in `mexs`.

If parsing `filename` fails, `nothing` is returned.
"""
parse_source(filename, mod::Module; kwargs...) =
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
function parse_source!(mod_exprs_sigs::ModuleExprsSigs, src::AbstractString, filename::AbstractString, mod::Module; kwargs...)
    startswith(src, "# REVISE: DO NOT PARSE") && return nothing
    ex = Base.parse_input_line(src; filename=filename)
    ex === nothing && return mod_exprs_sigs
    if isexpr(ex, :error) || isexpr(ex, :incomplete)
        if Base.VERSION >= v"1.10"
            eval(ex)   # this will throw, so the statements below will not execute
        end
        prevex, pos = first_bad_position(src)
        ln = count(isequal('\n'), SubString(src, 1, min(pos, length(src)))) + 1
        throw(LoadError(filename, ln, ex.args[1]))
    end
    return process_source!(mod_exprs_sigs, ex, filename, mod; kwargs...)
end

function process_source!(mod_exprs_sigs::ModuleExprsSigs, ex, filename, mod::Module; mode::Symbol=:sigs)
    for (mod, ex) in ExprSplitter(mod, ex)
        if mode === :includet
            try
                Core.eval(mod, ex)
            catch err
                bt = trim_toplevel!(catch_backtrace())
                lnn = firstline(ex)
                loc = location_string(lnn.file, lnn.line)
                throw(ReviseEvalException(loc, err, Any[(sf, 1) for sf in stacktrace(bt)]))
            end
        end
        exprs_sigs = get(mod_exprs_sigs, mod, nothing)
        if exprs_sigs === nothing
            mod_exprs_sigs[mod] = exprs_sigs = ExprsSigs()
        end
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

if Base.VERSION < v"1.10"
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
end
