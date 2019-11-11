# REVISE: DO NOT PARSE   # For people with JULIA_REVISE_INCLUDE=1
using Revise, CodeTracking, JuliaInterpreter
using Test

@test isempty(detect_ambiguities(Revise, Base, Core))

using Pkg, Unicode, Distributed, InteractiveUtils, REPL, UUIDs
import LibGit2
using OrderedCollections: OrderedSet
using Test: collect_test_logs
using Base.CoreLogging: Debug,Info

include("common.jl")

throwing_function(bt) = bt[2]

function rm_precompile(pkgname::AbstractString)
    filepath = Base.cache_file_entry(Base.PkgId(pkgname))
    isa(filepath, Tuple) && (filepath = filepath[1]*filepath[2])  # Julia 1.3+
    for depot in DEPOT_PATH
        fullpath = joinpath(depot, filepath)
        isfile(fullpath) && rm(fullpath)
    end
end

# A junk module that we can evaluate into
module ReviseTestPrivate
struct Inner
    x::Float64
end

macro changeto1(args...)
    return 1
end

macro donothing(ex)
    esc(ex)
end

macro addint(ex)
    :($(esc(ex))::$(esc(Int)))
end

# The following two submodules are for testing #199
module A
f(x::Int) = 1
end

module B
f(x::Int) = 1
module Core end
end

end

function private_module()
    modname = gensym()
    Core.eval(ReviseTestPrivate, :(module $modname end))
end

sig_type_exprs(ex) = Revise.sig_type_exprs(Main, ex)   # just for testing purposes

# accomodate changes in Dict printing w/ Julia version
const pair_op_compact = let io = IOBuffer()
    print(IOContext(io, :compact=>true), Dict(1=>2))
    String(take!(io))[7:end-2]
end

