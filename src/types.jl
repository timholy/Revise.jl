"""
    Revise.WatchList

A struct for holding files that live inside a directory.
Some platforms (OSX) have trouble watching too many files. So we
watch parent directories, and keep track of which files in them
should be tracked.

Fields:
- `timestamp`: mtime of last update
- `trackedfiles`: Set of filenames
"""
mutable struct WatchList
    timestamp::Float64         # unix time of last revision
    trackedfiles::Set{String}
end

const DefMapValue = Union{RelocatableExpr,Tuple{Vector{Any},Int}}  # ([sigt1,...], lineoffset)

"""
    DefMap

Maps `def`=>nothing or `def=>([sigt1,...], lineoffset)`, where:

- `def` is an expression
- the value is `nothing` if `def` does not define a method
- if it does define a method, `sigt1...` are the signature-types and `lineoffset` is the
  difference between the line number when the method was compiled and the current state
  of the source file.

See the documentation page [How Revise works](@ref) for more information.
"""
const DefMap = OrderedDict{RelocatableExpr,Union{DefMapValue,Nothing}}

"""
    SigtMap

Maps `sigt=>def`, where `sigt` is the signature-type of a method and `def` the expression
defining the method.

See the documentation page [How Revise works](@ref) for more information.
"""
const SigtMap = IdDict{Any,RelocatableExpr}   # sigt=>def

"""
    FMMaps

`source=>sigtypes` and `sigtypes=>source` mappings for a particular file/module combination.
See the documentation page [How Revise works](@ref) for more information.
"""
struct FMMaps
    defmap::DefMap
    sigtmap::SigtMap
end
FMMaps() = FMMaps(DefMap(), SigtMap())

Base.isempty(fmm::FMMaps) = isempty(fmm.defmap)

function Base.show(io::IO, fmm::FMMaps)
    limit = get(io, :limit, true)
    if limit
        print(io, "FMMaps(<$(length(fmm.defmap)) expressions>, <$(length(fmm.sigtmap)) signatures>)")
    else
        println(io, "FMMaps with the following expressions:")
        for def in keys(fmm.defmap)
            print(io, "  ")
            Base.show_unquoted(io, def, 2)
            print(io, '\n')
        end
    end
end

"""
    FileModules

For a particular source file, the corresponding `FileModules` is an
`OrderedDict(mod1=>fmm1, mod2=>fmm2)`,
mapping the collection of modules "active" in the file (the parent module and any
submodules it defines) to their corresponding [`FMMaps`](@ref).

The first key is guaranteed to be the module into which this file was `include`d.

To create a `FileModules` from a source file, see [`parse_source`](@ref).
"""
const FileModules = OrderedDict{Module,FMMaps}

"""
    fm = FileModules(mod::Module)

Initialize an empty `FileModules` for a file that is `include`d into `mod`.
"""
FileModules(mod::Module) = FileModules(mod=>FMMaps())

Base.isempty(fm::FileModules) = length(fm) == 1 && isempty(first(values(fm)))

"""
    FileInfo(fm::FileModules, cachefile="")

Structure to hold the per-module expressions found when parsing a
single file.
`fm` holds the [`FileModules`](@ref) for the file.

Optionally, a `FileInfo` can also record the path to a cache file holding the original source code.
This is applicable only for precompiled modules and `Base`.
(This cache file is distinct from the original source file that might be edited by the
developer, and it will always hold the state
of the code when the package was precompiled or Julia's `Base` was built.)
When a cache is available, `fm` will be empty until the file gets edited:
the original source code gets parsed only when a revision needs to be made.

Source cache files greatly reduce the overhead of using Revise.
"""
struct FileInfo
    fm::FileModules
    cachefile::String
end
FileInfo(fm::FileModules) = FileInfo(fm, "")

"""
    FileInfo(mod::Module, cachefile="")

Initialze an empty FileInfo for a file that is `include`d into `mod`.
"""
FileInfo(mod::Module, cachefile::AbstractString="") = FileInfo(FileModules(mod), cachefile)

FileInfo(fm::FileModules, fi::FileInfo) = FileInfo(fm, fi.cachefile)

struct GitRepoException <: Exception
    filename::String
end

function Base.showerror(io::IO, ex::GitRepoException)
    print(io, "no repository at ", ex.filename, " to track stdlibs you must build Julia from source")
end
