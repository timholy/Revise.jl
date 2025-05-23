"""
    mutable struct PkgFiles
        id::PkgId
        basedir::String
        files::Vector{String}
    end

PkgFiles encodes information about the current location of a package.
Fields:
- `id`: the `PkgId` of the package
- `basedir`: the current base directory of the package
- `files`: a list of files (relative path to `basedir`) that define the package.

Note that `basedir` may be subsequently updated by Pkg operations such as `add` and `dev`.
"""
mutable struct PkgFiles
    id::PkgId
    basedir::String
    files::Vector{String}
end

PkgFiles(id::PkgId, path::AbstractString) = PkgFiles(id, path, String[])
PkgFiles(id::PkgId, ::Nothing) = PkgFiles(id, "")
PkgFiles(id::PkgId) = PkgFiles(id, normpath(basepath(id)))
PkgFiles(id::PkgId, files::AbstractVector{<:AbstractString}) =
    PkgFiles(id, normpath(basepath(id)), files)

# Abstraction interface
Base.PkgId(info::PkgFiles) = info.id
srcfiles(info::PkgFiles) = info.files
basedir(info::PkgFiles) = info.basedir

function Base.show(io::IO, info::PkgFiles)
    compact = get(io, :compact, false)
    if compact
        print(io, "PkgFiles(", info.id.name, ", ", info.basedir, ", ")
        show(io, info.files)
        print(io, ')')
    else
        println(io, "PkgFiles(", info.id, "):")
        println(io, "  basedir: \"", info.basedir, '"')
        print(io, "  files: ")
        show(io, info.files)
    end
end

function basepath(id::PkgId)
    id.name ∈ ("Main", "Base", "Core") && return ""
    loc = Base.locate_package(id)
    loc === nothing && return ""
    return dirname(dirname(loc))
end
