module test_pkgdata

using Test
using CodeManagement

let # Related to timholy/Revise.jl#358
    id = Base.PkgId(Main)
    pd = PkgData(id)
    @test isempty(basedir(pd))
end

end # module test_pkgdata
