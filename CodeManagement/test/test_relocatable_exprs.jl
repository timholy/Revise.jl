module test_relocatable_exprs

using Test
using CodeManagement

@testset "Equality and hashing" begin
    # issue #233
    @test  isequal(RelocatableExpr(:(x = 1)), RelocatableExpr(:(x = 1)))
    @test !isequal(RelocatableExpr(:(x = 1)), RelocatableExpr(:(x = 1.0)))
    @test hash(RelocatableExpr(:(x = 1))) == hash(RelocatableExpr(:(x = 1)))
    @test hash(RelocatableExpr(:(x = 1))) != hash(RelocatableExpr(:(x = 1.0)))
    @test hash(RelocatableExpr(:(x = 1))) != hash(RelocatableExpr(:(x = 2)))
end

function collectexprs(rex::RelocatableExpr)
    items = []
    for item in LineSkippingIterator(rex.ex.args)
        push!(items, isa(item, Expr) ? RelocatableExpr(item) : item)
    end
    items
end

@testset "LineSkipping" begin
    rex = RelocatableExpr(quote
                              f(x) = x^2
                              g(x) = sin(x)
                          end)
    @test length(rex.ex.args) == 4  # including the line number expressions
    exs = collectexprs(rex)
    @test length(exs) == 2
    @test isequal(exs[1], RelocatableExpr(:(f(x) = x^2)))
    @test hash(exs[1]) == hash(RelocatableExpr(:(f(x) = x^2)))
    @test !isequal(exs[2], RelocatableExpr(:(f(x) = x^2)))
    @test isequal(exs[2], RelocatableExpr(:(g(x) = sin(x))))
    @test !isequal(exs[1], RelocatableExpr(:(g(x) = sin(x))))
    @test string(rex) == """
        quote
            f(x) = begin
                    x ^ 2
                end
            g(x) = begin
                    sin(x)
                end
        end"""
end

end # test_relocatable_exprs