@testset "Revise" begin
    @testset "PkgData" begin
        # Related to #358
        id = Base.PkgId(Main)
        pd = Revise.PkgData(id)
        @test isempty(Revise.basedir(pd))
    end

    @testset "LineSkipping" begin
        rex = Revise.RelocatableExpr(quote
                                    f(x) = x^2
                                    g(x) = sin(x)
                                    end)
        @test length(Expr(rex).args) == 4  # including the line number expressions
        exs = collectexprs(rex)
        @test length(exs) == 2
        @test isequal(exs[1], Revise.RelocatableExpr(:(f(x) = x^2)))
        @test hash(exs[1]) == hash(Revise.RelocatableExpr(:(f(x) = x^2)))
        @test !isequal(exs[2], Revise.RelocatableExpr(:(f(x) = x^2)))
        @test isequal(exs[2], Revise.RelocatableExpr(:(g(x) = sin(x))))
        @test !isequal(exs[1], Revise.RelocatableExpr(:(g(x) = sin(x))))
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

    @testset "Equality and hashing" begin
        # issue #233
        @test  isequal(Revise.RelocatableExpr(:(x = 1)), Revise.RelocatableExpr(:(x = 1)))
        @test !isequal(Revise.RelocatableExpr(:(x = 1)), Revise.RelocatableExpr(:(x = 1.0)))
        @test hash(Revise.RelocatableExpr(:(x = 1))) == hash(Revise.RelocatableExpr(:(x = 1)))
        @test hash(Revise.RelocatableExpr(:(x = 1))) != hash(Revise.RelocatableExpr(:(x = 1.0)))
        @test hash(Revise.RelocatableExpr(:(x = 1))) != hash(Revise.RelocatableExpr(:(x = 2)))
    end

    @testset "Parse errors" begin
        md = Revise.ModuleExprsSigs(Main)
        @test_throws LoadError Revise.parse_source!(md, """
begin # this block should parse correctly, cf. issue #109

end
f(x) = 1
g(x) = 2
h{x) = 3  # error
k(x) = 4
""", "test", Main)
    end

    @testset "Signature extraction" begin
        jidir = dirname(dirname(pathof(JuliaInterpreter)))
        scriptfile = joinpath(jidir, "test", "toplevel_script.jl")
        modex = :(module Toplevel include($scriptfile) end)
        mod = eval(modex)
        mexs = Revise.parse_source(scriptfile, mod)
        Revise.instantiate_sigs!(mexs)
        nms = names(mod; all=true)
        modeval, modinclude = getfield(mod, :eval), getfield(mod, :include)
        failed = []
        n = 0
        for fsym in nms
            f = getfield(mod, fsym)
            isa(f, Base.Callable) || continue
            (f === modeval || f === modinclude) && continue
            for m in methods(f)
                # MyInt8 brings in lots of number & type machinery, which leads
                # to wandering through Base files. At this point we just want
                # to test whether we have the basics down, so for now avoid
                # looking in any file other than the script
                string(m.file) == scriptfile || continue
                isa(definition(m), Expr) || push!(failed, m.sig)
                n += 1
            end
        end
        @test isempty(failed)
        @test n > length(nms)/2
    end

    @testset "Comparison and line numbering" begin
        # We'll also use these tests to try out the logging system
        rlogger = Revise.debug_logger()

        fl1 = joinpath(@__DIR__, "revisetest.jl")
        fl2 = joinpath(@__DIR__, "revisetest_revised.jl")
        fl3 = joinpath(@__DIR__, "revisetest_errors.jl")

        # Copy the files to a temporary file. This is to ensure that file name doesn't change
        # in docstring macros and backtraces.
        tmpfile = joinpath(tempdir(), randstring(10))*".jl"
        push!(to_remove, tmpfile)

        cp(fl1, tmpfile)
        include(tmpfile)  # So the modules are defined
        # test the "mistakes"
        @test ReviseTest.cube(2) == 16
        @test ReviseTest.Internal.mult3(2) == 8
        @test ReviseTest.Internal.mult4(2) == -2
        # One method will be deleted, for log testing we need to grab it while we still have it
        delmeth = first(methods(ReviseTest.Internal.mult4))
        mmult3 = @which ReviseTest.Internal.mult3(2)

        mexsold = Revise.parse_source(tmpfile, Main)
        Revise.instantiate_sigs!(mexsold)
        mcube = @which ReviseTest.cube(2)

        cp(fl2, tmpfile; force=true)
        mexsnew = Revise.parse_source(tmpfile, Main)
        mexsnew = Revise.eval_revised(mexsnew, mexsold)
        @test ReviseTest.cube(2) == 8
        @test ReviseTest.Internal.mult3(2) == 6

        @test length(mexsnew) == 3
        @test haskey(mexsnew, ReviseTest) && haskey(mexsnew, ReviseTest.Internal)

        dvs = collect(mexsnew[ReviseTest])
        @test length(dvs) == 3
        (def, val) = dvs[1]
        @test isequal(def, Revise.RelocatableExpr(:(square(x) = x^2)))
        @test val == [Tuple{typeof(ReviseTest.square),Any}]
        @test Revise.firstline(Revise.unwrap(def)).line == 5
        m = @which ReviseTest.square(1)
        @test m.line == 5
        @test whereis(m) == (tmpfile, 5)
        @test Revise.RelocatableExpr(definition(m)) == def
        (def, val) = dvs[2]
        @test isequal(def, Revise.RelocatableExpr(:(cube(x) = x^3)))
        @test val == [Tuple{typeof(ReviseTest.cube),Any}]
        m = @which ReviseTest.cube(1)
        @test m.line == 7
        @test whereis(m) == (tmpfile, 7)
        @test Revise.RelocatableExpr(definition(m)) == def
        (def, val) = dvs[3]
        @test isequal(def, Revise.RelocatableExpr(:(fourth(x) = x^4)))
        @test val == [Tuple{typeof(ReviseTest.fourth),Any}]
        m = @which ReviseTest.fourth(1)
        @test m.line == 9
        @test whereis(m) == (tmpfile, 9)
        @test Revise.RelocatableExpr(definition(m)) == def

        dvs = collect(mexsnew[ReviseTest.Internal])
        @test length(dvs) == 5
        (def, val) = dvs[1]
        @test isequal(def,  Revise.RelocatableExpr(:(mult2(x) = 2*x)))
        @test val == [Tuple{typeof(ReviseTest.Internal.mult2),Any}]
        @test Revise.firstline(Revise.unwrap(def)).line == 13
        m = @which ReviseTest.Internal.mult2(1)
        @test m.line == 11
        @test whereis(m) == (tmpfile, 13)
        @test Revise.RelocatableExpr(definition(m)) == def
        (def, val) = dvs[2]
        @test isequal(def, Revise.RelocatableExpr(:(mult3(x) = 3*x)))
        @test val == [Tuple{typeof(ReviseTest.Internal.mult3),Any}]
        m = @which ReviseTest.Internal.mult3(1)
        @test m.line == 14
        @test whereis(m) == (tmpfile, 14)
        @test Revise.RelocatableExpr(definition(m)) == def

        @test_throws MethodError ReviseTest.Internal.mult4(2)

        function cmpdiff(record, msg; kwargs...)
            record.message == msg
            for (kw, val) in kwargs
                logval = record.kwargs[kw]
                for (v, lv) in zip(val, logval)
                    isa(v, Expr) && (v = Revise.RelocatableExpr(v))
                    isa(lv, Expr) && (lv = Revise.RelocatableExpr(lv))
                    @test lv == v
                end
            end
            return nothing
        end
        logs = filter(r->r.level==Debug && r.group=="Action", rlogger.logs)
        @test length(logs) == 9
        cmpdiff(logs[1], "DeleteMethod"; deltainfo=(Tuple{typeof(ReviseTest.cube),Any}, MethodSummary(mcube)))
        cmpdiff(logs[2], "DeleteMethod"; deltainfo=(Tuple{typeof(ReviseTest.Internal.mult3),Any}, MethodSummary(mmult3)))
        cmpdiff(logs[3], "DeleteMethod"; deltainfo=(Tuple{typeof(ReviseTest.Internal.mult4),Any}, MethodSummary(delmeth)))
        cmpdiff(logs[4], "Eval"; deltainfo=(ReviseTest, :(cube(x) = x^3)))
        cmpdiff(logs[5], "Eval"; deltainfo=(ReviseTest, :(fourth(x) = x^4)))
        stmpfile = Symbol(tmpfile)
        cmpdiff(logs[6], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.mult2),Any}], LineNumberNode(11,stmpfile)=>LineNumberNode(13,stmpfile)))
        cmpdiff(logs[7], "Eval"; deltainfo=(ReviseTest.Internal, :(mult3(x) = 3*x)))
        cmpdiff(logs[8], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.unchanged),Any}], LineNumberNode(18,stmpfile)=>LineNumberNode(19,stmpfile)))
        cmpdiff(logs[9], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.unchanged2),Any}], LineNumberNode(20,stmpfile)=>LineNumberNode(21,stmpfile)))
        @test length(Revise.actions(rlogger)) == 6  # by default LineOffset is skipped
        @test length(Revise.actions(rlogger; line=true)) == 9
        @test_broken length(Revise.diffs(rlogger)) == 2
        empty!(rlogger.logs)

        # Backtraces. Note this doesn't test the line-number correction
        # because both of these are revised definitions.
        cp(fl3, tmpfile; force=true)
        mexsold = mexsnew
        mexsnew = Revise.parse_source(tmpfile, Main)
        mexsnew = Revise.eval_revised(mexsnew, mexsold)
        try
            ReviseTest.cube(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "cube"
            bt = throwing_function(stacktrace(catch_backtrace()))
            @test bt.func == :cube && bt.file == Symbol(tmpfile) && bt.line == 7
        end
        try
            ReviseTest.Internal.mult2(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "mult2"
            bt = throwing_function(stacktrace(catch_backtrace()))
            @test bt.func == :mult2 && bt.file == Symbol(tmpfile) && bt.line == 13
        end

        logs = filter(r->r.level==Debug && r.group=="Action", rlogger.logs)
        @test length(logs) == 4
        cmpdiff(logs[3], "Eval"; deltainfo=(ReviseTest, :(cube(x) = error("cube"))))
        cmpdiff(logs[4], "Eval"; deltainfo=(ReviseTest.Internal, :(mult2(x) = error("mult2"))))

        # Turn off future logging
        Revise.debug_logger(; min_level=Info)

        # Gensymmed symbols
        rex1 = Revise.RelocatableExpr(macroexpand(Main, :(t = @elapsed(foo(x)))))
        rex2 = Revise.RelocatableExpr(macroexpand(Main, :(t = @elapsed(foo(x)))))
        @test isequal(rex1, rex2)
        @test hash(rex1) == hash(rex2)
        rex3 = Revise.RelocatableExpr(macroexpand(Main, :(t = @elapsed(bar(x)))))
        @test !isequal(rex1, rex3)
        @test hash(rex1) != hash(rex3)
        sym1, sym2 = gensym(:hello), gensym(:hello)
        rex1 = Revise.RelocatableExpr(:(x = $sym1))
        rex2 = Revise.RelocatableExpr(:(x = $sym2))
        @test isequal(rex1, rex2)
        @test hash(rex1) == hash(rex2)
        sym3 = gensym(:world)
        rex3 = Revise.RelocatableExpr(:(x = $sym3))
        @test isequal(rex1, rex3)
        @test hash(rex1) == hash(rex3)
    end

    @testset "Display" begin
        io = IOBuffer()
        show(io, Revise.RelocatableExpr(:(@inbounds x[2])))
        str = String(take!(io))
        @test str == ":(@inbounds x[2])"
        mod = private_module()
        file = joinpath(@__DIR__, "revisetest.jl")
        Base.include(mod, file)
        mexs = Revise.parse_source(file, mod)
        Revise.instantiate_sigs!(mexs)
        io = IOBuffer()
        print(IOContext(io, :compact=>true), mexs)
        str = String(take!(io))
        @test str == "OrderedCollections.OrderedDict($mod$(pair_op_compact)ExprsSigs(<1 expressions>, <0 signatures>),$mod.ReviseTest$(pair_op_compact)ExprsSigs(<2 expressions>, <2 signatures>),$mod.ReviseTest.Internal$(pair_op_compact)ExprsSigs(<6 expressions>, <5 signatures>))"
        exs = mexs[getfield(mod, :ReviseTest)]
        io = IOBuffer()
        print(IOContext(io, :compact=>true), exs)
        @test String(take!(io)) == "ExprsSigs(<2 expressions>, <2 signatures>)"
        print(IOContext(io, :compact=>false), exs)
        str = String(take!(io))
        @test str == "ExprsSigs with the following expressions: \n  :(square(x) = begin\n          x ^ 2\n      end)\n  :(cube(x) = begin\n          x ^ 4\n      end)"
    end

    @testset "File paths" begin
        testdir = newtestdir()
        for (pcflag, fbase) in ((true, "pc"), (false, "npc"),)  # precompiled & not
            modname = uppercase(fbase)
            pcexpr = pcflag ? "" : :(__precompile__(false))
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
$pcexpr
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
            sleep(mtimedelay)
            @eval using $(Symbol(modname))
            sleep(mtimedelay)
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
            m = @eval first(methods($fn1))
            rex = Revise.RelocatableExpr(definition(m))
            @test rex == convert(Revise.RelocatableExpr, :( $fn1() = 1 ))
            # Check that definition returns copies
            rex2 = deepcopy(rex)
            rex.ex.args[end].args[end] = 2
            @test Revise.RelocatableExpr(definition(m)) == rex2
            @test Revise.RelocatableExpr(definition(m)) != rex
            # CodeTracking methods
            m3 = first(methods(eval(fn3)))
            m3file = joinpath(dn, "subdir", "file3.jl")
            @test whereis(m3) == (m3file, 1)
            @test signatures_at(m3file, 1) == [m3.sig]
            @test signatures_at(eval(Symbol(modname)), joinpath("src", "subdir", "file3.jl"), 1) == [m3.sig]

            # Change the definition of function 1 (easiest to just rewrite the whole file)
            open(joinpath(dn, modname*".jl"), "w") do io
                println(io, """
$pcexpr
module $modname
export $(fbase)1, $(fbase)2, $(fbase)3, $(fbase)4, $(fbase)5, using_macro_$(fbase)
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
            @test revise(eval(Symbol(modname)))
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
            # Check that the list of files is complete
            pkgdata = Revise.pkgdatas[Base.PkgId(modname)]
            for file = [joinpath("src", modname*".jl"), joinpath("src", "file2.jl"),
                        joinpath("src", "subdir", "file3.jl"),
                        joinpath("src", "subdir", "file4.jl"),
                        joinpath("src", "file5.jl")]
                @test Revise.hasfile(pkgdata, file)
            end
        end
        # Remove the precompiled file
        rm_precompile("PC")

        # Submodules (issue #142)
        srcdir = joinpath(testdir, "Mysupermodule", "src")
        subdir = joinpath(srcdir, "Mymodule")
        mkpath(subdir)
        open(joinpath(srcdir, "Mysupermodule.jl"), "w") do io
            print(io, """
                module Mysupermodule
                include("Mymodule/Mymodule.jl")
                end
                """)
        end
        open(joinpath(subdir, "Mymodule.jl"), "w") do io
            print(io, """
                module Mymodule
                include("filesub.jl")
                end
                """)
        end
        open(joinpath(subdir, "filesub.jl"), "w") do io
            print(io, """
                func() = 1
                """)
        end
        sleep(mtimedelay)
        @eval using Mysupermodule
        sleep(mtimedelay)
        @test Mysupermodule.Mymodule.func() == 1
        open(joinpath(subdir, "filesub.jl"), "w") do io
            print(io, """
                func() = 2
                """)
        end
        yry()
        @test Mysupermodule.Mymodule.func() == 2
        rm_precompile("Mymodule")
        rm_precompile("Mysupermodule")

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
        sleep(mtimedelay)
        @eval using LoopInclude
        sleep(mtimedelay)
        @test li_f() == 1
        @test li_g() == 2
        open(joinpath(dn, "file1.jl"), "w") do io
            println(io, "li_f() = -1")
        end
        yry()
        @test li_f() == -1
        rm_precompile("LoopInclude")

        # Multiple packages in the same directory (issue #228)
        open(joinpath(testdir, "A228.jl"), "w") do io
            println(io, """
                        module A228
                        using B228
                        export f228
                        f228(x) = 3 * g228(x)
                        end
                        """)
        end
        open(joinpath(testdir, "B228.jl"), "w") do io
            println(io, """
                        module B228
                        export g228
                        g228(x) = 4x + 2
                        end
                        """)
        end
        sleep(mtimedelay)
        using A228
        sleep(mtimedelay)
        @test f228(3) == 42
        open(joinpath(testdir, "B228.jl"), "w") do io
            println(io, """
                        module B228
                        export g228
                        g228(x) = 4x + 1
                        end
                        """)
        end
        yry()
        @test f228(3) == 39
        rm_precompile("A228")
        rm_precompile("B228")

        # uncoupled packages in the same directory (issue #339)
        open(joinpath(testdir, "A339.jl"), "w") do io
            println(io, """
                        module A339
                        f() = 1
                        end
                        """)
        end
        open(joinpath(testdir, "B339.jl"), "w") do io
            println(io, """
                        module B339
                        f() = 1
                        end
                        """)
        end
        sleep(mtimedelay)
        using A339, B339
        sleep(mtimedelay)
        @test A339.f() == 1
        @test B339.f() == 1
        open(joinpath(testdir, "A339.jl"), "w") do io
            println(io, """
                        module A339
                        f() = 2
                        end
                        """)
        end
        yry()
        @test A339.f() == 2
        @test B339.f() == 1
        open(joinpath(testdir, "B339.jl"), "w") do io
            println(io, """
                        module B339
                        f() = 2
                        end
                        """)
        end
        yry()
        @test A339.f() == 2
        @test B339.f() == 2
        rm_precompile("A339")
        rm_precompile("B339")

        pop!(LOAD_PATH)
    end

    # issue #131
    @testset "Base & stdlib file paths" begin
        @test isfile(Revise.basesrccache)
        targetfn = Base.Filesystem.path_separator * joinpath("good", "path", "mydir", "myfile.jl")
        @test Revise.fixpath("/some/bad/path/mydir/myfile.jl"; badpath="/some/bad/path", goodpath="/good/path") == targetfn
        @test Revise.fixpath("/some/bad/path/mydir/myfile.jl"; badpath="/some/bad/path/", goodpath="/good/path") == targetfn
        @test isfile(Revise.fixpath(Base.find_source_file("array.jl")))
        failedfiles = Tuple{String,String}[]
        for (mod,file) = Base._included_files
            fixedfile = Revise.fixpath(file)
            if !isfile(fixedfile)
                push!(failedfiles, (file, fixedfile))
            end
        end
        if !isempty(failedfiles)
            display(failedfiles)
        end
        @test isempty(failedfiles)
    end

    # issue #318
    @testset "Cross-module extension" begin
        testdir = newtestdir()
        dnA = joinpath(testdir, "CrossModA", "src")
        mkpath(dnA)
        open(joinpath(dnA, "CrossModA.jl"), "w") do io
            println(io, """
            module CrossModA
            foo(x) = "default"
            end
            """)
        end
        dnB = joinpath(testdir, "CrossModB", "src")
        mkpath(dnB)
        open(joinpath(dnB, "CrossModB.jl"), "w") do io
            println(io, """
            module CrossModB
            import CrossModA
            CrossModA.foo(x::Int) = 1
            end
            """)
        end
        sleep(mtimedelay)
        @eval using CrossModA, CrossModB
        @test CrossModA.foo("") == "default"
        @test CrossModA.foo(0) == 1
        sleep(mtimedelay)
        open(joinpath(dnB, "CrossModB.jl"), "w") do io
            println(io, """
            module CrossModB
            import CrossModA
            CrossModA.foo(x::Int) = 2
            end
            """)
        end
        yry()
        @test CrossModA.foo("") == "default"
        @test CrossModA.foo(0) == 2
        open(joinpath(dnB, "CrossModB.jl"), "w") do io
            println(io, """
            module CrossModB
            import CrossModA
            CrossModA.foo(x::Int) = 3
            end
            """)
        end
        yry()
        @test CrossModA.foo("") == "default"
        @test CrossModA.foo(0) == 3

        rm_precompile("CrossModA")
        rm_precompile("CrossModB")
        pop!(LOAD_PATH)
    end

    # issue #36
    @testset "@__FILE__" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "ModFILE", "src")
        mkpath(dn)
        open(joinpath(dn, "ModFILE.jl"), "w") do io
            println(io, """
module ModFILE

mf() = @__FILE__, 1

end
""")
        end
        sleep(mtimedelay)
        @eval using ModFILE
        sleep(mtimedelay)
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 1)
        open(joinpath(dn, "ModFILE.jl"), "w") do io
            println(io, """
module ModFILE

mf() = @__FILE__, 2

end
""")
        end
        yry()
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 2)
        rm_precompile("ModFILE")
        pop!(LOAD_PATH)
    end

    # issue #8
    @testset "Module docstring" begin
        testdir = newtestdir()
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
        sleep(mtimedelay)
        @eval using ModDocstring
        sleep(mtimedelay)
        @test ModDocstring.f() == 1
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Ahoy! "

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
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Ahoy! "

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
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Hello! "
        rm_precompile("ModDocstring")
        pop!(LOAD_PATH)
    end

    @testset "Undef in docstrings" begin
        fn = Base.find_source_file("abstractset.jl")   # has lots of examples of """str""" func1, func2
        mexsold = Revise.parse_source(fn, Base)
        mexsnew = Revise.parse_source(fn, Base)
        odict = mexsold[Base]
        ndict = mexsnew[Base]
        for (k, v) in odict
            @test haskey(ndict, k)
        end
    end

    @testset "Macro docstrings (issue #309)" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "MacDocstring", "src")
        mkpath(dn)
        open(joinpath(dn, "MacDocstring.jl"), "w") do io
            println(io, """
            module MacDocstring

            macro myconst(name, val)
                quote
                    \"\"\"
                        mydoc
                    \"\"\"
                    const \$(esc(name)) = \$val
                end
            end

            @myconst c 1.2
            f() = 1

            end # module
            """)
        end
        sleep(mtimedelay)
        @eval using MacDocstring
        sleep(mtimedelay)
        @test MacDocstring.f() == 1
        ds = @doc(MacDocstring.c)
        @test strip(get_docstring(ds)) == "mydoc"

        open(joinpath(dn, "MacDocstring.jl"), "w") do io
            println(io, """
            module MacDocstring

            macro myconst(name, val)
                quote
                    \"\"\"
                        mydoc
                    \"\"\"
                    const \$(esc(name)) = \$val
                end
            end

            @myconst c 1.2
            f() = 2

            end # module
            """)
        end
        yry()
        @test MacDocstring.f() == 2
        ds = @doc(MacDocstring.c)
        @test strip(get_docstring(ds)) == "mydoc"

        rm_precompile("MacDocstring")
        pop!(LOAD_PATH)
    end

    # issue #165
    @testset "Changing @inline annotations" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "PerfAnnotations", "src")
        mkpath(dn)
        open(joinpath(dn, "PerfAnnotations.jl"), "w") do io
            println(io, """
            module PerfAnnotations

            @inline hasinline(x) = x
            check_hasinline(x) = hasinline(x)

            @noinline hasnoinline(x) = x
            check_hasnoinline(x) = hasnoinline(x)

            notannot1(x) = x
            check_notannot1(x) = notannot1(x)

            notannot2(x) = x
            check_notannot2(x) = notannot2(x)

            end
            """)
        end
        sleep(mtimedelay)
        @eval using PerfAnnotations
        sleep(mtimedelay)
        @test PerfAnnotations.check_hasinline(3) == 3
        @test PerfAnnotations.check_hasnoinline(3) == 3
        @test PerfAnnotations.check_notannot1(3) == 3
        @test PerfAnnotations.check_notannot2(3) == 3
        ci = code_typed(PerfAnnotations.check_hasinline, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_hasnoinline, Tuple{Int})[1].first
        @test length(ci.code) == 2 && ci.code[1].head == :invoke
        ci = code_typed(PerfAnnotations.check_notannot1, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_notannot2, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        open(joinpath(dn, "PerfAnnotations.jl"), "w") do io
            println(io, """
            module PerfAnnotations

            hasinline(x) = x
            check_hasinline(x) = hasinline(x)

            hasnoinline(x) = x
            check_hasnoinline(x) = hasnoinline(x)

            @inline notannot1(x) = x
            check_notannot1(x) = notannot1(x)

            @noinline notannot2(x) = x
            check_notannot2(x) = notannot2(x)

            end
            """)
        end
        yry()
        @test PerfAnnotations.check_hasinline(3) == 3
        @test PerfAnnotations.check_hasnoinline(3) == 3
        @test PerfAnnotations.check_notannot1(3) == 3
        @test PerfAnnotations.check_notannot2(3) == 3
        ci = code_typed(PerfAnnotations.check_hasinline, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_hasnoinline, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_notannot1, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_notannot2, Tuple{Int})[1].first
        @test length(ci.code) == 2 && ci.code[1].head == :invoke
        rm_precompile("PerfAnnotations")

        pop!(LOAD_PATH)
    end

    @testset "Revising macros" begin
        # issue #174
        testdir = newtestdir()
        dn = joinpath(testdir, "MacroRevision", "src")
        mkpath(dn)
        open(joinpath(dn, "MacroRevision.jl"), "w") do io
            println(io, """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 1
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        end
        sleep(mtimedelay)
        @eval using MacroRevision
        sleep(mtimedelay)
        @test MacroRevision.foo("hello") == 1

        open(joinpath(dn, "MacroRevision.jl"), "w") do io
            println(io, """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 2
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        end
        yry()
        @test MacroRevision.foo("hello") == 1
        revise(MacroRevision)
        @test MacroRevision.foo("hello") == 2

        open(joinpath(dn, "MacroRevision.jl"), "w") do io
            println(io, """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 3
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        end
        yry()
        @test MacroRevision.foo("hello") == 2
        revise(MacroRevision)
        @test MacroRevision.foo("hello") == 3
        rm_precompile("MacroRevision")
        pop!(LOAD_PATH)
    end

    @testset "More arg-modifying macros" begin
        # issue #183
        testdir = newtestdir()
        dn = joinpath(testdir, "ArgModMacros", "src")
        mkpath(dn)
        open(joinpath(dn, "ArgModMacros.jl"), "w") do io
            println(io, """
            module ArgModMacros

            using EponymTuples

            const revision = Ref(0)

            function hyper_loglikelihood(@eponymargs(μ, σ, LΩ), @eponymargs(w̃s, α̃s, β̃s))
                revision[] = 1
                loglikelihood_normal(@eponymtuple(μ, σ, LΩ), vcat(w̃s, α̃s, β̃s))
            end

            loglikelihood_normal(@eponymargs(μ, σ, LΩ), stuff) = stuff

            end
            """)
        end
        sleep(mtimedelay)
        @eval using ArgModMacros
        sleep(mtimedelay)
        @test ArgModMacros.hyper_loglikelihood((μ=1, σ=2, LΩ=3), (w̃s=4, α̃s=5, β̃s=6)) == [4,5,6]
        @test ArgModMacros.revision[] == 1
        open(joinpath(dn, "ArgModMacros.jl"), "w") do io
            println(io, """
            module ArgModMacros

            using EponymTuples

            const revision = Ref(0)

            function hyper_loglikelihood(@eponymargs(μ, σ, LΩ), @eponymargs(w̃s, α̃s, β̃s))
                revision[] = 2
                loglikelihood_normal(@eponymtuple(μ, σ, LΩ), vcat(w̃s, α̃s, β̃s))
            end

            loglikelihood_normal(@eponymargs(μ, σ, LΩ), stuff) = stuff

            end
            """)
        end
        yry()
        @test ArgModMacros.hyper_loglikelihood((μ=1, σ=2, LΩ=3), (w̃s=4, α̃s=5, β̃s=6)) == [4,5,6]
        @test ArgModMacros.revision[] == 2
        rm_precompile("ArgModMacros")
        pop!(LOAD_PATH)
    end

    @testset "Line numbers" begin
        # issue #27
        testdir = newtestdir()
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
        sleep(mtimedelay)
        @eval using LineNumberMod
        sleep(mtimedelay)
        lines = Int[]
        files = String[]
        for m in methods(LineNumberMod.foo)
            push!(files, String(m.file))
            push!(lines, m.line)
        end
        @test all(f->endswith(string(f), "incl.jl"), files)
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
        rm_precompile("LineNumberMod")
        pop!(LOAD_PATH)
    end

    @testset "Line numbers in backtraces and warnings" begin
        filename = randtmp() * ".jl"
        open(filename, "w") do io
            println(io, """
            function triggered(iserr::Bool, iswarn::Bool)
                iserr && error("error")
                iswarn && @warn "Information"
                return nothing
            end
            """)
        end
        sleep(mtimedelay)
        includet(filename)
        sleep(mtimedelay)
        try
            triggered(true, false)
            @test false
        catch err
            bt = throwing_function(Revise.update_stacktrace_lineno!(stacktrace(catch_backtrace())))
            @test bt.file == Symbol(filename) && bt.line == 2
        end
        io = IOBuffer()
        if isdefined(Base, :methodloc_callback)
            print(io, methods(triggered))
            @test occursin(filename * ":2", String(take!(io)))
        end
        open(filename, "w") do io
            println(io, """
            # A comment to change the line numbers
            function triggered(iserr::Bool, iswarn::Bool)
                iserr && error("error")
                iswarn && @warn "Information"
                return nothing
            end
            """)
        end
        yry()
        try
            triggered(true, false)
            @test false
        catch err
            bt = throwing_function(Revise.update_stacktrace_lineno!(stacktrace(catch_backtrace())))
            @test bt.file == Symbol(filename) && bt.line == 3
        end
        st = try
            triggered(true, false)
            @test false
        catch err
            stacktrace(catch_backtrace())
        end
        targetstr = filename * ":3"
        Base.show_backtrace(io, st)
        @test occursin(targetstr, String(take!(io)))
        # Long stacktraces take a different path, test this too
        while length(st) < 100
            st = vcat(st, st)
        end
        Base.show_backtrace(io, st)
        @test occursin(targetstr, String(take!(io)))
        if isdefined(Base, :methodloc_callback)
            print(io, methods(triggered))
            @test occursin(filename * ":3", String(take!(io)))
        end

        push!(to_remove, filename)
    end

    # Issue #43
    @testset "New submodules" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "Submodules", "src")
        mkpath(dn)
        open(joinpath(dn, "Submodules.jl"), "w") do io
            println(io, """
module Submodules
f() = 1
end
""")
        end
        sleep(mtimedelay)
        @eval using Submodules
        sleep(mtimedelay)
        @test Submodules.f() == 1
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
        rm_precompile("Submodules")
        pop!(LOAD_PATH)
    end

    @testset "Timing (issue #341)" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "Timing", "src")
        mkpath(dn)
        open(joinpath(dn, "Timing.jl"), "w") do io
            println(io, """
            module Timing
            f(x) = 1
            end
            """)
        end
        sleep(mtimedelay)
        @eval using Timing
        sleep(mtimedelay)
        @test Timing.f(nothing) == 1
        tmpfile = joinpath(dn, "Timing_temp.jl")
        open(tmpfile, "w") do io
            println(io, """
            module Timing
            f(x) = 2
            end
            """)
        end
        yry()
        @test Timing.f(nothing) == 1
        mv(tmpfile, pathof(Timing), force=true)
        yry()
        @test Timing.f(nothing) == 2

        rm_precompile("Timing")
    end

    @testset "Method deletion" begin
        Core.eval(Base, :(revisefoo(x::Float64) = 1)) # to test cross-module method scoping
        testdir = newtestdir()
        dn = joinpath(testdir, "MethDel", "src")
        mkpath(dn)
        open(joinpath(dn, "MethDel.jl"), "w") do io
            println(io, """
__precompile__(false)   # "clean" Base doesn't have :revisefoo
module MethDel
f(x) = 1
f(x::Int) = 2
g(x::Vector{T}, y::T) where T = 1
g(x::Array{T,N}, y::T) where N where T = 2
g(::Array, ::Any) = 3
h(x::Array{T}, y::T) where T = g(x, y)
k(::Int; badchoice=1) = badchoice
Base.revisefoo(x::Int) = 2
struct Private end
Base.revisefoo(::Private) = 3

dfltargs(x::Int8, y::Int=0, z::Float32=1.0f0) = x+y+z

hasmacro1(@nospecialize(x)) = x
hasmacro2(@nospecialize(x::Int)) = x
hasmacro3(@nospecialize(x::Int), y::Float64) = x

hasdestructure1(x, (count, name)) = name^count
hasdestructure2(x, (count, name)::Tuple{Int,Any}) = name^count

struct A end
struct B end

checkunion(a::Union{Nothing, A}) = 1

methgensym(::Vector{<:Integer}) = 1

mapf(fs, x) = (fs[1](x), mapf(Base.tail(fs), x)...)
mapf(::Tuple{}, x) = ()

for T in (Int, Float64, String)
    @eval mytypeof(x::\$T) = \$T
end

end
""")
        end
        sleep(mtimedelay)
        @eval using MethDel
        sleep(mtimedelay)
        @test MethDel.f(1.0) == 1
        @test MethDel.f(1) == 2
        @test MethDel.g(rand(3), 1.0) == 1
        @test MethDel.g(rand(3, 3), 1.0) == 2
        @test MethDel.g(Int[], 1.0) == 3
        @test MethDel.h(rand(3), 1.0) == 1
        @test MethDel.k(1) == 1
        @test MethDel.k(1; badchoice=2) == 2
        @test MethDel.hasmacro1(1) == 1
        @test MethDel.hasmacro2(1) == 1
        @test MethDel.hasmacro3(1, 0.0) == 1
        @test MethDel.hasdestructure1(0, (3, "hi")) == "hihihi"
        @test MethDel.hasdestructure2(0, (3, "hi")) == "hihihi"
        @test Base.revisefoo(1.0) == 1
        @test Base.revisefoo(1) == 2
        @test Base.revisefoo(MethDel.Private()) == 3
        @test MethDel.dfltargs(Int8(2)) == 3.0f0
        @test MethDel.dfltargs(Int8(2), 5) == 8.0f0
        @test MethDel.dfltargs(Int8(2), 5, -17.0f0) == -10.0f0
        @test MethDel.checkunion(nothing) == 1
        @test MethDel.methgensym([1]) == 1
        @test_throws MethodError MethDel.methgensym([1.0])
        @test MethDel.mapf((x->x+1, x->x+0.1), 3) == (4, 3.1)
        @test MethDel.mytypeof(1) === Int
        @test MethDel.mytypeof(1.0) === Float64
        @test MethDel.mytypeof("hi") === String
        open(joinpath(dn, "MethDel.jl"), "w") do io
            println(io, """
module MethDel
f(x) = 1
g(x::Array{T,N}, y::T) where N where T = 2
h(x::Array{T}, y::T) where T = g(x, y)
k(::Int; goodchoice=-1) = goodchoice
dfltargs(x::Int8, yz::Tuple{Int,Float32}=(0,1.0f0)) = x+yz[1]+yz[2]

struct A end
struct B end

checkunion(a::Union{Nothing, B}) = 2

methgensym(::Vector{<:Real}) = 1

mapf(fs::F, x) where F = (fs[1](x), mapf(Base.tail(fs), x)...)
mapf(::Tuple{}, x) = ()

for T in (Int, String)
    @eval mytypeof(x::\$T) = \$T
end

end
""")
        end
        yry()
        @test MethDel.f(1.0) == 1
        @test MethDel.f(1) == 1
        @test MethDel.g(rand(3), 1.0) == 2
        @test MethDel.g(rand(3, 3), 1.0) == 2
        @test_throws MethodError MethDel.g(Int[], 1.0)
        @test MethDel.h(rand(3), 1.0) == 2
        @test_throws MethodError MethDel.k(1; badchoice=2)
        @test MethDel.k(1) == -1
        @test MethDel.k(1; goodchoice=10) == 10
        @test_throws MethodError MethDel.hasmacro1(1)
        @test_throws MethodError MethDel.hasmacro2(1)
        @test_throws MethodError MethDel.hasmacro3(1, 0.0)
        @test_throws MethodError MethDel.hasdestructure1(0, (3, "hi"))
        @test_throws MethodError MethDel.hasdestructure2(0, (3, "hi"))
        @test Base.revisefoo(1.0) == 1
        @test_throws MethodError Base.revisefoo(1)
        @test_throws MethodError Base.revisefoo(MethDel.Private())
        @test MethDel.dfltargs(Int8(2)) == 3.0f0
        @test MethDel.dfltargs(Int8(2), (5,-17.0f0)) == -10.0f0
        @test_throws MethodError MethDel.dfltargs(Int8(2), 5) == 8.0f0
        @test_throws MethodError MethDel.dfltargs(Int8(2), 5, -17.0f0) == -10.0f0
        @test MethDel.checkunion(nothing) == 2
        @test MethDel.methgensym([1]) == 1
        @test MethDel.methgensym([1.0]) == 1
        @test length(methods(MethDel.methgensym)) == 1
        @test MethDel.mapf((x->x+1, x->x+0.1), 3) == (4, 3.1)
        @test length(methods(MethDel.mapf)) == 2
        @test MethDel.mytypeof(1) === Int
        @test_throws MethodError MethDel.mytypeof(1.0)
        @test MethDel.mytypeof("hi") === String

        Base.delete_method(first(methods(Base.revisefoo)))

        # Test for specificity in deletion
        ex1 = :(methspecificity(x::Int) = 1)
        ex2 = :(methspecificity(x::Integer) = 2)
        Core.eval(ReviseTestPrivate, ex1)
        Core.eval(ReviseTestPrivate, ex2)
        exsig1 = Revise.RelocatableExpr(ex1)=>[Tuple{typeof(ReviseTestPrivate.methspecificity),Int}]
        exsig2 = Revise.RelocatableExpr(ex2)=>[Tuple{typeof(ReviseTestPrivate.methspecificity),Integer}]
        f_old, f_new = Revise.ExprsSigs(exsig1, exsig2), Revise.ExprsSigs(exsig2)
        Revise.delete_missing!(f_old, f_new)
        m = @which ReviseTestPrivate.methspecificity(1)
        @test m.sig.parameters[2] === Integer
        Revise.delete_missing!(f_old, f_new)
        m = @which ReviseTestPrivate.methspecificity(1)
        @test m.sig.parameters[2] === Integer
    end

    @testset "Evaled toplevel" begin
        testdir = newtestdir()
        dnA = joinpath(testdir, "ToplevelA", "src"); mkpath(dnA)
        dnB = joinpath(testdir, "ToplevelB", "src"); mkpath(dnB)
        dnC = joinpath(testdir, "ToplevelC", "src"); mkpath(dnC)
        open(joinpath(dnA, "ToplevelA.jl"), "w") do io
            println(io, """
            module ToplevelA
            @eval using ToplevelB
            g() = 2
            end""")
        end
        open(joinpath(dnB, "ToplevelB.jl"), "w") do io
            println(io, """
            module ToplevelB
            using ToplevelC
            end""")
        end
        open(joinpath(dnC, "ToplevelC.jl"), "w") do io
            println(io, """
            module ToplevelC
            export f
            f() = 1
            end""")
        end
        sleep(mtimedelay)
        using ToplevelA
        sleep(mtimedelay)
        @test ToplevelA.ToplevelB.f() == 1
        @test ToplevelA.g() == 2
        open(joinpath(dnA, "ToplevelA.jl"), "w") do io
            println(io, """
            module ToplevelA
            @eval using ToplevelB
            g() = 3
            end""")
        end
        yry()
        @test ToplevelA.ToplevelB.f() == 1
        @test ToplevelA.g() == 3

        rm_precompile("ToplevelA")
        rm_precompile("ToplevelB")
        rm_precompile("ToplevelC")
    end

    @testset "Revision errors" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "RevisionErrors", "src")
        mkpath(dn)
        fn = joinpath(dn, "RevisionErrors.jl")
        open(fn, "w") do io
            println(io, """
            module RevisionErrors
            f(x) = 1
            end
            """)
        end
        sleep(mtimedelay)
        @eval using RevisionErrors
        sleep(mtimedelay)
        @test RevisionErrors.f(0) == 1
        open(fn, "w") do io
            println(io, """
            module RevisionErrors
            f{x) = 2
            end
            """)
        end
        logs, _ = Test.collect_test_logs() do
            yry()
        end
        rec = logs[1]
        @test rec.message == "Failed to revise $fn"
        exc, bt = rec.kwargs[:exception]
        @test exc isa LoadError
        @test exc.file == fn
        @test exc.line == 2
        @test occursin("missing comma or }", exc.error)
        st = stacktrace(bt)
        @test length(st) == 1

        logs, _ = Test.collect_test_logs() do
            yry()
        end
        rec = logs[1]
        @test startswith(rec.message, "Due to a previously reported error")
        @test occursin("RevisionErrors.jl", rec.message)

        open(joinpath(dn, "RevisionErrors.jl"), "w") do io
            println(io, """
            module RevisionErrors
            f(x) = 2
            end
            """)
        end
        logs, _ = Test.collect_test_logs() do
            yry()
        end
        @test isempty(logs)
        @test RevisionErrors.f(0) == 2

        # Also test that it ends up being reported to the user (issue #281)
        open(joinpath(dn, "RevisionErrors.jl"), "w") do io
            println(io, """
            module RevisionErrors
            f(x) = 2
            foo(::Vector{T}) = 3
            end
            """)
        end
        logfile = joinpath(tempdir(), randtmp()*".log")
        open(logfile, "w") do io
            redirect_stderr(io) do
                yry()
            end
        end
        str = read(logfile, String)
        @test occursin("T not defined", str)

        rm_precompile("RevisionErrors")

        testfile = joinpath(testdir, "Test301.jl")
        open(testfile, "w") do io
            print(io, """
            module Test301
            mutable struct Struct301
                x::Int
                unset

                Struct301(x::Integer) = new(x)
            end
            f(s) = s.unset
            const s = Struct301(1)
            if f(s)
                g() = 1
            else
                g() = 2
            end
            end
            """)
        end
        logs, _ = Test.collect_test_logs() do
            includet(testfile)
        end
        @test occursin("Test301.jl:10", logs[1].message)

        logs, _ = Test.collect_test_logs() do
            Revise.track("callee_error.jl"; define=true)
        end
        @test length(logs) == 2
        @test occursin("(compiled mode) evaluation error", logs[1].message)
        @test occursin("callee_error.jl:12", logs[1].message)
        exc = logs[1].kwargs[:exception]
        @test exc[1] isa BoundsError
        @test length(stacktrace(exc[2])) <= 5
        @test occursin("evaluation error", logs[2].message)
        @test occursin("callee_error.jl:13", logs[2].message)
        exc = logs[2].kwargs[:exception]
        @test exc[1] isa BoundsError
        @test length(stacktrace(exc[2])) <= 5
        m = @which CalleeError.foo(3.2f0)
        @test whereis(m)[2] == 15
    end

    @testset "get_def" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "GetDef", "src")
        mkpath(dn)
        open(joinpath(dn, "GetDef.jl"), "w") do io
            println(io, """
            module GetDef

            f(x) = 1
            f(v::AbstractVector) = 2
            f(v::AbstractVector{<:Integer}) = 3

            foo(x::T, y::Integer=1; kw1="hello", kwargs...) where T<:Number = error("stop")
            bar(x) = foo(x; kw1="world")

            end
            """)
        end
        sleep(mtimedelay)
        @eval using GetDef
        sleep(mtimedelay)
        @test GetDef.f(1.0) == 1
        @test GetDef.f([1.0]) == 2
        @test GetDef.f([1]) == 3
        m = @which GetDef.f([1])
        ex = Revise.RelocatableExpr(definition(m))
        @test ex isa Revise.RelocatableExpr
        @test isequal(ex, Revise.RelocatableExpr(:(f(v::AbstractVector{<:Integer}) = 3)))

        st = try GetDef.bar(5.0) catch err stacktrace(catch_backtrace()) end
        m = st[2].linfo.def
        def = Revise.RelocatableExpr(definition(m))
        @test def == Revise.RelocatableExpr(:(foo(x::T, y::Integer=1; kw1="hello", kwargs...) where T<:Number = error("stop")))

        rm_precompile("GetDef")

        # This method identifies itself as originating from @irrational, defined in Base, but
        # the module of the method is listed as Base.MathConstants.
        m = @which Float32(π)
        @test definition(m) isa Expr
    end

    @testset "Pkg exclusion" begin
        push!(Revise.dont_watch_pkgs, :Example)
        push!(Revise.silence_pkgs, :Example)
        @eval import Example
        id = Base.PkgId(Example)
        @test !haskey(Revise.pkgdatas, id)
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
        pop!(LOAD_PATH)
    end

    @testset "Manual track" begin
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        open(srcfile, "w") do io
            print(io, """
            revise_f(x) = 1
            """)
        end
        sleep(mtimedelay)
        includet(srcfile)
        sleep(mtimedelay)
        @test revise_f(10) == 1
        @test length(signatures_at(srcfile, 1)) == 1
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
        srcfile = randtmp()*".jl"
        open(srcfile, "w") do io
            print(io, """
            revise_floc(x) = 1
            """)
        end
        sleep(mtimedelay)
        include(joinpath(pwd(), srcfile))
        @test revise_floc(10) == 1
        Revise.track(srcfile)
        sleep(mtimedelay)
        open(srcfile, "w") do io
            print(io, """
            revise_floc(x) = 2
            """)
        end
        yry()
        @test revise_floc(10) == 2
        push!(to_remove, joinpath(tempdir(), srcfile))
        cd(curdir)

        # Empty files (issue #253)
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        open(srcfile, "w") do io
            println(io)
        end
        sleep(mtimedelay)
        includet(srcfile)
        sleep(mtimedelay)
        @test basename(srcfile) ∈ Revise.watched_files[dirname(srcfile)]
        push!(to_remove, srcfile)

        # Double-execution (issue #263)
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        open(srcfile, "w") do io
            print(io, """
            println("executed")
            """)
        end
        sleep(mtimedelay)
        logfile = joinpath(tempdir(), randtmp()*".log")
        open(logfile, "w") do io
            redirect_stdout(io) do
                includet(srcfile)
            end
        end
        sleep(mtimedelay)
        lines = readlines(logfile)
        @test length(lines) == 1 && chomp(lines[1]) == "executed"
        open(srcfile, "w") do io
            print(io, """
            println("executed again")
            """)
        end
        open(logfile, "w") do io
            redirect_stdout(io) do
                yry()
            end
        end
        lines = readlines(logfile)
        @test length(lines) == 1 && chomp(lines[1]) == "executed again"

        # tls path (issue #264)
        srcdir = joinpath(tempdir(), randtmp())
        mkpath(srcdir)
        push!(to_remove, srcdir)
        srcfile1 = joinpath(srcdir, randtmp()*".jl")
        srcfile2 = joinpath(srcdir, randtmp()*".jl")
        open(srcfile1, "w") do io
            print(io, """
                includet(\"$(basename(srcfile2))\")
                """)
        end
        open(srcfile2, "w") do io
            print(io, """
                f264() = 1
                """)
        end
        sleep(mtimedelay)
        include(srcfile1)
        sleep(mtimedelay)
        @test f264() == 1
        open(srcfile2, "w") do io
            print(io, """
                f264() = 2
                """)
        end
        yry()
        @test f264() == 2

        # recursive `includet`s (issue #302)
        testdir = newtestdir()
        srcfile1 = joinpath(testdir, "Test302.jl")
        open(srcfile1, "w") do io
            print(io, """
            module Test302
            struct Parameters{T}
                control::T
            end
            function Parameters(control = nothing; kw...)
                Parameters(control)
            end
            function (p::Parameters)(; kw...)
                p
            end
            end
            """)
        end
        srcfile2 = joinpath(testdir, "test2.jl")
        open(srcfile2, "w") do io
            print(io, """
            includet(joinpath(@__DIR__, "Test302.jl"))
            using .Test302
            """)
        end
        sleep(mtimedelay)
        includet(srcfile2)
        sleep(mtimedelay)
        p = Test302.Parameters{Int}(3)
        @test p() == p
        open(srcfile1, "w") do io
            print(io, """
            module Test302
            struct Parameters{T}
                control::T
            end
            function Parameters(control = nothing; kw...)
                Parameters(control)
            end
            function (p::Parameters)(; kw...)
                0
            end
            end
            """)
        end
        yry()
        @test p() == 0

        # Non-included dependency (issue #316)
        testdir = newtestdir()
        dn = joinpath(testdir, "LikePlots", "src"); mkpath(dn)
        open(joinpath(dn, "LikePlots.jl"), "w") do io
            println(io, """
            module LikePlots
            plot() = 0
            backend() = include(joinpath(@__DIR__, "backends/backend.jl"))
            end
            """)
        end
        sd = joinpath(dn, "backends"); mkpath(sd)
        open(joinpath(sd, "backend.jl"), "w") do io
            println(io, """
            f() = 1
            """)
        end
        sleep(mtimedelay)
        @eval using LikePlots
        @test LikePlots.plot() == 0
        @test_throws UndefVarError LikePlots.f()
        sleep(mtimedelay)
        Revise.track(LikePlots, joinpath(sd, "backend.jl"))
        LikePlots.backend()
        @test LikePlots.f() == 1
        sleep(2*mtimedelay)
        open(joinpath(sd, "backend.jl"), "w") do io
            println(io, """
            f() = 2
            """)
        end
        yry()
        @test LikePlots.f() == 2
        @test joinpath("src", "backends", "backend.jl") ∈ Revise.srcfiles(Revise.pkgdatas[Base.PkgId(LikePlots)])

        rm_precompile("LikePlots")
    end

    @testset "Auto-track user scripts" begin
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        push!(to_remove, srcfile)
        open(srcfile, "w") do io
            println(io, "revise_g() = 1")
        end
        sleep(mtimedelay)
        # By default user scripts are not tracked
        # issue #358: but if the user is tracking all includes...
        user_track_includes = Revise.tracking_Main_includes[]
        Revise.tracking_Main_includes[] = false
        include(srcfile)
        yry()
        @test revise_g() == 1
        open(srcfile, "w") do io
            println(io, "revise_g() = 2")
        end
        yry()
        @test revise_g() == 1
        # Turn on tracking of user scripts
        empty!(Revise.included_files)  # don't track files already loaded (like this one)
        Revise.tracking_Main_includes[] = true
        try
            srcfile = joinpath(tempdir(), randtmp()*".jl")
            push!(to_remove, srcfile)
            open(srcfile, "w") do io
                println(io, "revise_g() = 1")
            end
            sleep(mtimedelay)
            include(srcfile)
            yry()
            @test revise_g() == 1
            open(srcfile, "w") do io
                println(io, "revise_g() = 2")
            end
            yry()
            @test revise_g() == 2

            # issue #257
            logs, _ = Test.collect_test_logs() do  # just to prevent noisy warning
                try include("nonexistent1.jl") catch end
                yry()
                try include("nonexistent2.jl") catch end
                yry()
            end
        finally
            Revise.tracking_Main_includes[] = user_track_includes  # restore old behavior
        end
    end

    @testset "Distributed" begin
        # The d31474 test below is from
        # https://discourse.julialang.org/t/how-do-i-make-revise-jl-work-in-multiple-workers-environment/31474
        newprocs = addprocs(2)
        newproc = newprocs[end]
        Revise.init_worker.(newprocs)
        allworkers = [myid(); newprocs]
        dirname = randtmp()
        mkdir(dirname)
        @everywhere push_LOAD_PATH!(dirname) = push!(LOAD_PATH, dirname)  # Don't want to share this LOAD_PATH
        for p in allworkers
            remotecall_wait(push_LOAD_PATH!, p, dirname)
        end
        push!(to_remove, dirname)
        modname = "ReviseDistributed"
        dn = joinpath(dirname, modname, "src")
        mkpath(dn)
        s31474 = """
        function d31474()
            r = @spawnat $newproc sqrt(4)
            fetch(r)
        end
        """
        open(joinpath(dn, modname*".jl"), "w") do io
            println(io, """
module ReviseDistributed
using Distributed

f() = π
g(::Int) = 0
$s31474

end
""")
        end
        sleep(mtimedelay)
        using ReviseDistributed
        sleep(mtimedelay)
        @everywhere using ReviseDistributed
        for p in allworkers
            @test remotecall_fetch(ReviseDistributed.f, p)    == π
            @test remotecall_fetch(ReviseDistributed.g, p, 1) == 0
        end
        @test ReviseDistributed.d31474() == 2.0
        s31474 = VERSION < v"1.3.0" ? s31474 : """
        function d31474()
            r = @spawnat $newproc sqrt(9)
            fetch(r)
        end
        """
        open(joinpath(dn, modname*".jl"), "w") do io
            println(io, """
module ReviseDistributed

f() = 3.0
$s31474

end
""")
        end
        yry()
        @test_throws MethodError ReviseDistributed.g(1)
        for p in allworkers
            @test remotecall_fetch(ReviseDistributed.f, p) == 3.0
            @test_throws RemoteException remotecall_fetch(ReviseDistributed.g, p, 1)
        end
        @test ReviseDistributed.d31474() == (VERSION < v"1.3.0" ? 2.0 : 3.0)
        rmprocs(allworkers[2:3]...; waitfor=10)
        rm_precompile("ReviseDistributed")
        pop!(LOAD_PATH)
    end

    @testset "Git" begin
        # if haskey(ENV, "CI")   # if we're doing CI testing (Travis, Appveyor, etc.)
        #     # First do a full git checkout of a package (we'll use Revise itself)
        #     @warn "checking out a development copy of Revise for testing purposes"
        #     pkg = Pkg.develop("Revise")
        # end
        loc = Base.find_package("Revise")
        if occursin("dev", loc)
            repo, path = Revise.git_repo(loc)
            @test repo != nothing
            files = Revise.git_files(repo)
            @test "README.md" ∈ files
            src = Revise.git_source(loc, "946d588328c2eb5fe5a56a21b4395379e41092e0")
            @test startswith(src, "__precompile__")
            src = Revise.git_source(loc, "eae5e000097000472280e6183973a665c4243b94") # 2nd commit in Revise's history
            @test src == "module Revise\n\n# package code goes here\n\nend # module\n"
        else
            @warn "skipping git tests because Revise is not under development"
        end
        # Issue #135
        if !Sys.iswindows()
            randdir = randtmp()
            modname = "ModuleWithNewFile"
            push!(to_remove, randdir)
            push!(LOAD_PATH, randdir)
            randdir = joinpath(randdir, modname)
            mkpath(joinpath(randdir, "src"))
            mainjl = joinpath(randdir, "src", modname*".jl")
            LibGit2.with(LibGit2.init(randdir)) do repo
                open(mainjl, "w") do io
                    println(io, """
                    module $modname
                    end
                    """)
                end
                LibGit2.add!(repo, joinpath("src", modname*".jl"))
                test_sig = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time(); digits=0), 0)
                LibGit2.commit(repo, "New file test"; author=test_sig, committer=test_sig)
            end
            sleep(mtimedelay)
            @eval using $(Symbol(modname))
            sleep(mtimedelay)
            mod = @eval $(Symbol(modname))
            id = Base.PkgId(mod)
            # id = Base.PkgId(Main)
            extrajl = joinpath(randdir, "src", "extra.jl")
            open(extrajl, "w") do io
                println(io, """
                println("extra")
                """)
            end
            open(mainjl, "w") do io
                println(io, """
                module $modname
                include("extra.jl")
                end
                """)
            end
            sleep(mtimedelay)
            repo = LibGit2.GitRepo(randdir)
            LibGit2.add!(repo, joinpath("src", "extra.jl"))
            logs, _ = Test.collect_test_logs() do
                Revise.track_subdir_from_git(id, joinpath(randdir, "src"); commit="HEAD")
            end
            yry()
            @test Revise.hasfile(Revise.pkgdatas[id], mainjl)
            @test startswith(logs[end].message, "skipping src/extra.jl") || startswith(logs[end-1].message, "skipping src/extra.jl")
            rm_precompile("ModuleWithNewFile")
            pop!(LOAD_PATH)
        end
    end

    @testset "Recipes" begin
        # https://github.com/JunoLab/Juno.jl/issues/257#issuecomment-473856452
        meth = @which gcd(10, 20)
        sigs = signatures_at(Base.find_source_file(String(meth.file)), meth.line)  # this should track Base

        # Tracking Base
        # issue #250
        @test_throws ErrorException("use Revise.track(Base) or Revise.track(<stdlib module>)") Revise.track(joinpath(Revise.juliadir, "base", "intfuncs.jl"))

        id = Base.PkgId(Base)
        pkgdata = Revise.pkgdatas[id]
        @test any(k->endswith(k, "number.jl"), Revise.srcfiles(pkgdata))
        @test length(filter(k->endswith(k, "file.jl"), Revise.srcfiles(pkgdata))) == 1
        m = @which show([1,2,3])
        @test definition(m) isa Expr
        m = @which redirect_stdout()
        @test definition(m).head == :function

        # Tracking stdlibs
        Revise.track(Unicode)
        id = Base.PkgId(Unicode)
        pkgdata = Revise.pkgdatas[id]
        @test any(k->endswith(k, "Unicode.jl"), Revise.srcfiles(pkgdata))
        m = first(methods(Unicode.isassigned))
        @test definition(m) isa Expr
        @test isfile(whereis(m)[1])

        # Submodule of Pkg (note that package is developed outside the
        # Julia repo, this tests new cases)
        id = Revise.get_tracked_id(Pkg.Types)
        pkgdata = Revise.pkgdatas[id]
        @test definition(first(methods(Pkg.API.add))) isa Expr

        # Test that we skip over files that don't end in ".jl"
        logs, _ = Test.collect_test_logs() do
            Revise.track(REPL)
        end
        @test isempty(logs)

        Revise.get_tracked_id(Core)   # just test that this doesn't error

        # Determine whether a git repo is available. Travis & Appveyor do not have this.
        repo, path = Revise.git_repo(Revise.juliadir)
        if repo != nothing
            # Tracking Core.Compiler
            Revise.track(Core.Compiler)
            id = Base.PkgId(Core.Compiler)
            pkgdata = Revise.pkgdatas[id]
            @test any(k->endswith(k, "optimize.jl"), Revise.srcfiles(pkgdata))
            m = first(methods(Core.Compiler.typeinf_code))
            @test definition(m) isa Expr
        else
            @test_throws Revise.GitRepoException Revise.track(Core.Compiler)
            @warn "skipping Core.Compiler tests due to lack of git repo"
        end
    end

    @testset "CodeTracking #48" begin
        m = @which sum([1]; dims=1)
        file, line = whereis(m)
        @test endswith(file, "reducedim.jl") && line > 1
    end

    @testset "Methods at REPL" begin
        if isdefined(Base, :active_repl)
            hp = Base.active_repl.interface.modes[1].hist
            fstr = "__fREPL__(x::Int16) = 0"
            histidx = length(hp.history) + 1 - hp.start_idx
            ex = Base.parse_input_line(fstr; filename="REPL[$histidx]")
            f = Core.eval(Main, ex)
            if ex.head == :toplevel
                ex = ex.args[end]
            end
            push!(hp.history, fstr)
            m = first(methods(f))
            @test !isempty(signatures_at(String(m.file), m.line))
            @test isequal(Revise.RelocatableExpr(definition(m)), Revise.RelocatableExpr(ex))
            @test definition(String, m)[1] == fstr

            # Test that revisions work (https://github.com/timholy/CodeTracking.jl/issues/38)
            fstr = "__fREPL__(x::Int16) = 1"
            histidx = length(hp.history) + 1 - hp.start_idx
            ex = Base.parse_input_line(fstr; filename="REPL[$histidx]")
            f = Core.eval(Main, ex)
            if ex.head == :toplevel
                ex = ex.args[end]
            end
            push!(hp.history, fstr)
            m = first(methods(f))
            @test isequal(Revise.RelocatableExpr(definition(m)), Revise.RelocatableExpr(ex))
            @test definition(String, m)[1] == fstr
            @test !isempty(signatures_at(String(m.file), m.line))

            pop!(hp.history)
            pop!(hp.history)
        end
    end
