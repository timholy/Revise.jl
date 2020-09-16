using Base.CoreLogging
using Base.CoreLogging: Info, Debug

struct LogRecord
    level
    message
    group
    id
    file
    line
    kwargs
end
LogRecord(args...; kwargs...) = LogRecord(args..., kwargs)

mutable struct ReviseLogger <: AbstractLogger
    logs::Vector{LogRecord}
    min_level::LogLevel
end

ReviseLogger(; min_level=Info) = ReviseLogger(LogRecord[], min_level)

CoreLogging.min_enabled_level(logger::ReviseLogger) = logger.min_level

CoreLogging.shouldlog(logger::ReviseLogger, level, _module, group, id) = _module == Revise

function CoreLogging.handle_message(logger::ReviseLogger, level, msg, _module,
                                    group, id, file, line; kwargs...)
    rec = LogRecord(level, msg, group, id, file, line, kwargs)
    push!(logger.logs, rec)
    if level >= Info
        if group == "lowered" && haskey(kwargs, :mod) && haskey(kwargs, :ex) && haskey(kwargs, :exception)
            ex, bt = kwargs[:exception]
            printstyled(stderr, msg; color=:red)
            print(stderr, "\n  ")
            showerror(stderr, ex, bt; backtrace = bt!==nothing)
            println(stderr, "\nwhile evaluating\n", kwargs[:ex], "\nin module ", kwargs[:mod])
        else
            show(stderr, rec)
        end
    end
end

CoreLogging.catch_exceptions(::ReviseLogger) = false

function Base.show(io::IO, l::LogRecord; verbose::Bool=true)
    if verbose
        print(io, LogRecord)
        print(io, '(', l.level, ", ", l.message, ", ", l.group, ", ", l.id, ", \"", l.file, "\", ", l.line)
    else
        printstyled(io, "Revise ", l.message, '\n'; color=Base.error_color())
    end
    exc = nothing
    if !isempty(l.kwargs)
        verbose && print(io, ", (")
        prefix = ""
        for (kw, val) in l.kwargs
            kw === :exception && (exc = val; continue)
            verbose && print(io, prefix, kw, "=", val)
            prefix = ", "
        end
        verbose && print(io, ')')
    end
    if exc !== nothing
        ex, bt = exc
        showerror(io, ex, bt; backtrace = bt!==nothing)
        verbose || println(io)
    end
    verbose && println(io, ')')
end

const _debug_logger = ReviseLogger()

"""
    logger = Revise.debug_logger(; min_level=Debug)

Turn on [debug logging](https://docs.julialang.org/en/v1/stdlib/Logging/)
(if `min_level` is set to `Debug` or better) and return the logger object.
`logger.logs` contains a list of the logged events. The items in this list are of type `Revise.LogRecord`,
with the following relevant fields:

- `group`: the event category. Revise currently uses the following groups:
  + "Action": a change was implemented, of type described in the `message` field.
  + "Parsing": a "significant" event in parsing. For these, examine the `message` field
    for more information.
  + "Watching": an indication that Revise determined that a particular file needed to be
    examined for possible code changes. This is typically done on the basis of `mtime`,
    the modification time of the file, and does not necessarily indicate that there were
    any changes.
- `message`: a string containing more information. Some examples:
  + For entries in the "Action" group, `message` can be `"Eval"` when modifying
    old methods or defining new ones, "DeleteMethod" when deleting a method,
    and "LineOffset" to indicate that the line offset for a method
    was updated (the last only affects the printing of stacktraces upon error,
    it does not change how code runs)
  + Items with group "Parsing" and message "Diff" contain sets `:newexprs` and `:oldexprs`
    that contain the expression unique to post- or pre-revision, respectively.
- `kwargs`: a pairs list of any other data. This is usually specific to particular `group`/`message`
  combinations.

See also [`Revise.actions`](@ref) and [`Revise.diffs`](@ref).
"""
function debug_logger(; min_level=Debug)
    _debug_logger.min_level = min_level
    return _debug_logger
end

"""
    actions(logger; line=false)

Return a vector of all log events in the "Action" group. "LineOffset" events are returned
only if `line=true`; by default the returned items are the events that modified
methods in your session.
"""
function actions(logger::ReviseLogger; line=false)
    filter(logger.logs) do r
        r.group=="Action" && (line || r.message!="LineOffset")
    end
end

"""
    diffs(logger)

Return a vector of all log events that encode a (non-empty) diff between two versions of a file.
"""
function diffs(logger::ReviseLogger)
    filter(logger.logs) do r
        r.message=="Diff" && r.group=="Parsing" && (!isempty(r.kwargs[:newexprs]) || !isempty(r.kwargs[:oldexprs]))
    end
end

## Make the logs portable

"""
    MethodSummary(method)

Create a portable summary of a method. In particular, a MethodSummary can be saved to a JLD2 file.
"""
struct MethodSummary
    name::Symbol
    modulename::Symbol
    file::Symbol
    line::Int32
    sig::Type
end
MethodSummary(m::Method) = MethodSummary(m.name, nameof(m.module), m.file, m.line, m.sig)
