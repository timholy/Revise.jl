module ReviseREPLExt

import REPL
using Revise: Revise, revision_queue, revise, pkgdatas, pkgdatas_lock, PkgData, FileInfo,
              ModuleExprsInfos, parse_source!, instantiate_sigs!, unwrap, isexpr, revise_first,
              LoweredCodeUtils, is_quotenode_egal, @warnpcfail

using Base: PkgId


const original_repl_prefix = Ref{Union{String, Function, Nothing}}(nothing)

Revise.revise(::REPL.REPLBackend) = revise()

# Check if the active REPL backend is available
active_repl_backend_available() = isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing

function maybe_set_prompt_color_impl(color::Symbol)
    if isdefined(Base, :active_repl)
        repl = Base.active_repl
        if isa(repl, REPL.LineEditREPL)
            if color === :warn
                # First save the original setting
                if original_repl_prefix[] === nothing
                    original_repl_prefix[] = repl.mistate.current_mode.prompt_prefix
                end
                repl.mistate.current_mode.prompt_prefix = "\e[33m"  # yellow
            else
                color = original_repl_prefix[]
                color === nothing && return nothing
                repl.mistate.current_mode.prompt_prefix = color
                original_repl_prefix[] = nothing
            end
        end
    end
    return nothing
end

function add_definitions_from_repl_impl(filename::String)
    hist_idx = parse(Int, filename[6:end-1])
    hp = (Base.active_repl::REPL.LineEditREPL).interface.modes[1].hist::REPL.REPLHistoryProvider
    src = hp.history[hp.start_idx+hist_idx]
    id = PkgId(nothing, "@REPL")
    pkgdata = pkgdatas[id]
    mod_exs_infos = ModuleExprsInfos(Main::Module)
    parse_source!(mod_exs_infos, src, filename, Main::Module)
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
        if isa(exu, Expr)
            exu.head === :call && length(exu.args) == 1 && exu.args[1] === :exit && return ex
            lhsrhs = LoweredCodeUtils.get_lhs_rhs(exu)
            if lhsrhs !== nothing
                lhs, _ = lhsrhs
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
            # wait for active_repl_backend to exist
            # #719: do this async in case Revise is being loaded from startup.jl
            t = @async begin
                iter = 0
                while !active_repl_backend_available() && iter < 20
                    sleep(0.05)
                    iter += 1
                end
                if active_repl_backend_available()
                    push!(Base.active_repl_backend.ast_transforms, revise_first)
                end
            end
            errormonitor(t)
        end
    end
end

@warnpcfail precompile(active_repl_backend_available, ())
@warnpcfail precompile(maybe_set_prompt_color_impl, (Symbol,))
@warnpcfail precompile(add_definitions_from_repl_impl, (String,))
@warnpcfail precompile(revise_first, (Expr,))

end