end

@testset "Switching free/dev" begin
    function make_a2d(path, val, mode="r"; generate=true)
        # Create a new "read-only package" (which mimics how Pkg works when you `add` a package)
        cd(path) do
            pkgpath = joinpath(path, "A2D")
            srcpath = joinpath(pkgpath, "src")
            if generate
                Pkg.generate("A2D")
            else
                mkpath(srcpath)
            end
            filepath = joinpath(srcpath, "A2D.jl")
            open(filepath, "w") do io
                println(io, """
                        module A2D
                        f() = $val
                        end
                        """)
            end
            chmod(filepath, mode=="r" ? 0o100444 : 0o100644)
            return pkgpath
        end
    end
    # Create a new package depot
    depot = mktempdir()
    old_depots = copy(DEPOT_PATH)
    empty!(DEPOT_PATH)
    push!(DEPOT_PATH, depot)
    # Skip cloning the General registry since that is slow and unnecessary
    registries = Pkg.Types.DEFAULT_REGISTRIES
    old_registries = copy(registries)
    empty!(registries)
    # Ensure we start fresh with no dependencies
    old_project = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)", "Project.toml")
    mkpath(dirname(Base.ACTIVE_PROJECT[]))
    open(Base.ACTIVE_PROJECT[], "w") do io
        println(io, "[deps]")
    end
    ropkgpath = make_a2d(depot, 1)
    Pkg.REPLMode.do_cmd(Pkg.REPLMode.minirepl[], "dev $ropkgpath"; do_rethrow=true)  # like pkg> dev $pkgpath; unfortunately, Pkg.develop(pkgpath) doesn't work
    sleep(mtimedelay)
    @eval using A2D
    sleep(mtimedelay)
    @test Base.invokelatest(A2D.f) == 1
    for dir in keys(Revise.watched_files)
        @test !startswith(dir, ropkgpath)
    end
    devpath = joinpath(depot, "dev")
    mkpath(devpath)
    mfile = Revise.manifest_file()
    schedule(Task(Revise.Rescheduler(Revise.watch_manifest, (mfile,))))
    sleep(mtimedelay)
    pkgdevpath = make_a2d(devpath, 2, "w"; generate=false)
    cp(joinpath(ropkgpath, "Project.toml"), joinpath(devpath, "A2D/Project.toml"))
    Pkg.REPLMode.do_cmd(Pkg.REPLMode.minirepl[], "dev $pkgdevpath"; do_rethrow=true)
    yry()
    @test Base.invokelatest(A2D.f) == 2
    Pkg.REPLMode.do_cmd(Pkg.REPLMode.minirepl[], "dev $ropkgpath"; do_rethrow=true)
    yry()
    @test Base.invokelatest(A2D.f) == 1
    for dir in keys(Revise.watched_files)
        @test !startswith(dir, ropkgpath)
    end

    # Restore internal Pkg data
    empty!(DEPOT_PATH)
    append!(DEPOT_PATH, old_depots)
    for pr in old_registries
        push!(registries, pr)
    end
    Base.ACTIVE_PROJECT[] = old_project

    push!(to_remove, depot)
