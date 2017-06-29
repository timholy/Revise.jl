using Revise
using Base.Test

to_remove = String[]

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

    @testset "File paths" begin
        testdir = tempname()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        yry() = (sleep(0.1); revise(); sleep(0.1))
        for (pcflag, fbase) in ((true, "pc"), (false, "npc"))  # precompiled & not
            modname = uppercase(fbase)
            # Create a package with the following structure:
            #   src/PkgName.jl   # PC.jl = precompiled, NPC.jl = nonprecompiled
            #   src/file2.jl
            #   src/subdir/file3.jl
            #   src/subdir/file4.jl
            # exploring different ways of expressing the `include` statement
            dn = joinpath(testdir, modname, "src")
            mkpath(dn)
            open(joinpath(dn, modname*".jl"), "w") do io
                println(io, """
__precompile__($pcflag)

module $modname

export $(fbase)1, $(fbase)2, $(fbase)3, $(fbase)4

$(fbase)1() = 1

include("file2.jl")
include("subdir/file3.jl")
include(joinpath(@__DIR__, "subdir", "file4.jl"))

end
""")
            end
            open(joinpath(dn, "file2.jl"), "w") do io
                println(io, "$(fbase)2() = 2")
            end
            mkdir(joinpath(dn, "subdir"))
            open(joinpath(dn, "subdir", "file3.jl"), "w") do io
                println(io, "$(fbase)3() = 3")
            end
            open(joinpath(dn, "subdir", "file4.jl"), "w") do io
                println(io, "$(fbase)4() = 4")
            end
            @eval using $(Symbol(modname))
            fn1, fn2 = Symbol("$(fbase)1"), Symbol("$(fbase)2")
            fn3, fn4 = Symbol("$(fbase)3"), Symbol("$(fbase)4")
            @eval @test $(fn1)() == 1
            @eval @test $(fn2)() == 2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            sleep(0.1)  # to ensure that the file watching has kicked in
            # Change the definition of function 1 (easiest to just rewrite the whole file)
            open(joinpath(dn, modname*".jl"), "w") do io
                println(io, """
__precompile__($pcflag)
module $modname
export $(fbase)1, $(fbase)2, $(fbase)3, $(fbase)4
$(fbase)1() = -1
include("file2.jl")
include("subdir/file3.jl")
include(joinpath(@__DIR__, "subdir", "file4.jl"))
end
""")  # just for fun we skipped the whitespace
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == 2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            # Redefine function 2
            open(joinpath(dn, "file2.jl"), "w") do io
                println(io, "$(fbase)2() = -2")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            open(joinpath(dn, "subdir", "file3.jl"), "w") do io
                println(io, "$(fbase)3() = -3")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == -3
            @eval @test $(fn4)() == 4
            open(joinpath(dn, "subdir", "file4.jl"), "w") do io
                println(io, "$(fbase)4() = -4")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == -3
            @eval @test $(fn4)() == -4
        end
    end
end

# These may cause warning messages about "not an existing file", but that's fine
for name in to_remove
    rm(name; force=true, recursive=true)
end
