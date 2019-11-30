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

    # issue #399
    src = """
    for jy in ("j","y"), nu in (0,1)
        jynu = Expr(:quote, Symbol(jy,nu))
        jynuf = Expr(:quote, Symbol(jy,nu,"f"))
        bjynu = Symbol("bessel",jy,nu)
        if jy == "y"
            @eval begin
                \$bjynu(x::Float64) = nan_dom_err(ccall((\$jynu,libm),  Float64, (Float64,), x), x)
                \$bjynu(x::Float32) = nan_dom_err(ccall((\$jynuf,libm), Float32, (Float32,), x), x)
                \$bjynu(x::Float16) = Float16(\$bjynu(Float32(x)))
            end
        else
            @eval begin
                \$bjynu(x::Float64) = ccall((\$jynu,libm),  Float64, (Float64,), x)
                \$bjynu(x::Float32) = ccall((\$jynuf,libm), Float32, (Float32,), x)
                \$bjynu(x::Float16) = Float16(\$bjynu(Float32(x)))
            end
        end
        @eval begin
            \$bjynu(x::Real) = \$bjynu(float(x))
            \$bjynu(x::Complex) = \$(Symbol("bessel",jy))(\$nu,x)
        end
    end
    """
    ex = Meta.parse(src)
    @test Revise.methods_by_execution(BackEdgesTest, ex) isa Tuple
end