end

@testset "Broken dependencies (issue #371)" begin
    testdir = newtestdir()
    srcdir = joinpath(testdir, "DepPkg371", "src")
    filepath = joinpath(srcdir, "DepPkg371.jl")
    cd(testdir) do
        Pkg.generate("DepPkg371")
        open(filepath, "w") do io
            println(io, """
            module DepPkg371
            using OrderedCollections   # undeclared dependency
            greet() = "Hello world!"
            end
            """)
        end
    end
    sleep(mtimedelay)
    @info "A warning about not having OrderedCollection in dependencies is expected"
    @eval using DepPkg371
    @test DepPkg371.greet() == "Hello world!"
    sleep(mtimedelay)
    open(filepath, "w") do io
        println(io, """
        module DepPkg371
        using OrderedCollections   # undeclared dependency
        greet() = "Hello again!"
        end
        """)
    end
    yry()
    @test DepPkg371.greet() == "Hello again!"

    rm_precompile("DepPkg371")
    pop!(LOAD_PATH)
end

@testset "Non-jl include_dependency (issue #388)" begin
    push!(LOAD_PATH, joinpath(@__DIR__, "pkgs"))
    @eval using ExcludeFile
    sleep(0.01)
    pkgdata = Revise.pkgdatas[Base.PkgId(UUID("b915cca1-7962-4ffb-a1c7-2bbdb2d9c14c"), "ExcludeFile")]
    files = Revise.srcfiles(pkgdata)
    @test length(files) == 2
    @test joinpath("src", "ExcludeFile.jl") ∈ files
    @test joinpath("src", "f.jl") ∈ files
    @test joinpath("deps", "dependency.txt") ∉ files
