module ReviseREPLExt

using REPL: REPL
using Base: PkgId
using Base.Meta: isexpr
using Revise: @warnpcfail, FileInfo, ModuleExprsInfos, Revise, instantiate_sigs!,
    is_quotenode_egal, parse_and_maybe_eval_source!, pkgdatas, revise, revise_first,
    revise_lock, revision_queue, unwrap

const original_repl_prefix = Ref{Union{String, Function, Nothing}}(nothing)

Revise.revise(::REPL.REPLBackend) = revise()

# Check if the active REPL backend is available
active_repl_backend_available() = isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing

function maybe_set_prompt_color_impl(color::Symbol)
    if isdefined(Base, :active_repl)
        return set_prompt_color!(color, Base.active_repl)
    end
    return nothing
end

function set_prompt_color!(color, repl)
    if isa(repl, REPL.LineEditREPL) && isdefined(repl, :interface)
        # Always recolor the `julia>` prompt, never whatever mode happens to
        # be active, so a revision error raised while in shell/help/pkg mode
        # does not leak that mode's color onto `julia>` (issue #755).
        julia_prompt = repl.interface.modes[1]
        if color === :warn
            # First save the original setting
            if original_repl_prefix[] === nothing
                original_repl_prefix[] = julia_prompt.prompt_prefix
            end
            julia_prompt.prompt_prefix = "\e[33m"  # yellow
        else
            color = original_repl_prefix[]
            color === nothing && return nothing
            julia_prompt.prompt_prefix = color
            original_repl_prefix[] = nothing
        end
    end
    return nothing
end

function add_definitions_from_repl_impl(filename::String)
    hist_idx = parse(Int, filename[6:end-1])
    hp = (Base.active_repl::REPL.LineEditREPL).interface.modes[1].hist::REPL.REPLHistoryProvider
    entry = hp.history[hp.start_idx+hist_idx]
    src = entry isa AbstractString ? entry : entry.content
    id = PkgId(nothing, "@REPL")
    pkgdata = @lock revise_lock pkgdatas[id]
    mod_exs_infos = ModuleExprsInfos(Main::Module)
    parse_and_maybe_eval_source!(mod_exs_infos, src, filename, Main::Module)
    instantiate_sigs!(mod_exs_infos)
    fi = FileInfo(mod_exs_infos)
    push!(pkgdata, filename=>fi)
    return fi
end
add_definitions_from_repl_impl(filename::AbstractString) = add_definitions_from_repl_impl(convert(String, filename)::String)

# `revise_first` gets called by the REPL prior to executing the next command (by having been pushed
# onto the `ast_transform` list).
# This uses invokelatest not for reasons of world age but to ensure that the call is made at runtime.
# This allows `revise_first` to be compiled without compiling `revise` itself, and greatly
# reduces the overhead of using Revise.
function Revise.revise_first(ex)
    # Special-case `exit()` (issue #562)
    if isa(ex, Expr)
        exu = unwrap(ex)
        if isexpr(exu, :block, 2)
            arg1 = exu.args[1]
            if isexpr(arg1, :softscope)
                exu = exu.args[2]
            end
        end

        # Try to detect shell mode in the REPL. Might also falsely trigger for certain
        # `julia>` mode commands, but 🤷
        if isexpr(exu, :call, 3) && exu.args[1] == :(Base.repl_cmd)
            return ex
        end

        if isa(exu, Expr)
            exu.head === :call && length(exu.args) == 1 && exu.args[1] === :exit && return ex
            # `Revise.active[] = ...` must not trigger a revision. This is surface syntax,
            # so a plain `:(=)` check suffices; using `LoweredCodeUtils.get_lhs_rhs` here
            # would give this latest-world function static edges into that package.
            if isexpr(exu, :(=), 2)
                lhs = exu.args[1]
                if isexpr(lhs, :ref) && length(lhs.args) == 1
                    arg1 = lhs.args[1]
                    isexpr(arg1, :(.), 2) && arg1.args[1] === :Revise && is_quotenode_egal(arg1.args[2], :active) && return ex
                end
            end
        end
    end
    # Check for queued revisions, and if so call `revise` first before executing the expression
    return Expr(:toplevel, :($isempty($revision_queue) || $(Base.invokelatest)($revise)), ex)
end

# Wait for the REPL backend to come up, then register `revise_first` on it.
# #719: this runs async in case Revise is loaded from startup.jl, before the
# backend exists. issue #900: keep this a named function (not an anonymous
# `@async` closure) so it has a stable, precompilable signature.
function wait_for_repl_backend()
    iter = 0
    while !active_repl_backend_available() && iter < 20
        sleep(0.05)
        iter += 1
    end
    if active_repl_backend_available()
        push!(Base.active_repl_backend.ast_transforms, revise_first)
    end
    return nothing
end

function __init__()
    # Set REPL functions in Revise
    Revise.maybe_set_prompt_color = maybe_set_prompt_color_impl
    Revise.add_definitions_from_repl = add_definitions_from_repl_impl

    if Revise.should_enable_revise()
        pushfirst!(REPL.repl_ast_transforms, revise_first)
        # #664: once a REPL is started, it no longer interacts with REPL.repl_ast_transforms
        if active_repl_backend_available()
            push!(Base.active_repl_backend.ast_transforms, revise_first)
        else
            # wait for active_repl_backend to exist. Schedule the named function
            # directly (rather than `@async`, which wraps it in an anonymous
            # closure) so the task body carries a stable, precompilable signature.
            errormonitor(schedule(Task(wait_for_repl_backend)))
        end
    end
end

@warnpcfail precompile(active_repl_backend_available, ())
@warnpcfail precompile(wait_for_repl_backend, ())
@warnpcfail precompile(maybe_set_prompt_color_impl, (Symbol,))
@warnpcfail precompile(add_definitions_from_repl_impl, (String,))
@warnpcfail precompile(revise_first, (Expr,))

end
