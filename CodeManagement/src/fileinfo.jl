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
    parsed::Base.RefValue{Bool}                        # true if modexsigs have been parsed from cachefile
end
FileInfo(fm::ModuleExprsSigs, cachefile="") = FileInfo(fm, cachefile, Tuple{Module,Expr}[], Ref(false), Ref(false))

"""
    FileInfo(mod::Module, cachefile="")

Initialize an empty FileInfo for a file that is `include`d into `mod`.
"""
FileInfo(mod::Module, cachefile::AbstractString="") = FileInfo(ModuleExprsSigs(mod), cachefile)

FileInfo(fm::ModuleExprsSigs, fi::FileInfo) = FileInfo(fm, fi.cachefile, copy(fi.cacheexprs), Ref(fi.extracted[]), Ref(fi.parsed[]))

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