end

@testset "New files & Requires.jl" begin
    # Issue #107
    testdir = newtestdir()
    dn = joinpath(testdir, "NewFile", "src")
    mkpath(dn)
    open(joinpath(dn, "NewFile.jl"), "w") do io
        println(io, """
            module NewFile
            f() = 1
            end
            """)
    end
    sleep(mtimedelay)
    @eval using NewFile
    @test NewFile.f() == 1
    @test_throws UndefVarError NewFile.g()
    sleep(mtimedelay)
    open(joinpath(dn, "g.jl"), "w") do io
        println(io, "g() = 2")
    end
    open(joinpath(dn, "NewFile.jl"), "w") do io
        println(io, """
            module NewFile
            include("g.jl")
            f() = 1
            end
            """)
    end
    yry()
    @test NewFile.f() == 1
    @test NewFile.g() == 2

    dn = joinpath(testdir, "DeletedFile", "src")
    mkpath(dn)
    open(joinpath(dn, "DeletedFile.jl"), "w") do io
        println(io, """
            module DeletedFile
            include("g.jl")
            f() = 1
            end
            """)
    end
    open(joinpath(dn, "g.jl"), "w") do io
        println(io, "g() = 1")
    end
    sleep(mtimedelay)
    @eval using DeletedFile
    @test DeletedFile.f() == DeletedFile.g() == 1
    sleep(mtimedelay)
    open(joinpath(dn, "DeletedFile.jl"), "w") do io
        println(io, """
            module DeletedFile
            f() = 1
            end
            """)
    end
    rm(joinpath(dn, "g.jl"))
    yry()
    @test DeletedFile.f() == 1
    @test_throws MethodError DeletedFile.g()

    rm_precompile("NewFile")
    rm_precompile("DeletedFile")

    # https://discourse.julialang.org/t/revise-with-requires/19347
    dn = joinpath(testdir, "TrackRequires", "src")
    mkpath(dn)
    open(joinpath(dn, "TrackRequires.jl"), "w") do io
        println(io, """
        module TrackRequires
        using Requires
        function __init__()
            @require EndpointRanges="340492b5-2a47-5f55-813d-aca7ddf97656" begin
                export testfunc
                include("testfile.jl")
            end
        end
        end # module
        """)
    end
    open(joinpath(dn, "testfile.jl"), "w") do io
        println(io, "testfunc() = 1")
    end
    sleep(mtimedelay)
    @eval using TrackRequires
    notified = isdefined(TrackRequires.Requires, :withnotifications)
    notified || @warn "Requires does not support notifications"
    @test_throws UndefVarError TrackRequires.testfunc()
    @eval using EndpointRanges  # to trigger Requires
    sleep(mtimedelay)
    notified && @test TrackRequires.testfunc() == 1
    open(joinpath(dn, "testfile.jl"), "w") do io
        println(io, "testfunc() = 2")
    end
    yry()
    notified && @test TrackRequires.testfunc() == 2
    # Ensure it also works if the Requires dependency is pre-loaded
    dn = joinpath(testdir, "TrackRequires2", "src")
    mkpath(dn)
    open(joinpath(dn, "TrackRequires2.jl"), "w") do io
        println(io, """
        module TrackRequires2
        using Requires
        function __init__()
            @require EndpointRanges="340492b5-2a47-5f55-813d-aca7ddf97656" begin
                export testfunc
                include("testfile.jl")
            end
            @require MappedArrays="dbb5928d-eab1-5f90-85c2-b9b0edb7c900" begin
                export othertestfunc
                include("testfile2.jl")
            end
        end
        end # module
        """)
    end
    open(joinpath(dn, "testfile.jl"), "w") do io
        println(io, "testfunc() = 1")
    end
    open(joinpath(dn, "testfile2.jl"), "w") do io
        println(io, "othertestfunc() = -1")
    end
    sleep(mtimedelay)
    @eval using TrackRequires2
    sleep(mtimedelay)
    notified && @test TrackRequires2.testfunc() == 1
    @test_throws UndefVarError TrackRequires2.othertestfunc()
    open(joinpath(dn, "testfile.jl"), "w") do io
        println(io, "testfunc() = 2")
    end
    yry()
    notified && @test TrackRequires2.testfunc() == 2
    @test_throws UndefVarError TrackRequires2.othertestfunc()
    @eval using MappedArrays
    @test TrackRequires2.othertestfunc() == -1
    sleep(mtimedelay)
    open(joinpath(dn, "testfile2.jl"), "w") do io
        println(io, "othertestfunc() = -2")
    end
    yry()
    notified && @test TrackRequires2.othertestfunc() == -2

    rm_precompile("TrackRequires")
    rm_precompile("TrackRequires2")
    pop!(LOAD_PATH)
