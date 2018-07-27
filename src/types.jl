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

"""
    Revise.ExprsSigs

struct holding parsed source code.

Fields:
- `exprs`: all [`RelocatableExpr`](@ref) in the module or file
- `sigs`: all detected function signatures (used in method deletion)

These fields are stored as sets so that one can efficiently find the differences between two
versions of the same module or file.
"""
struct ExprsSigs
    exprs::OrderedSet{RelocatableExpr}
    sigs::OrderedSet{RelocatableExpr}
end
ExprsSigs() = ExprsSigs(OrderedSet{RelocatableExpr}(), OrderedSet{RelocatableExpr}())

Base.isempty(es::ExprsSigs) = isempty(es.exprs) && isempty(es.sigs)

function Base.show(io::IO, exprsig::ExprsSigs)
    println(io, "ExprsSigs with $(length(exprsig.exprs)) exprs and $(length(exprsig.sigs)) method signatures")
    println(io, "Exprs:")
    for ex in exprsig.exprs
        show(io, ex)
        println(io)
    end
    println(io, "Method signatures:")
    for sig in exprsig.sigs
        show(io, sig)
    end
end

"""
A `ModDict` is an alias for `Dict{Module,ExprsSigs}`. It is used to
organize expressions according to their module of definition.

See also [`FileModules`](@ref).
"""
const ModDict = Dict{Module,ExprsSigs}

"""
    FileModules(topmod::Module, md::ModDict, [cachefile::String])

Structure to hold the per-module expressions found when parsing a
single file.
`topmod` is the current module when the file is parsed (i.e., the module this file
was `include`d into); this is used every time the file is modified to re-parse the file.
 `md` holds the evaluatable statements, organized by the module
of their occurrence. In particular, if the file defines one or
more new modules, then `md` contains key/value pairs for each
module. If the file does not define any new modules, `topmod` is
the only key in `md`.

# Example:

Suppose MyPkg.jl has a file that looks like this:

```julia
__precompile__(true)

module MyPkg

foo(x) = x^2

end
```

Then if this module is loaded from `Main`, schematically the
corresponding `fm::FileModules` looks something like

```julia
fm.topmod = Main
fm.md = Dict(Main=>ExprsSigs(OrderedSet([:(__precompile__(true))]), OrderedSet()),
             Main.MyPkg=>ExprsSigs(OrderedSet([:(foo(x) = x^2)]), OrderedSet([:(foo(x))]))
```
because the precompile statement occurs in `Main`, and the definition of
`foo` occurs in `Main.MyPkg`.

!!! note "Source cache files"

    Optionally, a `FileModule` can also record the path to a cache file holding the original source code.
    This is applicable only for precompiled modules and `Base`.
    (This cache file is distinct from the original source file that might be edited by the
    developer, and it will always hold the state
    of the code when the package was precompiled or Julia's `Base` was built.)
    For such modules, the `ExprsSigs` will be empty for any file that has not yet been edited:
    the original source code gets parsed only when a revision needs to be made.

    Source cache files greatly reduce the overhead of using Revise.

To create a `FileModules` from a source file, see [`parse_source`](@ref).
"""
struct FileModules
    topmod::Module
    md::ModDict
    cachefile::String
end
FileModules(topmod::Module, md::ModDict) = FileModules(topmod, md, "")
FileModules(topmod::Module, cachefile::AbstractString="") =
    FileModules(topmod, Dict(topmod=>ExprsSigs()), cachefile)

# "Replace" md
FileModules(fm::FileModules, md::ModDict) = FileModules(fm.topmod, md, fm.cachefile)

Base.isempty(fm::FileModules) = length(fm.md) == 1 && isempty(first(values(fm.md)))

function Base.show(io::IO, fm::FileModules)
    print(io, "FileModules(", fm.topmod, ", ")
    showdict = Dict{Module,String}()
    for (mod, exprsig) in fm.md
        showdict[mod] = "ExprsSigs with $(length(exprsig.exprs)) exprs and $(length(exprsig.sigs)) method signatures"
    end
    print(io, showdict, ", ", isempty(fm.cachefile) ? "<no cachefile>" : fm.cachefile, ")")
end
