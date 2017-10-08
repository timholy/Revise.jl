using Revise
using Base.Test
using DataStructures: OrderedSet
using Compat

to_remove = String[]

@testset "Revise" begin

    function collectexprs(ex::Revise.RelocatableExpr)
        exs = Revise.RelocatableExpr[]
        for item in Revise.LineSkippingIterator(ex.args)
            push!(exs, item)
        end
        exs
    end

    @static if is_apple()
        yry() = (sleep(1.1); revise(); sleep(1.1))
    else
        yry() = (sleep(0.1); revise(); sleep(0.1))
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

    @testset "Parse errors" begin
        warnfile = joinpath(tempdir(), randstring(10))
        open(warnfile, "w") do io
            redirect_stderr(io) do
                md = Revise.ModDict(Main=>OrderedSet{Revise.RelocatableExpr}())
                @test !Revise.parse_source!(md, """
f(x) = 1
g(x) = 2
h{x) = 3  # error
k(x) = 4
""",
                                            :test, 1, Main, tempdir())
                @test convert(Revise.RelocatableExpr, :(g(x) = 2)) ∈ md[Main]
            end
        end
        @test contains(read(warnfile, String), "parsing error near line 3")
        rm(warnfile)
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
        @test isequal(revmd[ReviseTest], OrderedSet(collectexprs(cmp)))

        Revise.eval_revised(revmd)
        @test ReviseTest.cube(2) == 8
        @test ReviseTest.Internal.mult3(2) == 6

        # Backtraces
        newmd = Revise.parse_source(fl3, Main, nothing)
        revmd = Revise.revised_statements(newmd, oldmd)
        Revise.eval_revised(revmd)
        try
            ReviseTest.cube(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "cube"
            bt = first(stacktrace(catch_backtrace()))
            @test bt.func == :cube && bt.file == Symbol(fl3) && bt.line == 7
        end
        try
            ReviseTest.Internal.mult2(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "mult2"
            bt = first(stacktrace(catch_backtrace()))
            @test bt.func == :mult2 && bt.file == Symbol(fl3) && bt.line == 13
        end
    end

    @testset "File paths" begin
        testdir = joinpath(tempdir(), randstring(10))
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
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

export $(fbase)1, $(fbase)2, $(fbase)3, $(fbase)4, $(fbase)5, using_macro_$(fbase)

$(fbase)1() = 1

include("file2.jl")
include("subdir/file3.jl")
include(joinpath(@__DIR__, "subdir", "file4.jl"))
otherfile = "file5.jl"
include(otherfile)

# Update order check: modifying `some_macro_` to return -6 doesn't change the
# return value of `using_macro_` (issue #20) unless `using_macro_` is also updated,
# *in this order*:
#   1. update the `@some_macro_` definition
#   2. update the `using_macro_` definition
macro some_macro_$(fbase)()
    return 6
end
using_macro_$(fbase)() = @some_macro_$(fbase)()

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
            open(joinpath(dn, "file5.jl"), "w") do io
                println(io, "$(fbase)5() = 5")
            end
            @eval using $(Symbol(modname))
            fn1, fn2 = Symbol("$(fbase)1"), Symbol("$(fbase)2")
            fn3, fn4 = Symbol("$(fbase)3"), Symbol("$(fbase)4")
            fn5 = Symbol("$(fbase)5")
            fn6 = Symbol("using_macro_$(fbase)")
            @eval @test $(fn1)() == 1
            @eval @test $(fn2)() == 2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == 6
            sleep(0.1)  # to ensure that the file watching has kicked in
            # Change the definition of function 1 (easiest to just rewrite the whole file)
            open(joinpath(dn, modname*".jl"), "w") do io
                println(io, """
__precompile__($pcflag)
module $modname
export $(fbase)1, $(fbase)2, $(fbase)3, $(fbase)4, $(fbase)5, using_mac$(fbase)
$(fbase)1() = -1
include("file2.jl")
include("subdir/file3.jl")
include(joinpath(@__DIR__, "subdir", "file4.jl"))
otherfile = "file5.jl"
include(otherfile)

macro some_macro_$(fbase)()
    return -6
end
using_macro_$(fbase)() = @some_macro_$(fbase)()

end
""")  # just for fun we skipped the whitespace
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == 2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == 6      # because it hasn't been re-macroexpanded
            revise(eval(Symbol(modname)))
            @eval @test $(fn6)() == -6
            # Redefine function 2
            open(joinpath(dn, "file2.jl"), "w") do io
                println(io, "$(fbase)2() = -2")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == -6
            open(joinpath(dn, "subdir", "file3.jl"), "w") do io
                println(io, "$(fbase)3() = -3")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == -3
            @eval @test $(fn4)() == 4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == -6
            open(joinpath(dn, "subdir", "file4.jl"), "w") do io
                println(io, "$(fbase)4() = -4")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == -3
            @eval @test $(fn4)() == -4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == -6
            open(joinpath(dn, "file5.jl"), "w") do io
                println(io, "$(fbase)5() = -5")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == -3
            @eval @test $(fn4)() == -4
            @eval @test $(fn5)() == -5
            @eval @test $(fn6)() == -6
            # Check module2files
            files = [joinpath(dn, modname*".jl"), joinpath(dn, "file2.jl"),
                     joinpath(dn, "subdir", "file3.jl"),
                     joinpath(dn, "subdir", "file4.jl"),
                     joinpath(dn, "file5.jl")]
            @test Revise.module2files[Symbol(modname)] == files
        end
        # Remove the precompiled file
        rm(joinpath(Base.LOAD_CACHE_PATH[1], "PC.ji"))

        # Test files paths that can't be statically parsed
        dn = joinpath(testdir, "LoopInclude", "src")
        mkpath(dn)
        open(joinpath(dn, "LoopInclude.jl"), "w") do io
            println(io, """
module LoopInclude

export li_f, li_g

for fn in ("file1.jl", "file2.jl")
    include(fn)
end

end
""")
        end
        open(joinpath(dn, "file1.jl"), "w") do io
            println(io, "li_f() = 1")
        end
        open(joinpath(dn, "file2.jl"), "w") do io
            println(io, "li_g() = 2")
        end
        @eval using LoopInclude
        @test li_f() == 1
        @test li_g() == 2
        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "file1.jl"), "w") do io
            println(io, "li_f() = -1")
        end
        @test li_f() == 1  # unless the include is at toplevel it is not found

        @test isfile(Revise.sysimg_path)

        pop!(LOAD_PATH)
    end

    # issue #36
    @testset "@__FILE__" begin
        testdir = joinpath(tempdir(), randstring(10))
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "ModFILE", "src")
        mkpath(dn)
        open(joinpath(dn, "ModFILE.jl"), "w") do io
            println(io, """
__precompile__()

module ModFILE

mf() = @__FILE__, 1

end
""")
        end
        @eval using ModFILE
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 1)
        sleep(0.1)
        open(joinpath(dn, "ModFILE.jl"), "w") do io
            println(io, """
__precompile__()

module ModFILE

mf() = @__FILE__, 2

end
""")
        end
        yry()
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 2)
    end

    # issue #8
    @testset "Module docstring" begin
        testdir = joinpath(tempdir(), randstring(10))
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "ModDocstring", "src")
        mkpath(dn)
        open(joinpath(dn, "ModDocstring.jl"), "w") do io
            println(io, """
" Ahoy! "
module ModDocstring

include("dependency.jl")

f() = 1

end
""")
        end
        open(joinpath(dn, "dependency.jl"), "w") do io
            println(io, "")
        end
        @eval using ModDocstring
        @test ModDocstring.f() == 1
        ds = @doc ModDocstring
        @test ds.content[1].content[1].content[1] == "Ahoy! "

        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "ModDocstring.jl"), "w") do io
            println(io, """
" Ahoy! "
module ModDocstring

include("dependency.jl")

f() = 2

end
""")
        end
        yry()
        @test ModDocstring.f() == 2
        ds = @doc ModDocstring
        @test ds.content[1].content[1].content[1] == "Ahoy! "

        open(joinpath(dn, "ModDocstring.jl"), "w") do io
            println(io, """
" Hello! "
module ModDocstring

include("dependency.jl")

f() = 3

end
""")
        end
        yry()
        @test ModDocstring.f() == 3
        ds = @doc ModDocstring
        @test ds.content[end].content[1].content[1] == "Hello! "

        pop!(LOAD_PATH)
    end

    @testset "Line numbers" begin
        # issue #27
        testdir = joinpath(tempdir(), randstring(10))
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        modname = "LineNumberMod"
        dn = joinpath(testdir, modname, "src")
        mkpath(dn)
        open(joinpath(dn, modname*".jl"), "w") do io
            println(io, """
module $modname
include("incl.jl")
end
""")
        end
        open(joinpath(dn, "incl.jl"), "w") do io
            println(io, """
0
0
1
2
3
4
5
6
7
8


function foo(x)
    return x+5
end

foo(y::Int) = y-51
""")
        end
        @eval using LineNumberMod
        lines = Int[]
        files = String[]
        for m in methods(LineNumberMod.foo)
            push!(files, String(m.file))
            push!(lines, m.line)
        end
        @test all(f->endswith(string(f), "incl.jl"), files)
        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "incl.jl"), "w") do io
            println(io, """
0
0
1
2
3
4
5
6
7
8


function foo(x)
    return x+6
end

foo(y::Int) = y-51
""")
        end
        yry()
        for m in methods(LineNumberMod.foo)
            @test endswith(string(m.file), "incl.jl")
            @test m.line ∈ lines
        end
    end

    # Issue #43
    @testset "New submodules" begin
        testdir = joinpath(tempdir(), randstring(10))
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "Submodules", "src")
        mkpath(dn)
        open(joinpath(dn, "Submodules.jl"), "w") do io
            println(io, """
module Submodules
f() = 1
end
""")
        end
        @eval using Submodules
        @test Submodules.f() == 1
        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "Submodules.jl"), "w") do io
            println(io, """
module Submodules
f() = 1
module Sub
g() = 2
end
end
""")
        end
        yry()
        @test Submodules.f() == 1
        @test Submodules.Sub.g() == 2
    end

    @testset "Pkg exclusion" begin
        push!(Revise.dont_watch_pkgs, :Example)
        push!(Revise.silence_pkgs, :Example)
        @eval import Example
        for k in keys(Revise.file2modules)
            if contains(k, "Example")
                error("Should not track files in Example")
            end
        end
        # Ensure that silencing works
        sfile = Revise.silencefile[]  # remember the original
        try
            sfiletemp = tempname()
            Revise.silencefile[] = sfiletemp
            Revise.silence("GSL")
            @test isfile(sfiletemp)
            pkgs = readlines(sfiletemp)
            @test any(p->p=="GSL", pkgs)
            rm(sfiletemp)
        finally
            Revise.silencefile[] = sfile
        end
    end

    @testset "Manual track" begin
        srcfile = joinpath(tempdir(), randstring(10)*".jl")
        open(srcfile, "w") do io
            print(io, """
revise_f(x) = 1
""")
        end
        include(srcfile)
        @test revise_f(10) == 1
        Revise.track(srcfile)
        sleep(0.1)
        open(srcfile, "w") do io
            print(io, """
revise_f(x) = 2
""")
        end
        yry()
        @test revise_f(10) == 2
        push!(to_remove, srcfile)

        # Do it again with a relative path
        curdir = pwd()
        cd(tempdir())
        srcfile = randstring(10)*".jl"
        open(srcfile, "w") do io
            print(io, """
        revise_floc(x) = 1
        """)
        end
        include(joinpath(pwd(), srcfile))
        @test revise_floc(10) == 1
        Revise.track(srcfile)
        sleep(0.1)
        open(srcfile, "w") do io
            print(io, """
        revise_floc(x) = 2
        """)
        end
        yry()
        @test revise_floc(10) == 2
        push!(to_remove, joinpath(tempdir(), srcfile))
        cd(curdir)

        # Tracking Base
        Revise.track(Base)
        @test any(k->endswith(k, "number.jl"), keys(Revise.file2modules))
    end

    @testset "Cleanup" begin
        warnfile = joinpath(tempdir(), randstring(10))
        open(warnfile, "w") do io
            redirect_stderr(io) do
                for name in to_remove
                    try
                        rm(name; force=true, recursive=true)
                        deleteat!(LOAD_PATH, find(LOAD_PATH .== name))
                    end
                end
                yry()
            end
        end
        if !is_apple()
            @test contains(read(warnfile, String), "is not an existing directory")
        end
        rm(warnfile)
    end
end
