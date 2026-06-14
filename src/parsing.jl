"""
    ParseResult(modexinfos, success, donotparse=false, [ret])

The outcome of [`parse_and_maybe_eval_source`](@ref):

- `modexinfos::ModuleExprsInfos`: the per-module expression map. The `!` form adds to it in place.
- `success::Bool`: `false` if parsing produced no usable expressions, e.g. a missing file or a
  source consisting only of a top-level literal.
- `donotparse::Bool`: `true` if the source begins with `# REVISE: DO NOT PARSE` and was therefore
  left unparsed.
- `ret`: the value of the last evaluated expression, set only in `:includet` mode (see [`includet`](@ref)).
  Left undefined (`isdefined(pr, :ret) === false`) when nothing was evaluated.
"""
struct ParseResult
    modexinfos::ModuleExprsInfos
    success::Bool
    donotparse::Bool
    ret
    ParseResult(modexinfos::ModuleExprsInfos, success::Bool, donotparse::Bool=false) =
        new(modexinfos, success, donotparse)
    ParseResult(modexinfos::ModuleExprsInfos, success::Bool, donotparse::Bool, @nospecialize(ret)) =
        new(modexinfos, success, donotparse, ret)
end

"""
    pr = parse_and_maybe_eval_source(filename::AbstractString, mod::Module; mode=:sigs)

Parse the source `filename`, returning a [`ParseResult`](@ref) `pr`.
`mod` is the "parent" module for the file (i.e., the one that `include`d the file);
if `filename` defines more module(s) then these will all have separate entries in `pr.modexinfos`.

In `:includet` mode the expressions are also evaluated as they are parsed, and `pr.ret` holds the
value of the last one.
"""
parse_and_maybe_eval_source(filename::AbstractString, mod::Module; mode::Symbol=:sigs) =
    parse_and_maybe_eval_source!(ModuleExprsInfos(mod), filename, mod; mode)

"""
    pr = parse_and_maybe_eval_source!(modexinfos::ModuleExprsInfos, filename, mod::Module; mode=:sigs)

Top-level parsing of `filename` as included into module `mod`. Successfully-parsed expressions are
added to `modexinfos`, which is also returned as `pr.modexinfos`. In `:includet` mode the expressions
are evaluated as they are parsed.

See also [`Revise.parse_and_maybe_eval_source`](@ref).
"""
function parse_and_maybe_eval_source!(modexinfos::ModuleExprsInfos, filename::AbstractString, mod::Module; mode::Symbol=:sigs)
    if !isfile(filename)
        @warn "$filename is not a file, omitting from revision tracking"
        return ParseResult(modexinfos, false)
    end
    return parse_and_maybe_eval_source!(modexinfos, read(filename, String), filename, mod; mode)
end

function parse_and_maybe_eval_source!(modexinfos::ModuleExprsInfos, src::AbstractString, filename::AbstractString, mod::Module; mode::Symbol=:sigs)
    if startswith(src, "# REVISE: DO NOT PARSE")
        return ParseResult(modexinfos, true, true)
    end
    if VERSION ≥ v"1.14-DEV.1836"
        ex = Base.parse_input_line(src; filename, mod)
    else
        ex = Base.parse_input_line(src; filename)
    end
    if ex === nothing
        return ParseResult(modexinfos, true)
    elseif ex isa Expr
        # issue #783: in `:includet` mode `process_ex!` returns the value of the last evaluated
        # expression, which `includet` returns like `include`.
        ret = process_ex!(modexinfos, ex, filename, mod; mode)
        return mode === :includet ? ParseResult(modexinfos, true, false, ret) : ParseResult(modexinfos, true)
    else # literals
        return ParseResult(modexinfos, false)
    end
end

function process_ex!(mod_exprs_sigs::ModuleExprsInfos, ex::Expr, filename::AbstractString, mod::Module; mode::Symbol=:sigs)
    if isexpr(ex, :error) || isexpr(ex, :incomplete)
        return eval(ex)
    end
    lastval = nothing
    for (mod, ex) in ExprSplitter(mod, ex)
        if mode === :includet
            try
                lastval = Core.eval(mod, ex)
            catch err
                bt = trim_toplevel!(catch_backtrace())
                lnn = firstline(ex)
                loc = location_string((lnn.file, lnn.line))
                throw(ReviseEvalException(loc, err, Any[(sf, 1) for sf in stacktrace(bt)]))
            end
        end
        exprs_sigs = get!(ExprsInfos, mod_exprs_sigs, mod)
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
    # issue #783: the value of the last evaluated expression, so `includet` can
    # return it like `include`. Only `:includet` mode evaluates; otherwise `nothing`.
    return lastval
end
