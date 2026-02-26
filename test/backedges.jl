using Revise, Test
using Revise.JuliaInterpreter: Frame
using Base.Meta: isexpr

isdefined(@__MODULE__, :do_test) || include("common.jl")

module BackEdgesTest
using Test
flag = false    # this needs to be defined for the conditional part to work
end

do_test("Backedges") && @testset "Backedges" begin
    frame = Frame(Base, :(max_values(T::Union{map(X -> Type{X}, BitIntegerSmall_types)...}) = 1 << (8*sizeof(T))))
    src = frame.framecode.src
    # Find the inner struct def for the anonymous function
    idtype = findall(stmt->isexpr(stmt, :thunk) && isa(stmt.args[1], Core.CodeInfo), src.code)[end]
    src2 = src.code[idtype].args[1]
    isrequired = Revise.minimal_evaluation!(frame, :sigs)[1]
    laststmt = src.code[end]
    @assert isa(laststmt, Core.ReturnNode)
    to_skip = isa(laststmt.val, Revise.JuliaInterpreter.SSAValue) ? 2 : 1
    # Revise.LoweredCodeUtils.print_with_code(stdout, src, isrequired)
    extra_skip = hasfield(Method, :is_kwcall_stub) ? 1 : 0
    @test sum(isrequired) == length(src.code)-count(e->isexpr(e, :latestworld), src.code)-to_skip-extra_skip  # skips the `return` at the end (and its argument)

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
    mexs = Revise.parse_source!(Revise.ModuleExprsInfos(BackEdgesTest), src, "backedges_test.jl", BackEdgesTest)
    Revise.instantiate_sigs!(mexs)
    @test isempty(methods(BackEdgesTest.getdiameter))
    @test !isdefined(BackEdgesTest, :planetdiameters)

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

    # Issue #428
    src = """
    @testset for i in (1, 2)
        @test i == i
    end
    """
    ex = Meta.parse(src)
    @test Revise.methods_by_execution(BackEdgesTest, ex) isa Tuple
end
