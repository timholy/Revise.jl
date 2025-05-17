using Test
@testset "CodeManagement" begin
    @testset "RelocatableExpr" include("test_relocatable_exprs.jl")
    @testset "PkgFiles" include("test_pkgfiles.jl")
    @testset "PkgData" include("test_pkgdata.jl")
end
