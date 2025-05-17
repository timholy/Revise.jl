"""
    Revise.WatchList

A struct for holding files that live inside a directory.
Some platforms (OSX) have trouble watching too many files. So we
watch parent directories, and keep track of which files in them
should be tracked.

Fields:
- `timestamp`: mtime of last update
- `trackedfiles`: Set of filenames, generally expressed as a relative path
"""
mutable struct WatchList
    timestamp::Float64         # unix time of last revision
    trackedfiles::Dict{String,PkgId}
end

"""
    ReviseEvalException(loc::String, exc::Exception, stacktrace=nothing)

Provide additional location information about `exc`.

When running via the interpreter, the backtraces point to interpreter code rather than the original
culprit. This makes it possible to use `loc` to provide information about the frame backtrace,
and even to supply a fake backtrace.

If `stacktrace` is supplied it must be a `Vector{Any}` containing `(::StackFrame, n)` pairs where `n`
is the recursion count (typically 1).
"""
struct ReviseEvalException <: Exception
    loc::String
    exc::Exception
    stacktrace::Union{Nothing,Vector{Any}}
end
ReviseEvalException(loc::AbstractString, exc::Exception) = ReviseEvalException(loc, exc, nothing)

function Base.showerror(io::IO, ex::ReviseEvalException; blame_revise::Bool=true)
    showerror(io, ex.exc)
    st = ex.stacktrace
    if st !== nothing
        Base.show_backtrace(io, st)
    end
    if blame_revise
        println(io, "\nRevise evaluation error at ", ex.loc)
    end
end

struct GitRepoException <: Exception
    filename::String
end

function Base.showerror(io::IO, ex::GitRepoException)
    print(io, "no repository at ", ex.filename, " to track stdlibs you must build Julia from source")
end

struct LoweringException <: Exception
    ex::Expr
end

function Base.showerror(io::IO, ex::LoweringException)
    print(io, "lowering returned an exception:\n", ex.ex)
end

"""
    thunk = TaskThunk(f, args)

To facilitate precompilation and reduce latency, we avoid creation of anonymous thunks.
`thunk` can be used as an argument in `schedule(Task(thunk))`.
"""
struct TaskThunk
    f          # deliberately untyped
    args       # deliberately untyped
end

@noinline (thunk::TaskThunk)() = thunk.f(thunk.args...)