end

@testset "entr" begin
    if !Sys.isapple()   # these tests are very flaky on OSX
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        push!(to_remove, srcfile)
        open(srcfile, "w") do io
            println(io, "Core.eval(Main, :(__entr__ = 1))")
        end
        sleep(mtimedelay)
        try
            @sync begin
                @async begin
                    entr([srcfile]) do
                        include(srcfile)
                    end
                end
                sleep(mtimedelay)
                touch(srcfile)
                sleep(mtimedelay)
                @test Main.__entr__ == 1
                open(srcfile, "w") do io
                    println(io, "Core.eval(Main, :(__entr__ = 2))")
                end
                sleep(mtimedelay)
                @test Main.__entr__ == 2
                open(srcfile, "w") do io
                    println(io, "error(\"stop\")")
                end
                sleep(mtimedelay)
            end
            @test false
        catch err
            while err isa CompositeException
                err = err.exceptions[1]
                @static if VERSION >= v"1.3.0-alpha.110"
                    if  err isa TaskFailedException
                        err = err.task.exception
                    end
                end
                if err isa CapturedException
                    err = err.ex
                end
            end
            @test isa(err, LoadError)
            @test err.error.msg == "stop"
        end
    end
end

const A354_result = Ref(0)

# issue #354
@testset "entr with modules" begin

    testdir = newtestdir()
    modname = "A354"
    srcfile = joinpath(testdir, modname * ".jl")

    function setvalue(x)
        open(srcfile, "w") do io
            print(io, "module $modname test() = $x end")
        end
    end

    setvalue(1)

    # these sleeps may not be needed...
    sleep(mtimedelay)
    @eval using A354
    sleep(mtimedelay)

    A354_result[] = 0

    @async begin
        sleep(mtimedelay)
        setvalue(2)
        # belt and suspenders -- make sure we trigger entr:
        sleep(mtimedelay)
        touch(srcfile)
        sleep(mtimedelay)
    end

    try
        entr([], [A354], postpone=true) do
            A354_result[] = A354.test()
            error()
        end
    catch err
    end

    @test A354_result[] == 2

    rm_precompile(modname)

end

println("beginning cleanup")
GC.gc(); GC.gc()

@testset "Cleanup" begin
    logs, _ = Test.collect_test_logs() do
        warnfile = randtmp()
        open(warnfile, "w") do io
            redirect_stderr(io) do
                for name in to_remove
                    try
                        rm(name; force=true, recursive=true)
                        deleteat!(LOAD_PATH, findall(LOAD_PATH .== name))
                    catch
                    end
                end
                for i = 1:3
                    yry()
                    GC.gc()
                end
            end
        end
        @test occursin("is not an existing directory", read(warnfile, String))
        rm(warnfile)
    end
end

GC.gc(); GC.gc(); GC.gc()   # work-around for https://github.com/JuliaLang/julia/issues/28306

include("backedges.jl")

@testset "Base signatures" begin
    println("beginning signatures tests")
    # Using the extensive repository of code in Base as a testbed
    include("sigtest.jl")
end
