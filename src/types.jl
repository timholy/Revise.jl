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

const DocExprs = Dict{Module,Vector{Expr}}
const ExprsSigs = OrderedDict{RelocatableExpr,Union{Nothing,Vector{Any}}}
const DepDictVals = Tuple{Module,RelocatableExpr}
const DepDict = Dict{Symbol,Set{DepDictVals}}

function Base.show(io::IO, exsigs::ExprsSigs)
    compact = get(io, :compact, false)
    if compact
        n = 0
        for (rex, sigs) in exsigs
            sigs === nothing && continue
            n += length(sigs)
        end
        print(io, "ExprsSigs(<$(length(exsigs)) expressions>, <$n signatures>)")
    else
        print(io, "ExprsSigs with the following expressions: ")
        for def in keys(exsigs)
            print(io, "\n  ")
            Base.show_unquoted(io, RelocatableExpr(unwrap(def)), 2)
        end
    end
end

"""
    ModuleExprsSigs

For a particular source file, the corresponding `ModuleExprsSigs` is a mapping
`mod=>exprs=>sigs` of the expressions `exprs` found in `mod` and the signatures `sigs`
that arise from them. Specifically, if `mes` is a `ModuleExprsSigs`, then `mes[mod][ex]`
is a list of signatures that result from evaluating `ex` in `mod`. It is possible that
this returns `nothing`, which can mean either that `ex` does not define any methods
or that the signatures have not yet been cached.

The first `mod` key is guaranteed to be the module into which this file was `include`d.

To create a `ModuleExprsSigs` from a source file, see [`Revise.parse_source`](@ref).
"""
const ModuleExprsSigs = OrderedDict{Module,ExprsSigs}

function Base.typeinfo_prefix(io::IO, mexs::ModuleExprsSigs)
    tn = typeof(mexs).name
    return string(tn.module, '.', tn.name), true
end

"""
    fm = ModuleExprsSigs(mod::Module)

Initialize an empty `ModuleExprsSigs` for a file that is `include`d into `mod`.
"""
ModuleExprsSigs(mod::Module) = ModuleExprsSigs(mod=>ExprsSigs())

Base.isempty(fm::ModuleExprsSigs) = length(fm) == 1 && isempty(first(values(fm)))

"""
    FileInfo(mexs::ModuleExprsSigs, cachefile="")

Structure to hold the per-module expressions found when parsing a
single file.
`mexs` holds the [`Revise.ModuleExprsSigs`](@ref) for the file.

Optionally, a `FileInfo` can also record the path to a cache file holding the original source code.
This is applicable only for precompiled modules and `Base`.
(This cache file is distinct from the original source file that might be edited by the
developer, and it will always hold the state
of the code when the package was precompiled or Julia's `Base` was built.)
When a cache is available, `mexs` will be empty until the file gets edited:
the original source code gets parsed only when a revision needs to be made.

Source cache files greatly reduce the overhead of using Revise.
"""
struct FileInfo
    modexsigs::ModuleExprsSigs
    cachefile::String
    cacheexprs::Vector{Tuple{Module,Expr}}             # "unprocessed" exprs, used to support @require
    extracted::Base.RefValue{Bool}                     # true if signatures have been processed from modexsigs
end
FileInfo(fm::ModuleExprsSigs, cachefile="") = FileInfo(fm, cachefile, Tuple{Module,Expr}[], Ref(false))

"""
    FileInfo(mod::Module, cachefile="")

Initialize an empty FileInfo for a file that is `include`d into `mod`.
"""
FileInfo(mod::Module, cachefile::AbstractString="") = FileInfo(ModuleExprsSigs(mod), cachefile)

FileInfo(fm::ModuleExprsSigs, fi::FileInfo) = FileInfo(fm, fi.cachefile, copy(fi.cacheexprs), Ref(fi.extracted[]))

