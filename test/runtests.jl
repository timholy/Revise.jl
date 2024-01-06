# REVISE: DO NOT PARSE   # For people with JULIA_REVISE_INCLUDE=1
using Revise
using Revise.CodeTracking
using Revise.JuliaInterpreter
using Test

@test isempty(detect_ambiguities(Revise))

using Pkg, Unicode, Distributed, InteractiveUtils, REPL, UUIDs
import LibGit2
using Revise.OrderedCollections: OrderedSet
using Test: collect_test_logs
using Base.CoreLogging: Debug,Info

using Revise.CodeTracking: line_is_decl

# In addition to using this for the "More arg-modifying macros" test below,
# this package is used on CI to test what happens when you have multiple
# *.ji files for the package.
using EponymTuples

include("common.jl")

throwing_function(bt) = bt[2]

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

macro empty_function(name)
    return esc(quote
        function $name end
    end)
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

# accommodate changes in Dict printing w/ Julia version
const pair_op_compact = let io = IOBuffer()
    print(IOContext(io, :compact=>true), Dict(1=>2))
    String(take!(io))[7:end-2]
end

const issue639report = []

@testset "Revise" begin
    do_test("PkgData") && @testset "PkgData" begin
        # Related to #358
        id = Base.PkgId(Main)
        pd = Revise.PkgData(id)
        @test isempty(Revise.basedir(pd))
    end

    do_test("Package contents") && @testset "Package contents" begin
        id = Base.PkgId(EponymTuples)
        path, mods_files_mtimes = Revise.pkg_fileinfo(id)
        @test occursin("EponymTuples", path)
    end

    do_test("LineSkipping") && @testset "LineSkipping" begin
        rex = Revise.RelocatableExpr(quote
                                    f(x) = x^2
                                    g(x) = sin(x)
                                    end)
        @test length(rex.ex.args) == 4  # including the line number expressions
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

    do_test("Equality and hashing") && @testset "Equality and hashing" begin
        # issue #233
        @test  isequal(Revise.RelocatableExpr(:(x = 1)), Revise.RelocatableExpr(:(x = 1)))
        @test !isequal(Revise.RelocatableExpr(:(x = 1)), Revise.RelocatableExpr(:(x = 1.0)))
        @test hash(Revise.RelocatableExpr(:(x = 1))) == hash(Revise.RelocatableExpr(:(x = 1)))
        @test hash(Revise.RelocatableExpr(:(x = 1))) != hash(Revise.RelocatableExpr(:(x = 1.0)))
        @test hash(Revise.RelocatableExpr(:(x = 1))) != hash(Revise.RelocatableExpr(:(x = 2)))
    end

    do_test("Parse errors") && @testset "Parse errors" begin
        md = Revise.ModuleExprsSigs(Main)
        errtype = Base.VERSION < v"1.10" ? LoadError : Base.Meta.ParseError
        @test_throws errtype Revise.parse_source!(md, """
            begin # this block should parse correctly, cf. issue #109

            end
            f(x) = 1
            g(x) = 2
            h{x) = 3  # error
            k(x) = 4
            """, "test", Main)

        # Issue #448
        testdir = newtestdir()
        file = joinpath(testdir, "badfile.jl")
        write(file, """
            function g()
                while t
                c =
                k
            end
            """)
        try
            includet(file)
        catch err
            @test isa(err, errtype)
            if  Base.VERSION < v"1.10"
                @test err.file == file
                @test endswith(err.error, "requires end")
            else
                @test occursin("Expected `end`", err.msg)
            end
        end
    end

    do_test("REPL input") && @testset "REPL input" begin
        # issue #573
        retex = Revise.revise_first(nothing)
        @test retex.head === :toplevel
        @test length(retex.args) == 2 && retex.args[end] === nothing
    end

    do_test("Signature extraction") && @testset "Signature extraction" begin
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

        # Method expressions with bad line number info
        ex = quote
            function nolineinfo(x)
                y = x^2 + 2x + 1
                @warn "oops"
                return y
            end
        end
        ex2 = ex.args[end].args[end]
        for (i, arg) in enumerate(ex2.args)
            if isa(arg, LineNumberNode)
                ex2.args[i] = LineNumberNode(0, :none)
            end
        end
        mexs = Revise.ModuleExprsSigs(ReviseTestPrivate)
        mexs[ReviseTestPrivate][Revise.RelocatableExpr(ex)] = nothing
        logs, _ = Test.collect_test_logs() do
            Revise.instantiate_sigs!(mexs; mode=:eval)
        end
        @test isempty(logs)
        @test isdefined(ReviseTestPrivate, :nolineinfo)
    end

    do_test("Comparison and line numbering") && @testset "Comparison and line numbering" begin
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
        @test isequal(Revise.unwrap(def), Revise.RelocatableExpr(:(square(x) = x^2)))
        @test val == [Tuple{typeof(ReviseTest.square),Any}]
        @test Revise.firstline(Revise.unwrap(def)).line == 5
        m = @which ReviseTest.square(1)
        @test m.line == 5
        @test whereis(m) == (tmpfile, 5)
        @test Revise.RelocatableExpr(definition(m)) == Revise.unwrap(def)
        (def, val) = dvs[2]
        @test isequal(Revise.unwrap(def), Revise.RelocatableExpr(:(cube(x) = x^3)))
        @test val == [Tuple{typeof(ReviseTest.cube),Any}]
        m = @which ReviseTest.cube(1)
        @test m.line == 7
        @test whereis(m) == (tmpfile, 7)
        @test Revise.RelocatableExpr(definition(m)) == Revise.unwrap(def)
        (def, val) = dvs[3]
        @test isequal(Revise.unwrap(def), Revise.RelocatableExpr(:(fourth(x) = x^4)))
        @test val == [Tuple{typeof(ReviseTest.fourth),Any}]
        m = @which ReviseTest.fourth(1)
        @test m.line == 9
        @test whereis(m) == (tmpfile, 9)
        @test Revise.RelocatableExpr(definition(m)) == Revise.unwrap(def)

        dvs = collect(mexsnew[ReviseTest.Internal])
        @test length(dvs) == 5
        (def, val) = dvs[1]
        @test isequal(Revise.unwrap(def),  Revise.RelocatableExpr(:(mult2(x) = 2*x)))
        @test val == [Tuple{typeof(ReviseTest.Internal.mult2),Any}]
        @test Revise.firstline(Revise.unwrap(def)).line == 13
        m = @which ReviseTest.Internal.mult2(1)
        @test m.line == 11
        @test whereis(m) == (tmpfile, 13)
        @test Revise.RelocatableExpr(definition(m)) == Revise.unwrap(def)
        (def, val) = dvs[2]
        @test isequal(Revise.unwrap(def), Revise.RelocatableExpr(:(mult3(x) = 3*x)))
        @test val == [Tuple{typeof(ReviseTest.Internal.mult3),Any}]
        m = @which ReviseTest.Internal.mult3(1)
        @test m.line == 14
        @test whereis(m) == (tmpfile, 14)
        @test Revise.RelocatableExpr(definition(m)) == Revise.unwrap(def)

        @test_throws MethodError ReviseTest.Internal.mult4(2)

        function cmpdiff(record, msg; kwargs...)
            record.message == msg
            for (kw, val) in kwargs
                logval = record.kwargs[kw]
                for (v, lv) in zip(val, logval)
                    isa(v, Expr) && (v = Revise.RelocatableExpr(v))
                    isa(lv, Expr) && (lv = Revise.RelocatableExpr(Revise.unwrap(lv)))
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
        io = PipeBuffer()
        foreach(rec -> show(io, rec), rlogger.logs)
        foreach(rec -> show(io, rec; verbose=false), rlogger.logs)
        @test count("Revise.LogRecord", read(io, String)) > 8
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
            @test bt.func === :cube && bt.file == Symbol(tmpfile) && bt.line == 7
        end
        try
            ReviseTest.Internal.mult2(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "mult2"
            bt = throwing_function(stacktrace(catch_backtrace()))
            @test bt.func === :mult2 && bt.file == Symbol(tmpfile) && bt.line == 13
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

        # coverage
        rex = convert(Revise.RelocatableExpr, :(a = 1))
        @test Revise.striplines!(rex) isa Revise.RelocatableExpr
        @test copy(rex) !== rex
    end

    do_test("Display") && @testset "Display" begin
        io = IOBuffer()
        show(io, Revise.RelocatableExpr(:(@inbounds x[2])))
        str = String(take!(io))
        @test str == ":(@inbounds x[2])"
        mod = private_module()
        file = joinpath(@__DIR__, "revisetest.jl")
        Base.include(mod, file)
        mexs = Revise.parse_source(file, mod)
        Revise.instantiate_sigs!(mexs)
        # io = IOBuffer()
        print(IOContext(io, :compact=>true), mexs)
        str = String(take!(io))
        @test str == "OrderedCollections.OrderedDict($mod$(pair_op_compact)ExprsSigs(<1 expressions>, <0 signatures>), $mod.ReviseTest$(pair_op_compact)ExprsSigs(<2 expressions>, <2 signatures>), $mod.ReviseTest.Internal$(pair_op_compact)ExprsSigs(<6 expressions>, <5 signatures>))"
        exs = mexs[getfield(mod, :ReviseTest)]
        # io = IOBuffer()
        print(IOContext(io, :compact=>true), exs)
        @test String(take!(io)) == "ExprsSigs(<2 expressions>, <2 signatures>)"
        print(IOContext(io, :compact=>false), exs)
        str = String(take!(io))
        @test str == "ExprsSigs with the following expressions: \n  :(square(x) = begin\n          x ^ 2\n      end)\n  :(cube(x) = begin\n          x ^ 4\n      end)"

        sleep(0.1)  # wait for EponymTuples to hit the cache
        pkgdata = Revise.pkgdatas[Base.PkgId(EponymTuples)]
        file = first(Revise.srcfiles(pkgdata))
        Revise.maybe_parse_from_cache!(pkgdata, file)
        print(io, pkgdata)
        str = String(take!(io))
        @test occursin("EponymTuples.jl\": FileInfo", str)
        @test occursin(r"with cachefile.*EponymTuples.*ji", str)
        print(IOContext(io, :compact=>true), pkgdata)
        str = String(take!(io))
        @test occursin("1/1 parsed files", str)
    end

    do_test("File paths") && @testset "File paths" begin
        testdir = newtestdir()
        for wf in (Revise.watching_files[] ? (true,) : (true, false))
            for (pcflag, fbase) in ((true, "pc"), (false, "npc"),)  # precompiled & not
                modname = uppercase(fbase) * (wf ? "WF" : "WD")
                fbase = fbase * (wf ? "wf" : "wd")
                pcexpr = pcflag ? "" : :(__precompile__(false))
                # Create a package with the following structure:
                #   src/PkgName.jl   # PC.jl = precompiled, NPC.jl = nonprecompiled
                #   src/file2.jl
                #   src/subdir/file3.jl
                #   src/subdir/file4.jl
                # exploring different ways of expressing the `include` statement
                dn = joinpath(testdir, modname, "src")
                mkpath(dn)
                write(joinpath(dn, modname*".jl"), """
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
                write(joinpath(dn, "file2.jl"), "$(fbase)2() = 2")
                mkdir(joinpath(dn, "subdir"))
                write(joinpath(dn, "subdir", "file3.jl"), "$(fbase)3() = 3")
                write(joinpath(dn, "subdir", "file4.jl"), "$(fbase)4() = 4")
                write(joinpath(dn, "file5.jl"), "$(fbase)5() = 5")

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
                @test rex == Revise.RelocatableExpr(:( $fn1() = 1 ))
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

                id = Base.PkgId(eval(Symbol(modname)))   # for testing #596
                pkgdata = Revise.pkgdatas[id]

                # Change the definition of function 1 (easiest to just rewrite the whole file)
                write(joinpath(dn, modname*".jl"), """
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
                yry()
                fi = pkgdata.fileinfos[1]
                @test fi.extracted[]          # issue 596
                @eval @test $(fn1)() == -1
                @eval @test $(fn2)() == 2
                @eval @test $(fn3)() == 3
                @eval @test $(fn4)() == 4
                @eval @test $(fn5)() == 5
                @eval @test $(fn6)() == 6      # because it hasn't been re-macroexpanded
                @test revise(eval(Symbol(modname)))
                @eval @test $(fn6)() == -6
                # Redefine function 2
                write(joinpath(dn, "file2.jl"), "$(fbase)2() = -2")
                yry()
                @eval @test $(fn1)() == -1
                @eval @test $(fn2)() == -2
                @eval @test $(fn3)() == 3
                @eval @test $(fn4)() == 4
                @eval @test $(fn5)() == 5
                @eval @test $(fn6)() == -6
                write(joinpath(dn, "subdir", "file3.jl"), "$(fbase)3() = -3")
                yry()
                @eval @test $(fn1)() == -1
                @eval @test $(fn2)() == -2
                @eval @test $(fn3)() == -3
                @eval @test $(fn4)() == 4
                @eval @test $(fn5)() == 5
                @eval @test $(fn6)() == -6
                write(joinpath(dn, "subdir", "file4.jl"), "$(fbase)4() = -4")
                yry()
                @eval @test $(fn1)() == -1
                @eval @test $(fn2)() == -2
                @eval @test $(fn3)() == -3
                @eval @test $(fn4)() == -4
                @eval @test $(fn5)() == 5
                @eval @test $(fn6)() == -6
                write(joinpath(dn, "file5.jl"), "$(fbase)5() = -5")
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
        end
        # Remove the precompiled file(s)
        rm_precompile("PCWF")
        Revise.watching_files[] || rm_precompile("PCWD")

        # Submodules (issue #142)
        srcdir = joinpath(testdir, "Mysupermodule", "src")
        subdir = joinpath(srcdir, "Mymodule")
        mkpath(subdir)
        write(joinpath(srcdir, "Mysupermodule.jl"), """
            module Mysupermodule
            include("Mymodule/Mymodule.jl")
            end
            """)
        write(joinpath(subdir, "Mymodule.jl"), """
            module Mymodule
            include("filesub.jl")
            end
            """)
        write(joinpath(subdir, "filesub.jl"), "func() = 1")
        sleep(mtimedelay)
        @eval using Mysupermodule
        sleep(mtimedelay)
        @test Mysupermodule.Mymodule.func() == 1
        write(joinpath(subdir, "filesub.jl"), "func() = 2")
        yry()
        @test Mysupermodule.Mymodule.func() == 2
        rm_precompile("Mymodule")
        rm_precompile("Mysupermodule")

        # Test files paths that can't be statically parsed
        dn = joinpath(testdir, "LoopInclude", "src")
        mkpath(dn)
        write(joinpath(dn, "LoopInclude.jl"), """
            module LoopInclude

            export li_f, li_g

            for fn in ("file1.jl", "file2.jl")
                include(fn)
            end

            end
            """)
        write(joinpath(dn, "file1.jl"), "li_f() = 1")
        write(joinpath(dn, "file2.jl"), "li_g() = 2")
        sleep(mtimedelay)
        @eval using LoopInclude
        sleep(mtimedelay)
        @test li_f() == 1
        @test li_g() == 2
        write(joinpath(dn, "file1.jl"), "li_f() = -1")
        yry()
        @test li_f() == -1
        rm_precompile("LoopInclude")

        # Multiple packages in the same directory (issue #228)
        write(joinpath(testdir, "A228.jl"), """
            module A228
            using B228
            export f228
            f228(x) = 3 * g228(x)
            end
            """)
        write(joinpath(testdir, "B228.jl"), """
            module B228
            export g228
            g228(x) = 4x + 2
            end
            """)
        sleep(mtimedelay)
        using A228
        sleep(mtimedelay)
        @test f228(3) == 42
        write(joinpath(testdir, "B228.jl"), """
            module B228
            export g228
            g228(x) = 4x + 1
            end
            """)
        yry()
        @test f228(3) == 39
        rm_precompile("A228")
        rm_precompile("B228")

        # uncoupled packages in the same directory (issue #339)
        write(joinpath(testdir, "A339.jl"), """
            module A339
            f() = 1
            end
            """)
        write(joinpath(testdir, "B339.jl"), """
            module B339
            f() = 1
            end
            """)
        sleep(mtimedelay)
        using A339, B339
        sleep(mtimedelay)
        @test A339.f() == 1
        @test B339.f() == 1
        sleep(mtimedelay)
        write(joinpath(testdir, "A339.jl"), """
                        module A339
                        f() = 2
                        end
                        """)
        yry()
        @test A339.f() == 2
        @test B339.f() == 1
        sleep(mtimedelay)
        write(joinpath(testdir, "B339.jl"), """
                        module B339
                        f() = 2
                        end
                        """)
        yry()
        @test A339.f() == 2
        @test B339.f() == 2
        rm_precompile("A339")
        rm_precompile("B339")

        # Combining `include` with empty functions (issue #758)
        write(joinpath(testdir, "Issue758.jl"), """
            module Issue758
            global gvar = true
            function f end
            include("Issue758helperfile.jl")
            end
            """)
        write(joinpath(testdir, "Issue758helperfile.jl"), "")
        sleep(mtimedelay)
        using Issue758
        sleep(mtimedelay)
        @test_throws MethodError Issue758.f()
        sleep(mtimedelay)
        write(joinpath(testdir, "Issue758.jl"), """
            module Issue758
            global gvar = true
            function f end
            f() = 1
            include("Issue758helperfile.jl")
            end
            """)
        yry()
        @test Issue758.f() == 1
        rm_precompile("Issue758")

        pop!(LOAD_PATH)
    end

    # issue #131
    do_test("Base & stdlib file paths") && @testset "Base & stdlib file paths" begin
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

    do_test("Namespace") && @testset "Namespace" begin
        # Issues #579, #239, and #627
        testdir = newtestdir()
        dn = joinpath(testdir, "Namespace", "src")
        mkpath(dn)
        write(joinpath(dn, "Namespace.jl"), """
            module Namespace
            struct X end
            cos(::X) = 20
            end
            """)
        sleep(mtimedelay)
        @eval using Namespace
        @test Namespace.cos(Namespace.X()) == 20
        @test_throws MethodError Base.cos(Namespace.X())
        sleep(mtimedelay)
        write(joinpath(dn, "Namespace.jl"), """
            module Namespace
            struct X end
            sin(::Int) = 10
            Base.cos(::X) = 20
            # From #627
            module Foos
                struct Foo end
            end
            using .Foos: Foo
            end
            """)
        yry()
        @test Namespace.sin(0) == 10
        @test Base.sin(0) == 0
        @test Base.cos(Namespace.X()) == 20
        @test_throws MethodError Namespace.cos(Namespace.X())

        rm_precompile("Namespace")
        pop!(LOAD_PATH)
    end

    do_test("Multiple definitions") && @testset "Multiple definitions" begin
        # This simulates a copy/paste/save "error" from one file to another
        # ref https://github.com/timholy/CodeTracking.jl/issues/55
        testdir = newtestdir()
        dn = joinpath(testdir, "Multidef", "src")
        mkpath(dn)
        write(joinpath(dn, "Multidef.jl"), """
            module Multidef
            include("utils.jl")
            end
            """)
        write(joinpath(dn, "utils.jl"), "repeated(x) = x+1")
        sleep(mtimedelay)
        @eval using Multidef
        @test Multidef.repeated(3) == 4
        sleep(mtimedelay)
        write(joinpath(dn, "Multidef.jl"), """
            module Multidef
            include("utils.jl")
            repeated(x) = x+1
            end
            """)
        yry()
        @test Multidef.repeated(3) == 4
        sleep(mtimedelay)
        write(joinpath(dn, "utils.jl"), "\n")
        yry()
        @test Multidef.repeated(3) == 4

        rm_precompile("Multidef")
        pop!(LOAD_PATH)
    end

    do_test("Recursive types (issue #417)") && @testset "Recursive types (issue #417)" begin
        testdir = newtestdir()
        fn = joinpath(testdir, "recursive.jl")
        write(fn, """
            module RecursiveTypes
            struct Foo
                x::Vector{Foo}

                Foo() = new(Foo[])
            end
            end
            """)
        sleep(mtimedelay)
        includet(fn)
        @test isa(RecursiveTypes.Foo().x, Vector{RecursiveTypes.Foo})

        pop!(LOAD_PATH)
    end

    # issue #318
    do_test("Cross-module extension") && @testset "Cross-module extension" begin
        testdir = newtestdir()
        dnA = joinpath(testdir, "CrossModA", "src")
        mkpath(dnA)
        write(joinpath(dnA, "CrossModA.jl"), """
            module CrossModA
            foo(x) = "default"
            end
            """)
        dnB = joinpath(testdir, "CrossModB", "src")
        mkpath(dnB)
        write(joinpath(dnB, "CrossModB.jl"), """
            module CrossModB
            import CrossModA
            CrossModA.foo(x::Int) = 1
            end
            """)
        sleep(mtimedelay)
        @eval using CrossModA, CrossModB
        @test CrossModA.foo("") == "default"
        @test CrossModA.foo(0) == 1
        sleep(mtimedelay)
        write(joinpath(dnB, "CrossModB.jl"), """
            module CrossModB
            import CrossModA
            CrossModA.foo(x::Int) = 2
            end
            """)
        yry()
        @test CrossModA.foo("") == "default"
        @test CrossModA.foo(0) == 2
        write(joinpath(dnB, "CrossModB.jl"), """
            module CrossModB
            import CrossModA
            CrossModA.foo(x::Int) = 3
            end
            """)
        yry()
        @test CrossModA.foo("") == "default"
        @test CrossModA.foo(0) == 3

        rm_precompile("CrossModA")
        rm_precompile("CrossModB")
        pop!(LOAD_PATH)
    end

    # issue #36
    do_test("@__FILE__") && @testset "@__FILE__" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "ModFILE", "src")
        mkpath(dn)
        write(joinpath(dn, "ModFILE.jl"), """
            module ModFILE

            mf() = @__FILE__, 1

            end
            """)
        sleep(mtimedelay)
        @eval using ModFILE
        sleep(mtimedelay)
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 1)
        write(joinpath(dn, "ModFILE.jl"), """
            module ModFILE

            mf() = @__FILE__, 2

            end
            """)
        yry()
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 2)
        rm_precompile("ModFILE")
        pop!(LOAD_PATH)
    end

    do_test("Revision order") && @testset "Revision order" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "Order1", "src")
        mkpath(dn)
        write(joinpath(dn, "Order1.jl"), """
            module Order1
            include("file1.jl")
            include("file2.jl")
            end
            """)
        write(joinpath(dn, "file1.jl"), "# a comment")
        write(joinpath(dn, "file2.jl"), "# a comment")
        sleep(mtimedelay)
        @eval using Order1
        sleep(mtimedelay)
        # we want Revise to process files the order file1.jl, file2.jl, but let's save them in the opposite order
        write(joinpath(dn, "file2.jl"), "f(::Ord1) = 1")
        sleep(mtimedelay)
        write(joinpath(dn, "file1.jl"), "struct Ord1 end")
        yry()
        @test Order1.f(Order1.Ord1()) == 1

        # A case in which order cannot be determined solely from file order
        dn = joinpath(testdir, "Order2", "src")
        mkpath(dn)
        write(joinpath(dn, "Order2.jl"), """
            module Order2
            include("file.jl")
            end
            """)
        write(joinpath(dn, "file.jl"), "# a comment")
        sleep(mtimedelay)
        @eval using Order2
        sleep(mtimedelay)
        write(joinpath(dn, "Order2.jl"), """
            module Order2
            include("file.jl")
            f(::Ord2) = 1
            end
            """)
        sleep(mtimedelay)
        write(joinpath(dn, "file.jl"), "struct Ord2 end")
        @info "The following error message is expected for this broken test"
        yry()
        @test_broken Order2.f(Order2.Ord2()) == 1
        # Resolve it with retry
        Revise.retry()
        @test Order2.f(Order2.Ord2()) == 1

        # Cross-module dependencies
        dn3 = joinpath(testdir, "Order3", "src")
        mkpath(dn3)
        write(joinpath(dn3, "Order3.jl"), """
            module Order3
            using Order2
            end
            """)
        sleep(mtimedelay)
        @eval using Order3
        sleep(mtimedelay)
        write(joinpath(dn3, "Order3.jl"), """
            module Order3
            using Order2
            g(::Order2.Ord2a) = 1
            end
            """)
        sleep(mtimedelay)
        write(joinpath(dn, "file.jl"), """
            struct Ord2 end
            struct Ord2a end
            """)
        yry()
        @test Order3.g(Order2.Ord2a()) == 1

        rm_precompile("Order1")
        rm_precompile("Order2")
        pop!(LOAD_PATH)
    end

    # issue #8 and #197
    do_test("Module docstring") && @testset "Module docstring" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "ModDocstring", "src")
        mkpath(dn)
        write(joinpath(dn, "ModDocstring.jl"), """
            " Ahoy! "
            module ModDocstring

            include("dependency.jl")

            f() = 1

            end
            """)
        write(joinpath(dn, "dependency.jl"), "")
        sleep(mtimedelay)
        @eval using ModDocstring
        sleep(mtimedelay)
        @test ModDocstring.f() == 1
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Ahoy! "

        write(joinpath(dn, "ModDocstring.jl"), """
            " Ahoy! "
            module ModDocstring

            include("dependency.jl")

            f() = 2

            end
            """)
        yry()
        @test ModDocstring.f() == 2
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Ahoy! "

        write(joinpath(dn, "ModDocstring.jl"), """
            " Hello! "
            module ModDocstring

            include("dependency.jl")

            f() = 3

            end
            """)
        yry()
        @test ModDocstring.f() == 3
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Hello! "
        rm_precompile("ModDocstring")

        # issue #197
        dn = joinpath(testdir, "ModDocstring2", "src")
        mkpath(dn)
        write(joinpath(dn, "ModDocstring2.jl"), """
            "docstring"
            module ModDocstring2
                "docstring for .Sub"
                module Sub
                end
            end
            """)
        sleep(mtimedelay)
        @eval using ModDocstring2
        sleep(mtimedelay)
        ds = @doc(ModDocstring2)
        @test get_docstring(ds) == "docstring"
        ds = @doc(ModDocstring2.Sub)
        @test get_docstring(ds) == "docstring for .Sub"
        write(joinpath(dn, "ModDocstring2.jl"), """
            "updated docstring"
            module ModDocstring2
                "updated docstring for .Sub"
                module Sub
                end
            end
            """)
        yry()
        ds = @doc(ModDocstring2)
        @test get_docstring(ds) == "updated docstring"
        ds = @doc(ModDocstring2.Sub)
        @test get_docstring(ds) == "updated docstring for .Sub"
        rm_precompile("ModDocstring2")

        pop!(LOAD_PATH)
    end

    do_test("Changing docstrings") && @testset "Changing docstring" begin
        # Compiled mode covers most docstring changes, so we have to go to
        # special effort to test the older interpreter-based solution.
        testdir = newtestdir()
        dn = joinpath(testdir, "ChangeDocstring", "src")
        mkpath(dn)
        write(joinpath(dn, "ChangeDocstring.jl"), """
            module ChangeDocstring
            "f" f() = 1
            g() = 1
            end
            """)
        sleep(mtimedelay)
        @eval using ChangeDocstring
        sleep(mtimedelay)
        @test ChangeDocstring.f() == 1
        ds = @doc(ChangeDocstring.f)
        @test get_docstring(ds) == "f"
        @test ChangeDocstring.g() == 1
        ds = @doc(ChangeDocstring.g)
        @test get_docstring(ds) == "No documentation found."
        # Ordinary route
        write(joinpath(dn, "ChangeDocstring.jl"), """
            module ChangeDocstring
            "h" f() = 1
            "g" g() = 1
            end
            """)
        yry()
        ds = @doc(ChangeDocstring.f)
        @test get_docstring(ds) == "h"
        ds = @doc(ChangeDocstring.g)
        @test get_docstring(ds) == "g"

        # Now manually change the docstring
        ex = quote "g" f() = 1 end
        lwr = Meta.lower(ChangeDocstring, ex)
        frame = Frame(ChangeDocstring, lwr.args[1])
        methodinfo = Revise.MethodInfo()
        docexprs = Revise.DocExprs()
        ret = Revise.methods_by_execution!(JuliaInterpreter.finish_and_return!, methodinfo,
                                           docexprs, frame, trues(length(frame.framecode.src.code)); mode=:sigs)
        ds = @doc(ChangeDocstring.f)
        @test get_docstring(ds) == "g"

        rm_precompile("ChangeDocstring")

        # Test for #583
        dn = joinpath(testdir, "FirstDocstring", "src")
        mkpath(dn)
        write(joinpath(dn, "FirstDocstring.jl"), """
            module FirstDocstring
            g() = 1
            end
            """)
        sleep(mtimedelay)
        @eval using FirstDocstring
        sleep(mtimedelay)
        @test FirstDocstring.g() == 1
        ds = @doc(FirstDocstring.g)
        @test get_docstring(ds) == "No documentation found."
        write(joinpath(dn, "FirstDocstring.jl"), """
            module FirstDocstring
            "g" g() = 1
            end
            """)
        yry()
        ds = @doc(FirstDocstring.g)
        @test get_docstring(ds) == "g"

        rm_precompile("FirstDocstring")
        pop!(LOAD_PATH)
    end

    do_test("doc expr signature") && @testset "Docstring attached to signatures" begin
        md = Revise.ModuleExprsSigs(Main)
        Revise.parse_source!(md, """
            module DocstringSigsOnly
            function f end
            "basecase" f(x)
            "basecase with type" f(x::Int)
            "basecase no varname" f(::Float64)
            "where" f(x::T) where T <: Int8
            "where no varname" f(::T) where T <: String
            end
            """, "test2", Main)
        # Simply test that the "bodies" of the doc exprs are not included as
        # standalone expressions.
        @test length(md[Main.DocstringSigsOnly]) == 6 # 1 func + 5 doc exprs
    end

    do_test("Undef in docstrings") && @testset "Undef in docstrings" begin
        fn = Base.find_source_file("abstractset.jl")   # has lots of examples of """str""" func1, func2
        mexsold = Revise.parse_source(fn, Base)
        mexsnew = Revise.parse_source(fn, Base)
        odict = mexsold[Base]
        ndict = mexsnew[Base]
        for (k, v) in odict
            @test haskey(ndict, k)
        end
    end

    do_test("Macro docstrings (issue #309)") && @testset "Macro docstrings (issue #309)" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "MacDocstring", "src")
        mkpath(dn)
        write(joinpath(dn, "MacDocstring.jl"), """
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
        sleep(mtimedelay)
        @eval using MacDocstring
        sleep(mtimedelay)
        @test MacDocstring.f() == 1
        ds = @doc(MacDocstring.c)
        @test strip(get_docstring(ds)) == "mydoc"

        write(joinpath(dn, "MacDocstring.jl"), """
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
        yry()
        @test MacDocstring.f() == 2
        ds = @doc(MacDocstring.c)
        @test strip(get_docstring(ds)) == "mydoc"

        rm_precompile("MacDocstring")
        pop!(LOAD_PATH)
    end

    # issue #165
    do_test("Changing @inline annotations") && @testset "Changing @inline annotations" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "PerfAnnotations", "src")
        mkpath(dn)
        write(joinpath(dn, "PerfAnnotations.jl"), """
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
        sleep(mtimedelay)
        @eval using PerfAnnotations
        sleep(mtimedelay)
        @test PerfAnnotations.check_hasinline(3) == 3
        @test PerfAnnotations.check_hasnoinline(3) == 3
        @test PerfAnnotations.check_notannot1(3) == 3
        @test PerfAnnotations.check_notannot2(3) == 3
        code = get_code(PerfAnnotations.check_hasinline, Tuple{Int})
        @test length(code) == 1 && isreturning_slot(code[1], 2)
        code = get_code(PerfAnnotations.check_hasnoinline, Tuple{Int})
        @test length(code) == 2 && code[1].head === :invoke
        code = get_code(PerfAnnotations.check_notannot1, Tuple{Int})
        @test length(code) == 1 && isreturning_slot(code[1], 2)
        code = get_code(PerfAnnotations.check_notannot2, Tuple{Int})
        @test length(code) == 1 && isreturning_slot(code[1], 2)
        write(joinpath(dn, "PerfAnnotations.jl"), """
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
        yry()
        @test PerfAnnotations.check_hasinline(3) == 3
        @test PerfAnnotations.check_hasnoinline(3) == 3
        @test PerfAnnotations.check_notannot1(3) == 3
        @test PerfAnnotations.check_notannot2(3) == 3
        code = get_code(PerfAnnotations.check_hasinline, Tuple{Int})
        @test length(code) == 1 && isreturning_slot(code[1], 2)
        code = get_code(PerfAnnotations.check_hasnoinline, Tuple{Int})
        @test length(code) == 1 && isreturning_slot(code[1], 2)
        code = get_code(PerfAnnotations.check_notannot1, Tuple{Int})
        @test length(code) == 1 && isreturning_slot(code[1], 2)
        code = get_code(PerfAnnotations.check_notannot2, Tuple{Int})
        @test length(code) == 2 && code[1].head === :invoke
        rm_precompile("PerfAnnotations")

        pop!(LOAD_PATH)
    end

    do_test("Revising macros") && @testset "Revising macros" begin
        # issue #174
        testdir = newtestdir()
        dn = joinpath(testdir, "MacroRevision", "src")
        mkpath(dn)
        write(joinpath(dn, "MacroRevision.jl"), """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 1
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        sleep(mtimedelay)
        @eval using MacroRevision
        sleep(mtimedelay)
        @test MacroRevision.foo("hello") == 1

        write(joinpath(dn, "MacroRevision.jl"), """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 2
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        yry()
        @test MacroRevision.foo("hello") == 1
        revise(MacroRevision)
        @test MacroRevision.foo("hello") == 2

        write(joinpath(dn, "MacroRevision.jl"), """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 3
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        yry()
        @test MacroRevision.foo("hello") == 2
        revise(MacroRevision)
        @test MacroRevision.foo("hello") == 3
        rm_precompile("MacroRevision")

        # issue #435
        dn = joinpath(testdir, "MacroSigs", "src")
        mkpath(dn)
        write(joinpath(dn, "MacroSigs.jl"), """
            module MacroSigs
            end
            """)
        sleep(mtimedelay)
        @eval using MacroSigs
        sleep(mtimedelay)
        write(joinpath(dn, "MacroSigs.jl"), """
            module MacroSigs
            macro testmac(fname)
                esc(quote
                    function some_fun end
                    \$fname() = 1
                    end)
            end

            @testmac blah
            end
            """)
        yry()
        @test MacroSigs.blah() == 1
        @test haskey(CodeTracking.method_info, (@which MacroSigs.blah()).sig)
        rm_precompile("MacroSigs")

        # Issue #568 (a macro *execution* bug)
        dn = joinpath(testdir, "MacroLineNos568", "src")
        mkpath(dn)
        write(joinpath(dn, "MacroLineNos568.jl"), """
            module MacroLineNos568
            using MacroTools: @q

            function my_fun end

            macro some_macro(value)
                return esc(@q \$MacroLineNos568.my_fun() = \$value)
            end

            @some_macro 20
            end
            """)
        sleep(mtimedelay)
        @eval using MacroLineNos568
        sleep(mtimedelay)
        @test MacroLineNos568.my_fun() == 20
        write(joinpath(dn, "MacroLineNos568.jl"), """
            module MacroLineNos568
            using MacroTools: @q

            function my_fun end

            macro some_macro(value)
                return esc(@q \$MacroLineNos568.my_fun() = \$value)
            end

            @some_macro 30
            end
            """)
        yry()
        @test MacroLineNos568.my_fun() == 30
        rm_precompile("MacroLineNos568")

        # Macros that create empty functions (another macro *execution* bug, issue #792)
        file = tempname()
        write(file, "@empty_function issue792f1\n")
        sleep(mtimedelay)
        includet(ReviseTestPrivate, file)
        sleep(mtimedelay)
        @test isempty(methods(ReviseTestPrivate.issue792f1))
        open(file, "a") do f
            println(f, "@empty_function issue792f2")
        end
        yry()
        @test isempty(methods(ReviseTestPrivate.issue792f2))
        rm(file)

        pop!(LOAD_PATH)
    end

    do_test("More arg-modifying macros") && @testset "More arg-modifying macros" begin
        # issue #183
        testdir = newtestdir()
        dn = joinpath(testdir, "ArgModMacros", "src")
        mkpath(dn)
        write(joinpath(dn, "ArgModMacros.jl"), """
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
        sleep(mtimedelay)
        @eval using ArgModMacros
        sleep(mtimedelay)
        @test ArgModMacros.hyper_loglikelihood((μ=1, σ=2, LΩ=3), (w̃s=4, α̃s=5, β̃s=6)) == [4,5,6]
        @test ArgModMacros.revision[] == 1
        write(joinpath(dn, "ArgModMacros.jl"), """
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
        yry()
        @test ArgModMacros.hyper_loglikelihood((μ=1, σ=2, LΩ=3), (w̃s=4, α̃s=5, β̃s=6)) == [4,5,6]
        @test ArgModMacros.revision[] == 2
        rm_precompile("ArgModMacros")
        pop!(LOAD_PATH)
    end

    do_test("Line numbers") && @testset "Line numbers" begin
        # issue #27
        testdir = newtestdir()
        modname = "LineNumberMod"
        dn = joinpath(testdir, modname, "src")
        mkpath(dn)
        write(joinpath(dn, modname*".jl"), "module $modname include(\"incl.jl\") end")
        write(joinpath(dn, "incl.jl"), """
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

            foo(x) = x+5

            foo(y::Int) = y-51
            """)
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
        write(joinpath(dn, "incl.jl"), """
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

            foo(x) = x+6

            foo(y::Int) = y-51
            """)
        yry()
        for m in methods(LineNumberMod.foo)
            @test endswith(string(m.file), "incl.jl")
            @test m.line ∈ lines
        end
        rm_precompile("LineNumberMod")
        pop!(LOAD_PATH)
    end

    do_test("Line numbers in backtraces and warnings") && @testset "Line numbers in backtraces and warnings" begin
        filename = randtmp() * ".jl"
        write(filename, """
            function triggered(iserr::Bool, iswarn::Bool)
                iserr && error("error")
                iswarn && @warn "Information"
                return nothing
            end
            """)
        sleep(mtimedelay)
        includet(filename)
        sleep(mtimedelay)
        try
            triggered(true, false)
            @test false
        catch err
            st = stacktrace(catch_backtrace())
            Revise.update_stacktrace_lineno!(st)
            bt = throwing_function(st)
            @test bt.file == Symbol(filename) && bt.line == 2
        end
        io = IOBuffer()
        if isdefined(Base, :methodloc_callback)
            print(io, methods(triggered))
            mline = line_is_decl ? 1 : 2
            @test occursin(filename * ":$mline", String(take!(io)))
        end
        write(filename, """
            # A comment to change the line numbers
            function triggered(iserr::Bool, iswarn::Bool)
                iserr && error("error")
                iswarn && @warn "Information"
                return nothing
            end
            """)
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
        targetstr = basename(filename * ":3")
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
            mline = line_is_decl ? 2 : 3
            @test occursin(basename(filename * ":$mline"), String(take!(io)))
        end

        push!(to_remove, filename)
    end

    # Issue #43
    do_test("New submodules") && @testset "New submodules" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "Submodules", "src")
        mkpath(dn)
        write(joinpath(dn, "Submodules.jl"), """
            module Submodules
            f() = 1
            end
            """)
        sleep(mtimedelay)
        @eval using Submodules
        sleep(mtimedelay)
        @test Submodules.f() == 1
        write(joinpath(dn, "Submodules.jl"), """
            module Submodules
            f() = 1
            module Sub
            g() = 2
            end
            end
            """)
        yry()
        @test Submodules.f() == 1
        @test Submodules.Sub.g() == 2
        rm_precompile("Submodules")
        pop!(LOAD_PATH)
    end

    do_test("Submodule in same file (#718)") && @testset "Submodule in same file (#718)" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "TestPkg718", "src")
        mkpath(dn)
        write(joinpath(dn, "TestPkg718.jl"), """
            module TestPkg718

            module TestModule718
                export _VARIABLE_UNASSIGNED
                global _VARIABLE_UNASSIGNED = -84.0
            end

            using .TestModule718

            end
            """)
        sleep(mtimedelay)
        @eval using TestPkg718
        sleep(mtimedelay)
        @test TestPkg718._VARIABLE_UNASSIGNED == -84.0
        write(joinpath(dn, "TestPkg718.jl"), """
            module TestPkg718

            module TestModule718
                export _VARIABLE_UNASSIGNED
                global _VARIABLE_UNASSIGNED = -83.0
            end

            using .TestModule718

            end
            """)
        yry()
        @test TestPkg718._VARIABLE_UNASSIGNED == -83.0

        rm_precompile("TestPkg718")
        pop!(LOAD_PATH)
    end

    do_test("Timing (issue #341)") && @testset "Timing (issue #341)" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "Timing", "src")
        mkpath(dn)
        write(joinpath(dn, "Timing.jl"), """
            module Timing
            f(x) = 1
            end
            """)
        sleep(mtimedelay)
        @eval using Timing
        sleep(mtimedelay)
        @test Timing.f(nothing) == 1
        tmpfile = joinpath(dn, "Timing_temp.jl")
        write(tmpfile, """
            module Timing
            f(x) = 2
            end
            """)
        yry()
        @test Timing.f(nothing) == 1
        mv(tmpfile, pathof(Timing), force=true)
        yry()
        @test Timing.f(nothing) == 2

        rm_precompile("Timing")
    end

    do_test("Method deletion") && @testset "Method deletion" begin
        Core.eval(Base, :(revisefoo(x::Float64) = 1)) # to test cross-module method scoping
        testdir = newtestdir()
        dn = joinpath(testdir, "MethDel", "src")
        mkpath(dn)
        write(joinpath(dn, "MethDel.jl"), """
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

            @generated function firstparam(A::AbstractArray)
                T = A.parameters[1]
                return :(\$T)
            end

            end
            """)
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
        @test MethDel.firstparam(rand(2,2)) === Float64
        write(joinpath(dn, "MethDel.jl"), """
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
        @test_throws MethodError MethDel.firstparam(rand(2,2))

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

    do_test("revise_file_now") && @testset "revise_file_now" begin
        # Very rarely this is used for debugging
        testdir = newtestdir()
        dn = joinpath(testdir, "ReviseFileNow", "src")
        mkpath(dn)
        fn = joinpath(dn, "ReviseFileNow.jl")
        write(fn, """
            module ReviseFileNow
            f(x) = 1
            end
            """)
        sleep(mtimedelay)
        @eval using ReviseFileNow
        @test ReviseFileNow.f(0) == 1
        sleep(mtimedelay)
        pkgdata = Revise.pkgdatas[Base.PkgId(ReviseFileNow)]
        write(fn, """
            module ReviseFileNow
            f(x) = 2
            end
            """)
        try
            Revise.revise_file_now(pkgdata, "foo")
        catch err
            @test isa(err, ErrorException)
            @test occursin("not currently being tracked", err.msg)
        end
        Revise.revise_file_now(pkgdata, relpath(fn, pkgdata))
        @test ReviseFileNow.f(0) == 2

        rm_precompile("ReviseFileNow")
    end

    do_test("Evaled toplevel") && @testset "Evaled toplevel" begin
        testdir = newtestdir()
        dnA = joinpath(testdir, "ToplevelA", "src"); mkpath(dnA)
        dnB = joinpath(testdir, "ToplevelB", "src"); mkpath(dnB)
        dnC = joinpath(testdir, "ToplevelC", "src"); mkpath(dnC)
        write(joinpath(dnA, "ToplevelA.jl"), """
            module ToplevelA
            @eval using ToplevelB
            g() = 2
            end""")
        write(joinpath(dnB, "ToplevelB.jl"), """
            module ToplevelB
            using ToplevelC
            end""")
        write(joinpath(dnC, "ToplevelC.jl"), """
            module ToplevelC
            export f
            f() = 1
            end""")
        sleep(mtimedelay)
        using ToplevelA
        sleep(mtimedelay)
        @test ToplevelA.ToplevelB.f() == 1
        @test ToplevelA.g() == 2
        write(joinpath(dnA, "ToplevelA.jl"), """
            module ToplevelA
            @eval using ToplevelB
            g() = 3
            end""")
        yry()
        @test ToplevelA.ToplevelB.f() == 1
        @test ToplevelA.g() == 3

        rm_precompile("ToplevelA")
        rm_precompile("ToplevelB")
        rm_precompile("ToplevelC")
    end

    do_test("struct inner functions") && @testset "struct inner functions" begin
        # issue #599
        testdir = newtestdir()
        dn = joinpath(testdir, "StructInnerFuncs", "src"); mkpath(dn)
        write(joinpath(dn, "StructInnerFuncs.jl"), """
            module StructInnerFuncs
            mutable struct A
                x::Int

                A(x) = new(f(x))
                f(x) = x^2
            end
            g(x) = 1
            end""")
        sleep(mtimedelay)
        using StructInnerFuncs
        sleep(mtimedelay)
        @test StructInnerFuncs.A(2).x == 4
        @test StructInnerFuncs.g(3) == 1
        write(joinpath(dn, "StructInnerFuncs.jl"), """
            module StructInnerFuncs
            mutable struct A
                x::Int

                A(x) = new(f(x))
                f(x) = x^2
            end
            g(x) = 2
            end""")
        yry()
        @test StructInnerFuncs.A(2).x == 4
        @test StructInnerFuncs.g(3) == 2

        rm_precompile("StructInnerFuncs")
    end

    do_test("Issue 606") && @testset "Issue 606" begin
        # issue #606
        testdir = newtestdir()
        dn = joinpath(testdir, "Issue606", "src"); mkpath(dn)
        write(joinpath(dn, "Issue606.jl"), """
            module Issue606
            function convert_output_relations()
                function add_default_zero!(dict::Dict{K, V})::Dict{K, V} where
                        {K <: Tuple, V}
                    if K == Tuple{} && isempty(dict)
                        dict[()] = 0.0
                    end
                    return dict
                end

                function convert_to_sorteddict(
                    relation::Union{Dict{K, Tuple{Float64}}}
                ) where K <: Tuple
                    return add_default_zero!(Dict{K, Float64}((k, v[1]) for (k, v) in relation))
                end

                function convert_to_sorteddict(relation::Dict{<:Tuple, Float64})
                    return add_default_zero!(relation)
                end

                return "HELLO"
            end
            end""")
        sleep(mtimedelay)
        using Issue606
        sleep(mtimedelay)
        @test Issue606.convert_output_relations() == "HELLO"
        write(joinpath(dn, "Issue606.jl"), """
            module Issue606
            function convert_output_relations()
                function add_default_zero!(dict::Dict{K, V})::Dict{K, V} where
                        {K <: Tuple, V}
                    if K == Tuple{} && isempty(dict)
                        dict[()] = 0.0
                    end
                    return dict
                end

                function convert_to_sorteddict(
                    relation::Union{Dict{K, Tuple{Float64}}}
                ) where K <: Tuple
                    return add_default_zero!(Dict{K, Float64}((k, v[1]) for (k, v) in relation))
                end

                function convert_to_sorteddict(relation::Dict{<:Tuple, Float64})
                    return add_default_zero!(relation)
                end

                return "HELLO2"
            end
            end""")
        yry()
        @test Issue606.convert_output_relations() == "HELLO2"

        rm_precompile("Issue606")
    end

    do_test("Revision errors") && @testset "Revision errors" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "RevisionErrors", "src")
        mkpath(dn)
        fn = joinpath(dn, "RevisionErrors.jl")
        write(fn, """
            module RevisionErrors
            f(x) = 1
            struct Vec{N, T <: Union{Float32,Float64}}
                data::NTuple{N, T}
            end
            g(x) = 1
            end
            """)
        sleep(mtimedelay)
        @eval using RevisionErrors
        sleep(mtimedelay)
        @test RevisionErrors.f(0) == 1
        write(fn, """
            module RevisionErrors
            f{x) = 2
            struct Vec{N, T <: Union{Float32,Float64}}
                data::NTuple{N, T}
            end
            g(x) = 1
            end
            """)
        logs, _ = Test.collect_test_logs() do
            yry()
        end

        function check_revision_error(rec, ErrorType, msg, line)
            @test rec.message == "Failed to revise $fn"
            exc = rec.kwargs[:exception]
            if exc isa Revise.ReviseEvalException
                exc, st = exc.exc, exc.stacktrace
            else
                exc, bt = exc
                st = stacktrace(bt)
            end
            @test exc isa ErrorType
            if ErrorType === LoadError
                @test exc.file == fn
                @test exc.line == line
                @test occursin(msg, errmsg(exc.error))
            elseif ErrorType === Base.Meta.ParseError
                @test occursin(msg, exc.msg)
            elseif ErrorType === UndefVarError
                @test msg == exc.var
            end
            @test length(st) == 1
        end

        # test errors are reported the the first time
        check_revision_error(logs[1], Base.VERSION < v"1.10" ? LoadError : Base.Meta.ParseError,
                             Base.VERSION < v"1.10" ? "missing comma or }" : "Expected `}`", 2 + (Base.VERSION >= v"1.10"))
        # Check that there's an informative warning
        rec = logs[2]
        @test startswith(rec.message, "The running code does not match")
        @test occursin("RevisionErrors.jl", rec.message)

        # test errors are not re-reported
        logs, _ = Test.collect_test_logs() do
            yry()
        end
        @test isempty(logs)

        # test error re-reporting
        logs,_ = Test.collect_test_logs() do
            Revise.errors()
        end
        check_revision_error(logs[1], Base.VERSION < v"1.10" ? LoadError : Base.Meta.ParseError,
                             Base.VERSION < v"1.10" ? "missing comma or }" : "Expected `}`", 2 + (Base.VERSION >= v"1.10"))

        write(joinpath(dn, "RevisionErrors.jl"), """
            module RevisionErrors
            f(x) = 2
            struct Vec{N, T <: Union{Float32,Float64}}
                data::NTuple{N, T}
            end
            g(x) = 1
            end
            """)
        logs, _ = Test.collect_test_logs() do
            yry()
        end
        @test isempty(logs)
        @test RevisionErrors.f(0) == 2

        # issue #421
        write(joinpath(dn, "RevisionErrors.jl"), """
            module RevisionErrors
            f(x) = 2
            struct Vec{N, T <: Union{Float32,Float64}}
                data::NTuple{N, T}
            end
            function g(x) = 1
            end
            """)
        logs, _ = Test.collect_test_logs() do
            yry()
        end
        delim = Base.VERSION < v"1.10" ? '"' : '`'
        check_revision_error(logs[1], Base.VERSION < v"1.10" ? LoadError : Base.Meta.ParseError,
                             "unexpected $delim=$delim", 6 + (Base.VERSION >= v"1.10")*2)

        write(joinpath(dn, "RevisionErrors.jl"), """
            module RevisionErrors
            f(x) = 2
            struct Vec{N, T <: Union{Float32,Float64}}
                data::NTuple{N, T}
            end
            g(x) = 1
            end
            """)
        logs, _ = Test.collect_test_logs() do
            yry()
        end
        @test isempty(logs)

        write(joinpath(dn, "RevisionErrors.jl"), """
            module RevisionErrors
            f(x) = 2
            struct Vec{N, T <: Union{Float32,Float64}}
                data::NTuple{N, T}
            end
            g(x) = 1
            foo(::Vector{T}) = 3
            end
            """)
        logs, _ = Test.collect_test_logs() do
            yry()
        end
        check_revision_error(logs[1], UndefVarError, :T, 6)

        # issue #541
        sleep(mtimedelay)
        write(joinpath(dn, "RevisionErrors.jl"), """
            module RevisionErrors
            f(x) = 2
            struct Vec{N, T <: Union{Float32,Float64}}
                data::NTuple{N, T}
            end
            g(x} = 2
            end
            """)
        @test try
            revise(throw=true)
            false
        catch err
            if Base.VERSION < v"1.10"
                isa(err, LoadError) && occursin("""unexpected "}" """, errmsg(err.error))
            else
                isa(err, Base.Meta.ParseError) && occursin("Expected `)`", err.msg)
            end
        end
        sleep(mtimedelay)
        write(joinpath(dn, "RevisionErrors.jl"), """
            module RevisionErrors
            f(x) = 2
            struct Vec{N, T <: Union{Float32,Float64}}
                data::NTuple{N, T}
            end
            g(x) = 2
            end
            """)
        yry()
        @test RevisionErrors.g(0) == 2

        rm_precompile("RevisionErrors")
        empty!(Revise.queue_errors)

        testfile = joinpath(testdir, "Test301.jl")
        write(testfile, """
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
        logfile = joinpath(tempdir(), randtmp()*".log")
        open(logfile, "w") do io
            redirect_stderr(io) do
                includet(testfile)
            end
        end
        sleep(mtimedelay)
        lines = readlines(logfile)
        @test lines[1] == "ERROR: UndefRefError: access to undefined reference"
        @test any(str -> occursin(r"f\(.*Test301\.Struct301\)", str), lines)
        @test any(str -> endswith(str, "Test301.jl:10"), lines)

        logfile = joinpath(tempdir(), randtmp()*".log")
        open(logfile, "w") do io
            redirect_stderr(io) do
                includet("callee_error.jl")
            end
        end
        sleep(mtimedelay)
        lines = readlines(logfile)
        @test lines[1] == "ERROR: BoundsError: attempt to access 3-element $(Vector{Int}) at index [4]"
        @test any(str -> endswith(str, "callee_error.jl:12"), lines)
        @test_throws UndefVarError CalleeError.foo(0.1f0)
    end

    do_test("Retry on InterruptException") && @testset "Retry on InterruptException" begin
        function check_revision_interrupt(logs)
            rec = logs[1]
            @test rec.message == "Failed to revise $fn"
            exc = rec.kwargs[:exception]
            if exc isa Revise.ReviseEvalException
                exc, st = exc.exc, exc.stacktrace
            else
                exc, bt = exc
                st = stacktrace(bt)
            end
            @test exc isa InterruptException
            if length(logs) > 1
                rec = logs[2]
                @test startswith(rec.message, "The running code does not match")
            end
        end

        testdir = newtestdir()
        dn = joinpath(testdir, "RevisionInterrupt", "src")
        mkpath(dn)
        fn = joinpath(dn, "RevisionInterrupt.jl")
        write(fn, """
            module RevisionInterrupt
            f(x) = 1
            end
            """)
        sleep(mtimedelay)
        @eval using RevisionInterrupt
        sleep(mtimedelay)
        @test RevisionInterrupt.f(0) == 1

        # Interpreted & compiled mode
        n = 1
        for errthrow in ("throw(InterruptException())", """
                         eval(quote  # this forces interpreted mode
                             throw(InterruptException())
                         end)""")
            n += 1
            write(fn, """
                module RevisionInterrupt
                $errthrow
                f(x) = $n
                end
                """)
            logs, _ = Test.collect_test_logs() do
                yry()
            end
            check_revision_interrupt(logs)
            # This method gets deleted because it's redefined to f(x) = 2,
            # but the error prevents it from getting that far.
            # @test RevisionInterrupt.f(0) == 1
            # Check that InterruptException triggers a retry (issue #418)
            logs, _ = Test.collect_test_logs() do
                yry()
            end
            check_revision_interrupt(logs)
            # @test RevisionInterrupt.f(0) == 1
            write(fn, """
                module RevisionInterrupt
                f(x) = $n
                end
                """)
            logs, _ = Test.collect_test_logs() do
                yry()
            end
            @test isempty(logs)
            @test RevisionInterrupt.f(0) == n
        end
    end

    do_test("Modify @enum") && @testset "Modify @enum" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "ModifyEnum", "src")
        mkpath(dn)
        write(joinpath(dn, "ModifyEnum.jl"), """
            module ModifyEnum
            @enum Fruit apple=1 orange=2
            end
            """)
        sleep(mtimedelay)
        @eval using ModifyEnum
        sleep(mtimedelay)
        @test Int(ModifyEnum.apple) == 1
        @test ModifyEnum.apple isa ModifyEnum.Fruit
        @test_throws UndefVarError Int(ModifyEnum.kiwi)
        write(joinpath(dn, "ModifyEnum.jl"), """
            module ModifyEnum
            @enum Fruit apple=1 orange=2 kiwi=3
            end
            """)
        yry()
        @test Int(ModifyEnum.kiwi) == 3
        @test Base.instances(ModifyEnum.Fruit) === (ModifyEnum.apple, ModifyEnum.orange, ModifyEnum.kiwi)
        rm_precompile("ModifyEnum")
        pop!(LOAD_PATH)
    end

    do_test("get_def") && @testset "get_def" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "GetDef", "src")
        mkpath(dn)
        write(joinpath(dn, "GetDef.jl"), """
            module GetDef

            f(x) = 1
            f(v::AbstractVector) = 2
            f(v::AbstractVector{<:Integer}) = 3

            foo(x::T, y::Integer=1; kw1="hello", kwargs...) where T<:Number = error("stop")
            bar(x) = foo(x; kw1="world")

            end
            """)
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

    do_test("Pkg exclusion") && @testset "Pkg exclusion" begin
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

    do_test("Manual track") && @testset "Manual track" begin
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        write(srcfile, "revise_f(x) = 1")
        sleep(mtimedelay)
        includet(srcfile)
        sleep(mtimedelay)
        @test revise_f(10) == 1
        @test length(signatures_at(srcfile, 1)) == 1
        write(srcfile, "revise_f(x) = 2")
        yry()
        @test revise_f(10) == 2
        push!(to_remove, srcfile)

        # Do it again with a relative path
        curdir = pwd()
        cd(tempdir())
        srcfile = randtmp()*".jl"
        write(srcfile, "revise_floc(x) = 1")
        sleep(mtimedelay)
        include(joinpath(pwd(), srcfile))
        @test revise_floc(10) == 1
        Revise.track(srcfile)
        sleep(mtimedelay)
        write(srcfile, "revise_floc(x) = 2")
        yry()
        @test revise_floc(10) == 2
        # Call track again & make sure it doesn't track twice
        Revise.track(srcfile)
        id = Base.PkgId(Main)
        pkgdata = Revise.pkgdatas[id]
        @test count(isequal(srcfile), pkgdata.info.files) == 1
        push!(to_remove, joinpath(tempdir(), srcfile))
        cd(curdir)

        # Empty files (issue #253)
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        write(srcfile, "\n")
        sleep(mtimedelay)
        includet(srcfile)
        sleep(mtimedelay)
        @test basename(srcfile) ∈ Revise.watched_files[dirname(srcfile)]
        push!(to_remove, srcfile)

        # Double-execution (issue #263)
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        write(srcfile, "println(\"executed\")")
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
        # In older versions of Revise, it would do the work again when the file
        # changed. Starting with 3.0, Revise modifies methods and docstrings but
        # does not "do work."
        write(srcfile, "println(\"executed again\")")
        open(logfile, "w") do io
            redirect_stdout(io) do
                yry()
            end
        end
        lines = readlines(logfile)
        @test isempty(lines)

        # tls path (issue #264)
        srcdir = joinpath(tempdir(), randtmp())
        mkpath(srcdir)
        push!(to_remove, srcdir)
        srcfile1 = joinpath(srcdir, randtmp()*".jl")
        srcfile2 = joinpath(srcdir, randtmp()*".jl")
        write(srcfile1, "includet(\"$(basename(srcfile2))\")")
        write(srcfile2, "f264() = 1")
        sleep(mtimedelay)
        include(srcfile1)
        sleep(mtimedelay)
        @test f264() == 1
        write(srcfile2, "f264() = 2")
        yry()
        @test f264() == 2

        # recursive `includet`s (issue #302)
        testdir = newtestdir()
        srcfile1 = joinpath(testdir, "Test302.jl")
        write(srcfile1, """
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
        srcfile2 = joinpath(testdir, "test2.jl")
        write(srcfile2, """
            includet(joinpath(@__DIR__, "Test302.jl"))
            using .Test302
            """)
        sleep(mtimedelay)
        includet(srcfile2)
        sleep(mtimedelay)
        p = Test302.Parameters{Int}(3)
        @test p() == p
        write(srcfile1, """
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
        yry()
        @test p() == 0

        # Double-execution prevention (issue #639)
        empty!(issue639report)
        srcfile1 = joinpath(testdir, "file1.jl")
        srcfile2 = joinpath(testdir, "file2.jl")
        write(srcfile1, """
            include(joinpath(@__DIR__, "file2.jl"))
            push!($(@__MODULE__).issue639report, '1')
            """)
        write(srcfile2, "push!($(@__MODULE__).issue639report, '2')")
        sleep(mtimedelay)
        includet(srcfile1)
        @test issue639report == ['2', '1']

        # Non-included dependency (issue #316)
        testdir = newtestdir()
        dn = joinpath(testdir, "LikePlots", "src"); mkpath(dn)
        write(joinpath(dn, "LikePlots.jl"), """
            module LikePlots
            plot() = 0
            backend() = include(joinpath(@__DIR__, "backends/backend.jl"))
            end
            """)
        sd = joinpath(dn, "backends"); mkpath(sd)
        write(joinpath(sd, "backend.jl"), "f() = 1")
        sleep(mtimedelay)
        @eval using LikePlots
        @test LikePlots.plot() == 0
        @test_throws UndefVarError LikePlots.f()
        sleep(mtimedelay)
        Revise.track(LikePlots, joinpath(sd, "backend.jl"))
        LikePlots.backend()
        @test LikePlots.f() == 1
        sleep(2*mtimedelay)
        write(joinpath(sd, "backend.jl"), "f() = 2")
        yry()
        @test LikePlots.f() == 2
        pkgdata = Revise.pkgdatas[Base.PkgId(LikePlots)]
        @test joinpath("src", "backends", "backend.jl") ∈ Revise.srcfiles(pkgdata)
        # No duplications from Revise.track with either relative or absolute paths
        Revise.track(LikePlots, joinpath(sd, "backend.jl"))
        @test length(Revise.srcfiles(pkgdata)) == 2
        cd(dn) do
            Revise.track(LikePlots, joinpath("backends", "backend.jl"))
            @test length(Revise.srcfiles(pkgdata)) == 2
        end

        rm_precompile("LikePlots")

        # Issue #475
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        write(srcfile, """
            a475 = 0.8
            a475 = 0.7
            a475 = 0.8
            """)
        includet(srcfile)
        @test a475 == 0.8

    end

    do_test("Auto-track user scripts") && @testset "Auto-track user scripts" begin
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        push!(to_remove, srcfile)
        write(srcfile, "revise_g() = 1")
        sleep(mtimedelay)
        # By default user scripts are not tracked
        # issue #358: but if the user is tracking all includes...
        user_track_includes = Revise.tracking_Main_includes[]
        Revise.tracking_Main_includes[] = false
        include(srcfile)
        yry()
        @test revise_g() == 1
        write(srcfile, "revise_g() = 2")
        yry()
        @test revise_g() == 1
        # Turn on tracking of user scripts
        empty!(Revise.included_files)  # don't track files already loaded (like this one)
        Revise.tracking_Main_includes[] = true
        try
            srcfile = joinpath(tempdir(), randtmp()*".jl")
            push!(to_remove, srcfile)
            write(srcfile, "revise_g() = 1")
            sleep(mtimedelay)
            include(srcfile)
            yry()
            @test revise_g() == 1
            write(srcfile, "revise_g() = 2")
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

    do_test("Distributed") && @testset "Distributed" begin
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
        write(joinpath(dn, modname*".jl"), """
            module ReviseDistributed
            using Distributed

            f() = π
            g(::Int) = 0
            $s31474

            end
            """)
        sleep(mtimedelay)
        using ReviseDistributed
        sleep(mtimedelay)
        @everywhere using ReviseDistributed
        for p in allworkers
            @test remotecall_fetch(ReviseDistributed.f, p)    == π
            @test remotecall_fetch(ReviseDistributed.g, p, 1) == 0
        end
        @test ReviseDistributed.d31474() == 2.0
        s31474 = """
        function d31474()
            r = @spawnat $newproc sqrt(9)
            fetch(r)
        end
        """
        write(joinpath(dn, modname*".jl"), """
            module ReviseDistributed

            f() = 3.0
            $s31474

            end
            """)
        yry()
        @test_throws MethodError ReviseDistributed.g(1)
        for p in allworkers
            @test remotecall_fetch(ReviseDistributed.f, p) == 3.0
            @test_throws RemoteException remotecall_fetch(ReviseDistributed.g, p, 1)
        end
        @test ReviseDistributed.d31474() == 3.0
        rmprocs(allworkers[2:3]...; waitfor=10)
        rm_precompile("ReviseDistributed")
        pop!(LOAD_PATH)
    end


    do_test("Distributed on worker") && @testset "Distributed on worker" begin
        # https://github.com/timholy/Revise.jl/pull/527
        favorite_proc, boring_proc = addprocs(2)

        Distributed.remotecall_eval(Main, [favorite_proc, boring_proc], :(ENV["JULIA_REVISE_WORKER_ONLY"] = "1"))

        dirname = randtmp()
        mkdir(dirname)
        push!(to_remove, dirname)

        @everywhere push_LOAD_PATH!(dirname) = push!(LOAD_PATH, dirname)  # Don't want to share this LOAD_PATH
        remotecall_wait(push_LOAD_PATH!, favorite_proc, dirname)

        modname = "ReviseDistributedOnWorker"
        dn = joinpath(dirname, modname, "src")
        mkpath(dn)

        s527_old = """
        module ReviseDistributedOnWorker

        f() = π
        g(::Int) = 0

        end
        """
        write(joinpath(dn, modname*".jl"), s527_old)

        # In the first tests, we only load Revise on our favorite process. The other (boring) process should be unaffected by the upcoming tests.
        Distributed.remotecall_eval(Main, [favorite_proc], :(using Revise))
        sleep(mtimedelay)
        Distributed.remotecall_eval(Main, [favorite_proc], :(using ReviseDistributedOnWorker))
        sleep(mtimedelay)

        @test Distributed.remotecall_eval(Main, favorite_proc, :(ReviseDistributedOnWorker.f())) == π
        @test Distributed.remotecall_eval(Main, favorite_proc, :(ReviseDistributedOnWorker.g(1))) == 0

        # we only loaded ReviseDistributedOnWorker on our favorite process
        @test_throws RemoteException Distributed.remotecall_eval(Main, boring_proc, :(ReviseDistributedOnWorker.f()))
        @test_throws RemoteException Distributed.remotecall_eval(Main, boring_proc, :(ReviseDistributedOnWorker.g(1)))

        s527_new = """
        module ReviseDistributedOnWorker

        f() = 3.0

        end
        """
        write(joinpath(dn, modname*".jl"), s527_new)
        sleep(mtimedelay)
        Distributed.remotecall_eval(Main, [favorite_proc], :(Revise.revise()))
        sleep(mtimedelay)


        @test Distributed.remotecall_eval(Main, favorite_proc, :(ReviseDistributedOnWorker.f())) == 3.0
        @test_throws RemoteException Distributed.remotecall_eval(Main, favorite_proc, :(ReviseDistributedOnWorker.g(1)))

        @test_throws RemoteException Distributed.remotecall_eval(Main, boring_proc, :(ReviseDistributedOnWorker.f()))
        @test_throws RemoteException Distributed.remotecall_eval(Main, boring_proc, :(ReviseDistributedOnWorker.g(1)))

        # In the second part, we'll also load Revise on the boring process, which should have no effect.
        Distributed.remotecall_eval(Main, [boring_proc], :(using Revise))

        write(joinpath(dn, modname*".jl"), s527_old)

        sleep(mtimedelay)
        @test !Distributed.remotecall_eval(Main, favorite_proc, :(Revise.revision_queue |> isempty))
        @test Distributed.remotecall_eval(Main, boring_proc, :(Revise.revision_queue |> isempty))

        Distributed.remotecall_eval(Main, [favorite_proc, boring_proc], :(Revise.revise()))
        sleep(mtimedelay)


        @test Distributed.remotecall_eval(Main, favorite_proc, :(ReviseDistributedOnWorker.f())) == π
        @test Distributed.remotecall_eval(Main, favorite_proc, :(ReviseDistributedOnWorker.g(1))) == 0

        @test_throws RemoteException Distributed.remotecall_eval(Main, boring_proc, :(ReviseDistributedOnWorker.f()))
        @test_throws RemoteException Distributed.remotecall_eval(Main, boring_proc, :(ReviseDistributedOnWorker.g(1)))

        rmprocs(favorite_proc, boring_proc; waitfor=10)
    end

    do_test("Git") && @testset "Git" begin
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
                write(mainjl, """
                    module $modname
                    end
                    """)
                LibGit2.add!(repo, joinpath("src", modname*".jl"))
                test_sig = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time(); digits=0), 0)
                LibGit2.commit(repo, "New file test"; author=test_sig, committer=test_sig)
            end
            sleep(mtimedelay)
            @eval using $(Symbol(modname))
            sleep(mtimedelay)
            mod = @eval $(Symbol(modname))
            id = Base.PkgId(mod)
            extrajl = joinpath(randdir, "src", "extra.jl")
            write(extrajl, "println(\"extra\")")
            write(mainjl, """
                module $modname
                include("extra.jl")
                end
                """)
            sleep(mtimedelay)
            repo = LibGit2.GitRepo(randdir)
            LibGit2.add!(repo, joinpath("src", "extra.jl"))
            pkgdata = Revise.pkgdatas[id]
            logs, _ = Test.collect_test_logs() do
                Revise.track_subdir_from_git!(pkgdata, joinpath(randdir, "src"); commit="HEAD")
            end
            yry()
            @test Revise.hasfile(pkgdata, mainjl)
            @test startswith(logs[end].message, "skipping src/extra.jl") || startswith(logs[end-1].message, "skipping src/extra.jl")
            rm_precompile("ModuleWithNewFile")
            pop!(LOAD_PATH)
        end
    end

    do_test("Recipes") && @testset "Recipes" begin
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
        @test definition(m).head ∈ (:function, :(=))

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

    do_test("CodeTracking #48") && @testset "CodeTracking #48" begin
        m = @which sum([1]; dims=1)
        file, line = whereis(m)
        @test endswith(file, "reducedim.jl") && line > 1
    end

    do_test("Methods at REPL") && @testset "Methods at REPL" begin
        if isdefined(Base, :active_repl)
            hp = Base.active_repl.interface.modes[1].hist
            fstr = "__fREPL__(x::Int16) = 0"
            histidx = length(hp.history) + 1 - hp.start_idx
            ex = Base.parse_input_line(fstr; filename="REPL[$histidx]")
            f = Core.eval(Main, ex)
            if ex.head === :toplevel
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
            if ex.head === :toplevel
                ex = ex.args[end]
            end
            push!(hp.history, fstr)
            m = first(methods(f))
            @test isequal(Revise.RelocatableExpr(definition(m)), Revise.RelocatableExpr(ex))
            @test definition(String, m)[1] == fstr
            @test !isempty(signatures_at(String(m.file), m.line))

            pop!(hp.history)
            pop!(hp.history)
        else
            @warn "REPL tests skipped"
        end
    end

    do_test("baremodule") && @testset "baremodule" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "Baremodule", "src")
        mkpath(dn)
        write(joinpath(dn, "Baremodule.jl"), """
            baremodule Baremodule
            f() = 1
            end
            """)
        sleep(mtimedelay)
        @eval using Baremodule
        sleep(mtimedelay)
        @test Baremodule.f() == 1
        write(joinpath(dn, "Baremodule.jl"), """
            module Baremodule
            f() = 2
            end
            """)
        yry()
        @test Baremodule.f() == 2
        rm_precompile("Baremodule")
        pop!(LOAD_PATH)
    end

    do_test("module style 2-argument includes (issue #670)") && @testset "module style 2-argument includes (issue #670)" begin
        testdir = newtestdir()
        dn = joinpath(testdir, "B670", "src")
        mkpath(dn)
        write(joinpath(dn, "A670.jl"), """
            x = 6
            y = 7
            """)
        sleep(mtimedelay)
        write(joinpath(dn, "B670.jl"), """
            module B670
                x = 5
            end
            """)
        sleep(mtimedelay)
        write(joinpath(dn, "C670.jl"), """
            using B670
            Base.include(B670, "A670.jl")
            """)
        sleep(mtimedelay)
        @eval using B670
        path = joinpath(dn, "C670.jl")
        @eval include($path)
        @test B670.x == 6
        @test B670.y == 7
        rm_precompile("B670")
    end
end

do_test("Utilities") && @testset "Utilities" begin
    # Used by Rebugger but still lives here
    io = IOBuffer()
    Revise.println_maxsize(io, "a"^100; maxchars=50)
    str = String(take!(io))
    @test startswith(str, "a"^25)
    @test endswith(chomp(chomp(str)), "a"^24)
    @test occursin("…", str)
end

do_test("Switching free/dev") && @testset "Switching free/dev" begin
    function make_a2d(path, val, mode="r"; generate=true)
        # Create a new "read-only package" (which mimics how Pkg works when you `add` a package)
        cd(path) do
            pkgpath = normpath(joinpath(path, "A2D"))
            srcpath = joinpath(pkgpath, "src")
            if generate
                Pkg.generate("A2D")
            else
                mkpath(srcpath)
            end
            filepath = joinpath(srcpath, "A2D.jl")
            write(filepath, """
                module A2D
                f() = $val
                end
                """)
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
    ENV["JULIA_PKG_SERVER"] = ""
    registries = isdefined(Pkg.Types, :DEFAULT_REGISTRIES) ? Pkg.Types.DEFAULT_REGISTRIES : Pkg.Registry.DEFAULT_REGISTRIES
    old_registries = copy(registries)
    empty!(registries)
    # Ensure we start fresh with no dependencies
    old_project = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)", "Project.toml")
    mkpath(dirname(Base.ACTIVE_PROJECT[]))
    write(Base.ACTIVE_PROJECT[], "[deps]")
    ropkgpath = make_a2d(depot, 1)
    Pkg.develop(PackageSpec(path=ropkgpath))
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
    schedule(Task(Revise.TaskThunk(Revise.watch_manifest, (mfile,))))
    sleep(mtimedelay)
    pkgdevpath = make_a2d(devpath, 2, "w"; generate=false)
    cp(joinpath(ropkgpath, "Project.toml"), joinpath(devpath, "A2D/Project.toml"))
    Pkg.develop(PackageSpec(path=pkgdevpath))
    yry()
    @test Base.invokelatest(A2D.f) == 2
    Pkg.develop(PackageSpec(path=ropkgpath))
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

do_test("Switching environments") && @testset "Switching environments" begin
    old_project = Base.active_project()

    function generate_package(path, val)
        cd(path) do
            pkgpath = normpath(joinpath(path, "TestPackage"))
            srcpath = joinpath(pkgpath, "src")
            if !isdir(srcpath)
                Pkg.generate("TestPackage")
            end
            filepath = joinpath(srcpath, "TestPackage.jl")
            write(filepath, """
                module TestPackage
                f() = $val
                end
                """)
            return pkgpath
        end
    end

    try
        Pkg.activate(; temp=true)

        # generate a package
        root = mktempdir()
        pkg = generate_package(root, 1)
        LibGit2.with(LibGit2.init(pkg)) do repo
            LibGit2.add!(repo, "Project.toml")
            LibGit2.add!(repo, "src/TestPackage.jl")
            test_sig = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time(); digits=0), 0)
            LibGit2.commit(repo, "version 1"; author=test_sig, committer=test_sig)
        end

        # install the package
        Pkg.add(url=pkg)
        sleep(mtimedelay)

        @eval using TestPackage
        sleep(mtimedelay)
        @test Base.invokelatest(TestPackage.f) == 1

        # update the package
        generate_package(root, 2)
        LibGit2.with(LibGit2.GitRepo(pkg)) do repo
            LibGit2.add!(repo, "src/TestPackage.jl")
            test_sig = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time(); digits=0), 0)
            LibGit2.commit(repo, "version 2"; author=test_sig, committer=test_sig)
        end

        # install the update
        Pkg.add(url=pkg)
        sleep(mtimedelay)

        revise()
        @test Base.invokelatest(TestPackage.f) == 2
    finally
        Pkg.activate(old_project)
    end
end

# in v1.8 and higher, a package can't be loaded at all when its precompilation failed
@static if Base.VERSION < v"1.8.0-DEV.1451"
do_test("Broken dependencies (issue #371)") && @testset "Broken dependencies (issue #371)" begin
    testdir = newtestdir()
    srcdir = joinpath(testdir, "DepPkg371", "src")
    filepath = joinpath(srcdir, "DepPkg371.jl")
    cd(testdir) do
        Pkg.generate("DepPkg371")
        write(filepath, """
            module DepPkg371
            using OrderedCollections   # undeclared dependency
            greet() = "Hello world!"
            end
            """)
    end
    sleep(mtimedelay)
    @info "A warning about not having OrderedCollection in dependencies is expected"
    @eval using DepPkg371
    @test DepPkg371.greet() == "Hello world!"
    sleep(mtimedelay)
    write(filepath, """
        module DepPkg371
        using OrderedCollections   # undeclared dependency
        greet() = "Hello again!"
        end
        """)
    yry()
    @test DepPkg371.greet() == "Hello again!"

    rm_precompile("DepPkg371")
    pop!(LOAD_PATH)
end
end # @static if VERSION ≤ v"1.7"

do_test("Non-jl include_dependency (issue #388)") && @testset "Non-jl include_dependency (issue #388)" begin
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

do_test("New files & Requires.jl") && @testset "New files & Requires.jl" begin
    # Issue #107
    testdir = newtestdir()
    dn = joinpath(testdir, "NewFile", "src")
    mkpath(dn)
    write(joinpath(dn, "NewFile.jl"), """
            module NewFile
            f() = 1
            module SubModule
            struct NewType end
            end
            end
            """)
    sleep(mtimedelay)
    @eval using NewFile
    @test NewFile.f() == 1
    @test_throws UndefVarError NewFile.g()
    sleep(mtimedelay)
    write(joinpath(dn, "g.jl"), "g() = 2")
    write(joinpath(dn, "NewFile.jl"), """
        module NewFile
        include("g.jl")
        f() = 1
        module SubModule
        struct NewType end
        end
        end
        """)
    yry()
    @test NewFile.f() == 1
    @test NewFile.g() == 2
    sd = joinpath(dn, "subdir")
    mkpath(sd)
    write(joinpath(sd, "h.jl"), "h(::NewType) = 3")
    write(joinpath(dn, "NewFile.jl"), """
        module NewFile
        include("g.jl")
        f() = 1
        module SubModule
        struct NewType end
        include("subdir/h.jl")
        end
        end
        """)
    yry()
    @test NewFile.f() == 1
    @test NewFile.g() == 2
    @test NewFile.SubModule.h(NewFile.SubModule.NewType()) == 3

    dn = joinpath(testdir, "DeletedFile", "src")
    mkpath(dn)
    write(joinpath(dn, "DeletedFile.jl"), """
        module DeletedFile
        include("g.jl")
        f() = 1
        end
        """)
    write(joinpath(dn, "g.jl"), "g() = 1")
    sleep(mtimedelay)
    @eval using DeletedFile
    @test DeletedFile.f() == DeletedFile.g() == 1
    sleep(mtimedelay)
    write(joinpath(dn, "DeletedFile.jl"), """
        module DeletedFile
        f() = 1
        end
        """)
    rm(joinpath(dn, "g.jl"))
    yry()
    @test DeletedFile.f() == 1
    @test_throws MethodError DeletedFile.g()

    rm_precompile("NewFile")
    rm_precompile("DeletedFile")

    # https://discourse.julialang.org/t/revise-with-requires/19347
    dn = joinpath(testdir, "TrackRequires", "src")
    mkpath(dn)
    write(joinpath(dn, "TrackRequires.jl"), """
        module TrackRequires
        using Requires
        const called_onearg = Ref(false)
        onearg(x) = called_onearg[] = true
        module SubModule
        abstract type SuperType end
        end
        function __init__()
            @require EndpointRanges="340492b5-2a47-5f55-813d-aca7ddf97656" begin
                export testfunc
                include("testfile.jl")
            end
            @require CatIndices="aafaddc9-749c-510e-ac4f-586e18779b91" onearg(1)
            @require IndirectArrays="9b13fd28-a010-5f03-acff-a1bbcff69959" @eval SubModule include("st.jl")
            @require RoundingIntegers="d5f540fe-1c90-5db3-b776-2e2f362d9394" begin
                fn = joinpath(@__DIR__, "subdir", "anotherfile.jl")
                include(fn)
                @require Revise="295af30f-e4ad-537b-8983-00126c2a3abe" Revise.track(TrackRequires, fn)
            end
            @require UnsafeArrays="c4a57d5a-5b31-53a6-b365-19f8c011fbd6" begin
                fn = joinpath(@__DIR__, "subdir", "yetanotherfile.jl")
                include(fn)
            end
        end
        end # module
        """)
    write(joinpath(dn, "testfile.jl"), "testfunc() = 1")
    write(joinpath(dn, "st.jl"), """
        struct NewType <: SuperType end
        h(::NewType) = 3
        """)
    sd = mkpath(joinpath(dn, "subdir"))
    write(joinpath(sd, "anotherfile.jl"), "ftrack() = 1")
    write(joinpath(sd, "yetanotherfile.jl"), "fauto() = 1")
    sleep(mtimedelay)
    @eval using TrackRequires
    notified = isdefined(TrackRequires.Requires, :withnotifications)
    notified || @warn "Requires does not support notifications"
    @test_throws UndefVarError TrackRequires.testfunc()
    @test_throws UndefVarError TrackRequires.SubModule.h(TrackRequires.SubModule.NewType())
    @eval using EndpointRanges  # to trigger Requires
    sleep(mtimedelay)
    notified && @test TrackRequires.testfunc() == 1
    write(joinpath(dn, "testfile.jl"), "testfunc() = 2")
    yry()
    notified && @test TrackRequires.testfunc() == 2
    @test_throws UndefVarError TrackRequires.SubModule.h(TrackRequires.SubModule.NewType())
    # Issue #477
    @eval using IndirectArrays
    sleep(mtimedelay)
    notified && @test TrackRequires.SubModule.h(TrackRequires.SubModule.NewType()) == 3
    # Check a non-block expression
    warnfile = randtmp()
    open(warnfile, "w") do io
        redirect_stderr(io) do
            @eval using CatIndices
            sleep(0.5)
        end
    end
    notified && @test TrackRequires.called_onearg[]
    @test isempty(read(warnfile, String))
    # Issue #431
    @test_throws UndefVarError TrackRequires.ftrack()
    if !(get(ENV, "CI", nothing) == "true" && Base.VERSION.major == 1 && Base.VERSION.minor == 8)   # circumvent CI hang
        @eval using RoundingIntegers
        sleep(2)  # allow time for the @async in all @require blocks to finish
        if notified
            @test TrackRequires.ftrack() == 1
            id = Base.PkgId(TrackRequires)
            pkgdata = Revise.pkgdatas[id]
            sf = Revise.srcfiles(pkgdata)
            @test count(name->occursin("@require", name), sf) == 1
            @test count(name->occursin("anotherfile", name), sf) == 1
            @test !any(isequal("."), sf)
            idx = findfirst(name->occursin("anotherfile", name), sf)
            @test !isabspath(sf[idx])
        end
    end
    @test_throws UndefVarError TrackRequires.fauto()
    @eval using UnsafeArrays
    sleep(2)  # allow time for the @async in all @require blocks to finish
    if notified
        @test TrackRequires.fauto() == 1
        id = Base.PkgId(TrackRequires)
        pkgdata = Revise.pkgdatas[id]
        sf = Revise.srcfiles(pkgdata)
        @test count(name->occursin("@require", name), sf) == 1
        @test count(name->occursin("yetanotherfile", name), sf) == 1
        @test !any(isequal("."), sf)
        idx = findfirst(name->occursin("yetanotherfile", name), sf)
        @test !isabspath(sf[idx])
    end

    # Ensure it also works if the Requires dependency is pre-loaded
    dn = joinpath(testdir, "TrackRequires2", "src")
    mkpath(dn)
    write(joinpath(dn, "TrackRequires2.jl"), """
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
    write(joinpath(dn, "testfile.jl"), "testfunc() = 1")
    write(joinpath(dn, "testfile2.jl"), "othertestfunc() = -1")
    sleep(mtimedelay)
    @eval using TrackRequires2
    sleep(mtimedelay)
    notified && @test TrackRequires2.testfunc() == 1
    @test_throws UndefVarError TrackRequires2.othertestfunc()
    write(joinpath(dn, "testfile.jl"), "testfunc() = 2")
    yry()
    notified && @test TrackRequires2.testfunc() == 2
    @test_throws UndefVarError TrackRequires2.othertestfunc()
    @eval using MappedArrays
    @test TrackRequires2.othertestfunc() == -1
    sleep(mtimedelay)
    write(joinpath(dn, "testfile2.jl"), "othertestfunc() = -2")
    yry()
    notified && @test TrackRequires2.othertestfunc() == -2

    # Issue #442
    push!(LOAD_PATH, joinpath(@__DIR__, "pkgs"))
    @eval using Pkg442
    sleep(0.01)
    @test check442()
    @test Pkg442.check442A()
    @test Pkg442.check442B()
    @test Pkg442.Dep442B.has442A()
    pop!(LOAD_PATH)

    rm_precompile("TrackRequires")
    rm_precompile("TrackRequires2")
    pop!(LOAD_PATH)
end

do_test("entr") && @testset "entr" begin
    srcfile1 = joinpath(tempdir(), randtmp()*".jl"); push!(to_remove, srcfile1)
    srcfile2 = joinpath(tempdir(), randtmp()*".jl"); push!(to_remove, srcfile2)
    revise(throw=true)   # force compilation
    write(srcfile1, "Core.eval(Main, :(__entr__ = 1))")
    touch(srcfile2)
    Core.eval(Main, :(__entr__ = 0))
    sleep(mtimedelay)
    try
        @sync begin
            @test Main.__entr__ == 0

            @async begin
                entr([srcfile1, srcfile2]; pause=0.5) do
                    include(srcfile1)
                end
            end
            sleep(1)
            @test Main.__entr__ == 1  # callback should have been run (postpone=false)

            # File modification
            write(srcfile1, "Core.eval(Main, :(__entr__ = 2))")
            sleep(1)
            @test Main.__entr__ == 2  # callback should have been called

            # Two events in quick succession (w.r.t. the `pause` argument)
            write(srcfile1, "Core.eval(Main, :(__entr__ += 1))")
            sleep(0.1)
            touch(srcfile2)
            sleep(1)
            @test Main.__entr__ == 3  # callback should have been called only once


            write(srcfile1, "error(\"stop\")")
            sleep(mtimedelay)
        end
        @test false
    catch err
        while err isa CompositeException
            err = err.exceptions[1]
            if err isa TaskFailedException
                err = err.task.exception
            end
            if err isa CapturedException
                err = err.ex
            end
        end
        @test isa(err, LoadError)
        @test err.error.msg == "stop"
    end

    # Callback should have been removed
    @test isempty(Revise.user_callbacks_by_file[srcfile1])


    # Watch directories (#470)
    try
        @sync let
            srcdir = joinpath(tempdir(), randtmp())
            mkdir(srcdir)

            trigger = joinpath(srcdir, "trigger.txt")

            counter = Ref(0)
            stop = Ref(false)

            @async begin
                entr([srcdir]; pause=0.5) do
                    counter[] += 1
                    stop[] && error("stop watching directory")
                end
            end
            sleep(1)
            @test length(readdir(srcdir)) == 0 # directory should still be empty
            @test counter[] == 1               # postpone=false

            # File creation
            touch(trigger)
            sleep(1)
            @test counter[] == 2

            # File modification
            touch(trigger)
            sleep(1)
            @test counter[] == 3

            # File deletion -> the directory should be empty again
            rm(trigger)
            sleep(1)
            @test length(readdir(srcdir)) == 0
            @test counter[] == 4

            # Two events in quick succession (w.r.t. the `pause` argument)
            touch(trigger)       # creation
            sleep(0.1)
            touch(trigger)       # modification
            sleep(1)
            @test counter[] == 5 # Callback should have been called only once

            # Stop
            stop[] = true
            touch(trigger)
        end

        # `entr` should have errored by now
        @test false
    catch err
        while err isa CompositeException
            err = err.exceptions[1]
            if err isa TaskFailedException
                err = err.task.exception
            end
            if err isa CapturedException
                err = err.ex
            end
        end
        @test isa(err, ErrorException)
        @test err.msg == "stop watching directory"
    end
end

const A354_result = Ref(0)

# issue #354
do_test("entr with modules") && @testset "entr with modules" begin

    testdir = newtestdir()
    modname = "A354"
    srcfile = joinpath(testdir, modname * ".jl")

    setvalue(x) = write(srcfile, "module $modname test() = $x end")

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

# issue #469
do_test("entr with all files") && @testset "entr with all files" begin
    testdir = newtestdir()
    modname = "A469"
    srcfile = joinpath(testdir, modname * ".jl")
    write(srcfile, "module $modname test() = 469 end")

    sleep(mtimedelay)
    @eval using A469
    sleep(mtimedelay)
    result = Ref(0)

    try
        @sync begin
            @async begin
                # Watch all files known to Revise
                # (including `srcfile`)
                entr([]; all=true, postpone=true) do
                    result[] = 1
                    error("stop")
                end
            end
            sleep(mtimedelay)
            @test result[] == 0

            # Trigger the callback
            touch(srcfile)
        end
        @test false
    catch err
        while err isa CompositeException
            err = err.exceptions[1]
            if err isa TaskFailedException
                err = err.task.exception
            end
            if err isa CapturedException
                err = err.ex
            end
        end
        @test isa(err, ErrorException)
        @test err.msg == "stop"
    end

    # If we got to this point, the callback should have been triggered. But
    # let's check nonetheless
    @test result[] == 1

    rm_precompile(modname)
end

do_test("callbacks") && @testset "callbacks" begin

    append(path, x...) = open(path, append=true) do io
        write(io, x...)
    end

    mktemp() do path, _
        contents = Ref("")
        key = Revise.add_callback([path]) do
            contents[] = read(path, String)
        end

        sleep(mtimedelay)

        append(path, "abc")
        sleep(mtimedelay)
        revise()
        @test contents[] == "abc"

        sleep(mtimedelay)

        append(path, "def")
        sleep(mtimedelay)
        revise()
        @test contents[] == "abcdef"

        Revise.remove_callback(key)
        sleep(mtimedelay)

        append(path, "ghi")
        sleep(mtimedelay)
        revise()
        @test contents[] == "abcdef"
    end

    testdir = newtestdir()
    modname = "A355"
    srcfile = joinpath(testdir, modname * ".jl")

    setvalue(x) = write(srcfile, "module $modname test() = $x end")

    setvalue(1)

    sleep(mtimedelay)
    @eval using A355
    sleep(mtimedelay)

    A355_result = Ref(0)

    Revise.add_callback([], [A355]) do
        A355_result[] = A355.test()
    end

    sleep(mtimedelay)
    setvalue(2)
    # belt and suspenders -- make sure we trigger entr:
    sleep(mtimedelay)
    touch(srcfile)

    yry()

    @test A355_result[] == 2

    rm_precompile(modname)

    # Issue 574 - ad-hoc revision of a file, combined with add_callback()
    A574_path = joinpath(testdir, "A574.jl")

    set_foo_A574(x) = write(A574_path, "foo_574() = $x")

    set_foo_A574(1)
    includet(@__MODULE__, A574_path)
    @test Base.invokelatest(foo_574) == 1

    foo_A574_result = Ref(0)
    key = Revise.add_callback([A574_path]) do
        foo_A574_result[] = foo_574()
    end

    sleep(mtimedelay)
    set_foo_A574(2)
    sleep(mtimedelay)
    revise()
    @test Base.invokelatest(foo_574) == 2
    @test foo_A574_result[] == 2

    Revise.remove_callback(key)

    sleep(mtimedelay)
    set_foo_A574(3)
    sleep(mtimedelay)
    revise()
    @test Base.invokelatest(foo_574) == 3
    @test foo_A574_result[] == 2 # <- callback removed - no longer updated
end

do_test("includet with mod arg (issue #689)") && @testset "includet with mod arg (issue #689)" begin
    testdir = newtestdir()

    common = joinpath(testdir, "common.jl")
    write(common, """
        module Common
            const foo = 2
        end
        """)

    routines = joinpath(testdir, "routines.jl")
    write(routines, """
        module Routines
            using Revise
            includet(@__MODULE__, raw"$common")
            using .Common
        end
        """)

    codes = joinpath(testdir, "codes.jl")
    write(codes, """
        module Codes
            using Revise
            includet(@__MODULE__, raw"$common")
            using .Common
        end
        """)

    driver = joinpath(testdir, "driver.jl")
    write(driver, """
        module Driver
            using Revise
            includet(@__MODULE__, raw"$routines")
            using .Routines
            includet(@__MODULE__, raw"$codes")
            using .Codes
        end
        """)

    includet(@__MODULE__, driver)
    @test parentmodule(Driver.Routines.Common) == Driver.Routines
    @test Base.moduleroot(Driver.Routines.Common) == Main

    @test parentmodule(Driver.Codes.Common) == Driver.Codes
    @test Base.moduleroot(Driver.Codes.Common) == Main

    @test Driver.Routines.Common.foo == 2
    @test Driver.Codes.Common.foo == 2
end

do_test("misc - coverage") && @testset "misc - coverage" begin
    @test Revise.ReviseEvalException("undef", UndefVarError(:foo)).loc isa String
    @test !Revise.throwto_repl(UndefVarError(:foo))

    @test endswith(Revise.fallback_juliadir(), "julia")

    @test isnothing(Revise.revise(REPL.REPLBackend()))
end

do_test("deprecated") && @testset "deprecated" begin
    @test_logs (:warn, r"`steal_repl_backend` has been removed.*") Revise.async_steal_repl_backend()
    @test_logs (:warn, r"`steal_repl_backend` has been removed.*") Revise.wait_steal_repl_backend()
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
        msg = Revise.watching_files[] ? "is not an existing file" : "is not an existing directory"
        isempty(ARGS) && !Sys.isapple() && @test occursin(msg, read(warnfile, String))
        rm(warnfile)
    end
end

GC.gc(); GC.gc(); GC.gc()   # work-around for https://github.com/JuliaLang/julia/issues/28306

# see #532 Fix InitError opening none existent Project.toml
function load_in_empty_project_test()
    # This will try to load Revise in a julia seccion
    # with an empty environment (missing Project.toml)

    julia = Base.julia_cmd()
    revise_proj = escape_string(Base.active_project())
    @assert isfile(revise_proj)

    src = """
    import Pkg
    Pkg.activate("fake_env")
    @assert !isfile(Base.active_project())

    # force to load the package env Revise version
    empty!(LOAD_PATH)
    push!(LOAD_PATH, "$revise_proj")

    @info "A warning about no Manifest.toml file found is expected"
    try; using Revise
        catch err
            # just fail for this error (see #532)
            err isa InitError && rethrow(err)
    end
    """
    cmd = `$julia --project=@. -E $src`

    @test begin
        wait(run(cmd))
        true
    end
end

do_test("Import in empty environment (issue #532)") && @testset "Import in empty environment (issue #532)" begin
    load_in_empty_project_test();
end

include("backedges.jl")

include("non_jl_test.jl")

do_test("Base signatures") && @testset "Base signatures" begin
    println("beginning signatures tests")
    # Using the extensive repository of code in Base as a testbed
    include("sigtest.jl")
end
