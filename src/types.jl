struct ReviseFileInfoAttrs
    cachefile::String
    cacheexprs::Vector{Tuple{Module,Expr}}             # "unprocessed" exprs, used to support @require
    extracted::Base.RefValue{Bool}                     # true if signatures have been processed from modexsigs
    parsed::Base.RefValue{Bool}                        # true if modexsigs have been parsed from cachefile
end
ReviseFileInfoAttrs(cachefile::AbstractString="") = ReviseFileInfoAttrs(cachefile, Tuple{Module,Expr}[], Ref(false), Ref(false))

"""
    ReviseFileInfo(mexs::ModuleExprsSigs, cachefile="")

Structure to hold the per-module expressions found when parsing a
single file.
`mexs` holds the [`Revise.ModuleExprsSigs`](@ref) for the file.

Optionally, a `ReviseFileInfo` can also record the path to a cache file holding the original source code.
This is applicable only for precompiled modules and `Base`.
(This cache file is distinct from the original source file that might be edited by the
developer, and it will always hold the state
of the code when the package was precompiled or Julia's `Base` was built.)
When a cache is available, `mexs` will be empty until the file gets edited:
the original source code gets parsed only when a revision needs to be made.

Source cache files greatly reduce the overhead of using Revise.
"""
const ReviseFileInfo = FileInfo{ReviseFileInfoAttrs}
ReviseFileInfo(modexsigs::ModuleExprsSigs, cachefile::AbstractString="") =
    ReviseFileInfo(modexsigs, ReviseFileInfoAttrs(cachefile))

"""
    ReviseFileInfo(mod::Module, cachefile::AbstractString="")

Initialize an empty `ReviseFileInfo` for a file that is `include`d into `mod`.
"""
ReviseFileInfo(mod::Module, cachefile::AbstractString="") =
    ReviseFileInfo(ModuleExprsSigs(mod), ReviseFileInfoAttrs(cachefile))

function Base.copy(attrs::ReviseFileInfoAttrs)
    return ReviseFileInfoAttrs(attrs.cachefile, copy(attrs.cacheexprs), Ref(attrs.extracted[]), Ref(attrs.parsed[]))
end
function Base.show(io::IO, attrs::ReviseFileInfoAttrs)
    if !isempty(attrs.cachefile)
        print(io, "with cachefile ", attrs.cachefile)
    end
end

"""
    mutable struct RevisePkgData
        info::PkgFiles
        fileinfos::Vector{ReviseFileInfo}
        requirements::Vector{PkgId}
    end
    PkgData(id::PkgId, path, fileinfos::Dict{String,ReviseFileInfo})

A structure holding the data required to handle a particular package.
`path` is the top-level directory defining the package,
and `fileinfos` holds the [`Revise.ReviseFileInfo`](@ref) for each file defining the package.

For the `PkgData` associated with `Main` (e.g., for files loaded with [`includet`](@ref)),
the corresponding `path` entry will be empty.
"""
const RevisePkgData = PkgData{ReviseFileInfoAttrs}

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
