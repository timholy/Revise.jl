using Revise, Test

module BackEdgesTest
flag = false    # this needs to be defined for the conditional part to work
end

@testset "Backedges" begin
    src = """
    # issue #249
    flag = false
    if flag
        f() = 1
    else
        f() = 2
    end

    # don't do work in the interpreter that isn't needed for function definitions
    # inspired by #300
    const planetdiameters = Dict("Mercury" => 4_878)
    planetdiameters["Venus"] = 12_104

    function getdiameter(name)
        return planetdiameters[name]
    end
    """
    mexs = Revise.parse_source!(Revise.ModuleExprsSigs(BackEdgesTest), src, "backedges_test.jl", BackEdgesTest)
    Revise.moduledeps[BackEdgesTest] = Revise.DepDict()
    Revise.instantiate_sigs!(mexs)
    @test isempty(methods(BackEdgesTest.getdiameter))
    @test !isdefined(BackEdgesTest, :planetdiameters)
    @test length(Revise.moduledeps[BackEdgesTest]) == 1
    @test Revise.moduledeps[BackEdgesTest][:flag] == Set([(BackEdgesTest, first(Iterators.drop(mexs[BackEdgesTest], 1))[1])])
end
