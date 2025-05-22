# Test that one can overload `Revise.parse_source!` and several Base methods to allow revision of
# non-Julia code.

using Revise
using Test

Revise.parsers[".program"] = function (filename::AbstractString)
    exprs = []
    for line in eachline(filename)
       val, name = split(line, '=')
       push!(exprs, :(function $(Symbol(name))() $val end))
    end
    Expr(:toplevel, :(baremodule fake_lang
       $(exprs...)
    end), :(using .fake_lang))
end

@testset "non-jl revisions" begin
    path = joinpath(@__DIR__, "test.program")
    try
        cp(joinpath(@__DIR__, "fake_lang", "test.program"), path, force=true)
        sleep(mtimedelay)
        includet(path)
        @yry()    # comes from test/common.jl
        @test fake_lang.y() == "2"
        @test fake_lang.x() == "1"
        sleep(mtimedelay)
        cp(joinpath(@__DIR__, "fake_lang", "new_test.program"), path, force=true)
        @yry()
        @test fake_lang.x() == "2"
        @test_throws MethodError fake_lang.y()
    finally
        rm(path, force=true)
    end
end
