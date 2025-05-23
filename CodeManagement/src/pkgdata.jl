mutable struct PkgData{Attrs}
    info::PkgFiles
    fileinfos::Vector{FileInfo{Attrs}}
    requirements::Vector{PkgId}
end

PkgData{Attrs}(id::PkgId, path) where Attrs = PkgData{Attrs}(PkgFiles(id, path), FileInfo[], PkgId[])
PkgData{Attrs}(id::PkgId, ::Nothing) where Attrs = PkgData{Attrs}(id, "")
function PkgData{Attrs}(id::PkgId) where Attrs
    bp = basepath(id)
    if !isempty(bp)
        bp = normpath(bp)
    end
    PkgData{Attrs}(id, bp)
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

# Abstraction interface for PkgData
Base.PkgId(pkgdata::PkgData) = PkgId(pkgdata.info)
basedir(pkgdata::PkgData) = basedir(pkgdata.info)
srcfiles(pkgdata::PkgData) = srcfiles(pkgdata.info)

relpath_safe(path::AbstractString, startpath::AbstractString) = isempty(startpath) ? path : relpath(path, startpath)

function Base.relpath(filename::AbstractString, pkgdata::PkgData)
    if isabspath(filename)
        # `Base.locate_package`, which is how `pkgdata` gets initialized, might strip pieces of the path.
        # For example, on Travis macOS the paths returned by `abspath`
        # can be preceded by "/private" which is not present in the value returned by `Base.locate_package`.
        idx = findfirst(basedir(pkgdata), filename)
        if idx !== nothing
            idx = first(idx)
            if idx > 1
                filename = filename[idx:end]
            end
            filename = relpath_safe(filename, basedir(pkgdata))
        end
    elseif startswith(filename, "compiler")
        # Core.Compiler's pkgid includes "compiler/" in the path
        filename = relpath(filename, "compiler")
    end
    return filename
end

function fileindex(info::PkgData, file::AbstractString)
    for (i, f) in enumerate(srcfiles(info))
        String(f) == String(file) && return i
    end
    return nothing
end

function hasfile(info::PkgData, file::AbstractString)
    if isabspath(file)
        file = relpath(file, info)
    end
    fileindex(info, file) !== nothing
end

function fileinfo(pkgdata::PkgData, file::AbstractString)
    i = fileindex(pkgdata, file)
    i === nothing && error("file ", file, " not found")
    return pkgdata.fileinfos[i]
end
fileinfo(pkgdata::PkgData, i::Int) = pkgdata.fileinfos[i]

function Base.push!(pkgdata::PkgData{Attrs}, pr::Pair{<:AbstractString,FileInfo{Attrs}}) where Attrs
    push!(srcfiles(pkgdata), pr.first)
    push!(pkgdata.fileinfos, pr.second)
    return pkgdata
end

function pkgfileless((pkgdata1,file1)::Tuple{PkgData,String}, (pkgdata2,file2)::Tuple{PkgData,String})
    # implements a partial order
    PkgId(pkgdata1) ∈ pkgdata2.requirements && return true
    PkgId(pkgdata1) == PkgId(pkgdata2) && return fileindex(pkgdata1, file1)::Int < fileindex(pkgdata2, file2)::Int
    return false
end