function Base.show(io::IO, fi::FileInfo)
    print(io, "FileInfo(")
    for (mod, exsigs) in fi.modexsigs
        show(io, mod)
        print(io, "=>")
        show(io, exsigs)
        print(io, ", ")
    end
    if !isempty(fi.cachefile)
        print(io, "with cachefile ", fi.cachefile)
    end
    print(io, ')')
end

"""
    PkgData(id, path, fileinfos::Dict{String,FileInfo})

A structure holding the data required to handle a particular package.
`path` is the top-level directory defining the package,
and `fileinfos` holds the [`Revise.FileInfo`](@ref) for each file defining the package.

For the `PkgData` associated with `Main` (e.g., for files loaded with [`includet`](@ref)),
the corresponding `path` entry will be empty.
"""
mutable struct PkgData
    info::PkgFiles
    fileinfos::Vector{FileInfo}
    requirements::Vector{PkgId}
end

PkgData(id::PkgId, path) = PkgData(PkgFiles(id, path), FileInfo[], PkgId[])
PkgData(id::PkgId, ::Nothing) = PkgData(id, "")
function PkgData(id::PkgId)
    bp = basepath(id)
    if !isempty(bp)
        bp = normpath(bp)
    end
    PkgData(id, bp)
end

# Abstraction interface for PkgData
Base.PkgId(pkgdata::PkgData) = PkgId(pkgdata.info)
CodeTracking.basedir(pkgdata::PkgData) = basedir(pkgdata.info)
CodeTracking.srcfiles(pkgdata::PkgData) = srcfiles(pkgdata.info)

is_same_file(a, b) = String(a) == String(b)

function fileindex(info, file)
    for (i, f) in enumerate(srcfiles(info))
        is_same_file(f, file) && return i
    end
    return nothing
end

function hasfile(info, file)
    if isabspath(file)
        file = relpath(file, info)
    end
    fileindex(info, file) !== nothing
end

function fileinfo(pkgdata::PkgData, file::String)
    i = fileindex(pkgdata, file)
    i === nothing && error("file ", file, " not found")
    return pkgdata.fileinfos[i]
end
fileinfo(pkgdata::PkgData, i::Int) = pkgdata.fileinfos[i]

function Base.push!(pkgdata::PkgData, pr::Pair{<:Any,FileInfo})
    push!(srcfiles(pkgdata), pr.first)
    push!(pkgdata.fileinfos, pr.second)
    return pkgdata
end

function Base.show(io::IO, pkgdata::PkgData)
    compact = get(io, :compact, false)
    print(io, "PkgData(")
    if compact
        print(io, '"', pkgdata.info.basedir, "\", ")
        nexs, nsigs, nparsed = 0, 0, 0
        for fi in pkgdata.fileinfos
            thisnexs, thisnsigs = 0, 0
            for (mod, exsigs) in fi.modexsigs
                for (rex, sigs) in exsigs
                    thisnexs += 1
                    sigs === nothing && continue
                    thisnsigs += length(sigs)
                end
            end
            nexs += thisnexs
            nsigs += thisnsigs
            if thisnexs > 0
                nparsed += 1
            end
        end
        print(io, nparsed, '/', length(pkgdata.fileinfos), " parsed files, ", nexs, " expressions, ", nsigs, " signatures)")
    else
        show(io, pkgdata.info.id)
        println(io, ", basedir \"", pkgdata.info.basedir, "\":")
        for (f, fi) in zip(pkgdata.info.files, pkgdata.fileinfos)
            print(io, "  \"", f, "\": ")
            show(IOContext(io, :compact=>true), fi)
            print(io, '\n')
        end
    end
end

function pkgfileless((pkgdata1,file1)::Tuple{PkgData,String}, (pkgdata2,file2)::Tuple{PkgData,String})
    # implements a partial order
    PkgId(pkgdata1) ∈ pkgdata2.requirements && return true
    PkgId(pkgdata1) == PkgId(pkgdata2) && return fileindex(pkgdata1, file1) < fileindex(pkgdata2, file2)
    return false
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
