# Some platforms (OSX) have trouble watching too many files. So we
# watch parent directories, and keep track of which files in them
# should be tracked.
mutable struct WatchList
    timestamp::Float64         # unix time of last revision
    trackedfiles::Set{String}
end

"""
A `ModDict` is a `Dict{Module,Set{RelocatableExpr}}`. It is used to
organize expressions according to their module of definition. We use a
Set so that it is easy to find the differences between two `ModDict`s.

See also [`FileModules`](@ref).
"""
const ModDict = Dict{Module,OrderedSet{RelocatableExpr}}

"""
    FileModules(topmod::Module, md::ModDict)

Structure to hold the per-module expressions found when parsing a
single file.  `topmod` is the current module when the file is
parsed. `md` holds the evaluatable statements, organized by the module
of their occurance. In particular, if the file defines one or
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
fm.md = Dict(Main=>OrderedSet([:(__precompile__(true))]),
             Main.MyPkg=>OrderedSet[:(foo(x) = x^2)])
```
because the precompile statement occurs in `Main`, and the definition of
`foo` occurs in `Main.MyPkg`.

To create a `FileModules` from a source file, see [`parse_source`](@ref).
"""
struct FileModules
    topmod::Module
    md::ModDict
    cachefile::String
end
FileModules(topmod::Module, md::ModDict) = FileModules(topmod, md, "")
