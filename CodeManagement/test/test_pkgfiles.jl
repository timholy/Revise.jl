module test_pkgfiles

using Test
using CodeManagement

let info = PkgFiles(Base.PkgId(CodeManagement), nothing)
    @test isempty(basedir(info))
end

let info = PkgFiles(Base.PkgId(CodeManagement), String[])
    @test length(srcfiles(info)) == 0
end

let info = PkgFiles(Base.PkgId(CodeManagement))
    @test Base.PkgId(info) === info.id
    @test basedir(info) == dirname(@__DIR__)

    io = PipeBuffer()
    show(io, info)
    str = read(io, String)
    @test startswith(str, "PkgFiles(CodeManagement [e3aa46a8-e9bc-434c-843a-2a8ca567387e]):\n  basedir:") ||
          startswith(str, "PkgFiles(Base.PkgId(Base.UUID(\"e3aa46a8-e9bc-434c-843a-2a8ca567387e\"), \"CodeManagement\")):\n  basedir:")
    ioctx = IOContext(io, :compact=>true)
    show(ioctx, info)
    str = read(io, String)
    @test match(r"PkgFiles\(CodeManagement, .*CodeManagement(\.jl)?, String\[\]\)", str) !== nothing
end

end # module test_pkgfiles
