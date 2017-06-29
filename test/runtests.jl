using Revise
using Base.Test

@testset "Revise" begin

    function collectexprs(ex::Revise.RelocatableExpr)
        exs = Revise.RelocatableExpr[]
        for item in Revise.LineSkippingIterator(ex.args)
            push!(exs, item)
        end
        exs
    end

    @testset "LineSkipping" begin
        ex = Revise.relocatable!(quote
                                 f(x) = x^2
                                 g(x) = sin(x)
                                 end)
        @test length(ex.args) == 4  # including the line number expressions
        exs = collectexprs(ex)
        @test length(exs) == 2
        @test isequal(exs[1], Revise.relocatable!(:(f(x) = x^2)))
        @test !isequal(exs[2], Revise.relocatable!(:(f(x) = x^2)))
        @test isequal(exs[2], Revise.relocatable!(:(g(x) = sin(x))))
        @test !isequal(exs[1], Revise.relocatable!(:(g(x) = sin(x))))
    end

    @testset "Comparison" begin
        fl1 = joinpath(@__DIR__, "revisetest.jl")
        fl2 = joinpath(@__DIR__, "revisetest_revised.jl")
        fl3 = joinpath(@__DIR__, "revisetest_errors.jl")
        include(fl1)  # So the modules are defined
        # test the "mistakes"
        @test ReviseTest.cube(2) == 16
        @test ReviseTest.Internal.mult3(2) == 8
        oldmd = Revise.parse_source(fl1, Main, dirname(fl1))
        newmd = Revise.parse_source(fl2, Main, nothing)
        revmd = Revise.revised_statements(newmd, oldmd)
        @test length(revmd) == 2
        @test haskey(revmd, ReviseTest) && haskey(revmd, ReviseTest.Internal)
        @test length(revmd[ReviseTest.Internal]) == 1
        cmp = Revise.relocatable!(quote
            mult3(x) = 3*x
        end)
        @test isequal(first(revmd[ReviseTest.Internal]), collectexprs(cmp)[1])
        @test length(revmd[ReviseTest]) == 2
        cmp = Revise.relocatable!(quote
            cube(x) = x^3
            fourth(x) = x^4  # this is an addition to the file
        end)
        @test isequal(revmd[ReviseTest], Set(collectexprs(cmp)))

        Revise.eval_revised(revmd)
        @test ReviseTest.cube(2) == 8
        @test ReviseTest.Internal.mult3(2) == 6

        # Backtraces
        newmd = Revise.parse_source(fl3, Main, nothing)
        revmd = Revise.revised_statements(newmd, oldmd)
        Revise.eval_revised(revmd)
        try
            ReviseTest.cube(2)
        catch err
            @test isa(err, ErrorException) && err.msg == "cube"
            bt = first(stacktrace(catch_backtrace()))
            @test bt.func == :cube && bt.file == Symbol(fl3) && bt.line == 6
        end
        try
            ReviseTest.Internal.mult2(2)
        catch err
            @test isa(err, ErrorException) && err.msg == "mult2"
            bt = first(stacktrace(catch_backtrace()))
            @test bt.func == :mult2 && bt.file == Symbol(fl3) && bt.line == 12
        end
    end

end
