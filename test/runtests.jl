using Revise
using Test

@test isempty(detect_ambiguities(Revise, Base, Core))

using Pkg, Unicode, Distributed, InteractiveUtils, REPL
import LibGit2
using OrderedCollections: OrderedSet
using Test: collect_test_logs
using Base.CoreLogging: Debug,Info

include("common.jl")

to_remove = String[]

throwing_function(bt) = bt[2]

function rm_precompile(pkgname::AbstractString)
    filepath = Base.cache_file_entry(Base.PkgId(pkgname))
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

function compare_sigs(ex, typex)
    mod = private_module()
    f = Core.eval(mod, ex)
    mths = methods(f)
    for (m, tex) in zip(mths, typex)
        t = Core.eval(mod, tex)
        @test m.sig == t
    end
end

function compare_sigs(ex)
    sig = Revise.get_signature(ex)
    typex = sig_type_exprs(sig)
    compare_sigs(ex, typex)
end

module PlottingDummy
using RecipesBase
struct PlotDummy end
end

sig_type_exprs(ex) = Revise.sig_type_exprs(Main, ex)   # just for testing purposes

@testset "Revise" begin

    function collectexprs(ex::Revise.RelocatableExpr)
        exs = Revise.RelocatableExpr[]
        for item in Revise.LineSkippingIterator(ex.args)
            push!(exs, item)
        end
        exs
    end

    function get_docstring(ds)
        docstr = ds.content[1]
        while !isa(docstr, AbstractString)
            docstr = docstr.content[1]
        end
        return docstr
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
        @test string(ex) == """
quote
    f(x) = begin
            x ^ 2
        end
    g(x) = begin
            sin(x)
        end
end"""
    end

    @testset "Parse errors" begin
        warnfile = randtmp()
        open(warnfile, "w") do io
            redirect_stderr(io) do
                md = Revise.FileModules(Main)
                @test Revise.parse_source!(md, """
begin # this block should parse correctly, cf. issue #109

end
f(x) = 1
g(x) = 2
h{x) = 3  # error
k(x) = 4
""",
                                            :test, 1, Main) == nothing
                @test haskey(md[Main].defmap, convert(Revise.RelocatableExpr, :(g(x) = 2)))
            end
        end
        @test occursin("parsing error near line 6", read(warnfile, String))
        rm(warnfile)
        @test Revise.is_linenumber(LineNumberNode(5, "foo.jl"))  # issue #100
    end

    @testset "Methods and signatures" begin
        compare_sigs(:(foo(x) = 1))
        compare_sigs(:(foo(x::Int) = 1))
        # where signatures
        compare_sigs(:(foo(x::T) where T<:Integer = T))
        compare_sigs(:(foo(x::V) where V<:Array{T} where T = T))
        # Varargs
        compare_sigs(:(foo(x::Int, y...) = 1))
        compare_sigs(:(foo(x::Int, y::Symbol...) = 1))
        compare_sigs(:(foo(x::T, y::U...) where {T<:Integer,U} = U))
        compare_sigs(:(foo(x::Array{Float64,K}, y::Vararg{Symbol,K}) where K = K))
        # Default args
        compare_sigs(:(foo(x, y=0) = 1))
        compare_sigs(:(foo(x, y::Int=0) = 1))
        compare_sigs(:(foo(x, y="hello", z::Int=0) = 1))
        compare_sigs(:(foo(x::Array{Float64,K}, y::Int=0) where K = K))
        # Keyword args
        compare_sigs(:(foo(x; y=0) = 1))
        compare_sigs(:(foo(x; y::Int=0) = 1))
        compare_sigs(:(foo(x; y="hello", z::Int=0) = 1))
        compare_sigs(:(foo(x::Array{Float64,K}; y::Int=0) where K = K))
        # Default and keyword args
        compare_sigs(:(foo(x, y="hello"; z::Int=0) = 1))
        # Destructured args
        compare_sigs(:(foo(x, (count, name)) = 1))

        # Do it all again for long-form declarations
        compare_sigs(:(function foo(x) return 1 end))
        compare_sigs(:(function foo(x::Int) return 1 end))
        # where signatures
        compare_sigs(:(function foo(x::T) where T<:Integer return T end))
        compare_sigs(:(function foo(x::V) where V<:Array{T} where T return T end))
        # Varargs
        compare_sigs(:(function foo(x::Int, y...) return 1 end))
        compare_sigs(:(function foo(x::Int, y::Symbol...) return 1 end))
        compare_sigs(:(function foo(x::T, y::U...) where {T<:Integer,U} return U end))
        compare_sigs(:(function foo(x::Array{Float64,K}, y::Vararg{Symbol,K}) where K return K end))
        # Default args
        compare_sigs(:(function foo(x, y=0) return 1 end))
        compare_sigs(:(function foo(x, y::Int=0) return 1 end))
        compare_sigs(:(function foo(x, y="hello", z::Int=0) return 1 end))
        compare_sigs(:(function foo(x::Array{Float64,K}, y::Int=0) where K return K end))
        # Keyword args
        compare_sigs(:(function foo(x; y=0) return 1 end))
        compare_sigs(:(function foo(x; y::Int=0) return 1 end))
        compare_sigs(:(function foo(x; y="hello", z::Int=0) return 1 end))
        compare_sigs(:(function foo(x::Array{Float64,K}; y::Int=0) where K return K end))
        # Default and keyword args
        compare_sigs(:(function foo(x, y="hello"; z::Int=0) return 1 end))
        # Destructured args
        compare_sigs(:(function foo(x, (count, name)) return 1 end))

        Typeof = Core.Typeof

        # Return type annotations
        @test sig_type_exprs(:(typeinfo_eltype(typeinfo::Type)::Union{Type,Nothing})) ==
              sig_type_exprs(:(typeinfo_eltype(typeinfo::Type)))
        def = quote
            function +(x::Bool, y::T)::promote_type(Bool,T) where T<:AbstractFloat
                return ifelse(x, oneunit(y) + y, y)
            end
        end
        sig = Revise.get_signature(Revise.funcdef_expr(def))
        @test sig_type_exprs(sig) == [:(Tuple{$Typeof(+), Bool, T} where T<:AbstractFloat)]

        # Overloading call
        def = :((i::Inner)(::String) = i.x)
        sig = Revise.get_signature(def)
        sigexs = sig_type_exprs(sig)
        Core.eval(ReviseTestPrivate, def)
        i = ReviseTestPrivate.Inner(3)
        m = @which i("hello")
        @test Core.eval(ReviseTestPrivate, sigexs[1]) == m.sig
        def = :((::Type{Inner})(::Dict) = 17)
        sig = Revise.get_signature(def)
        sigexs = sig_type_exprs(sig)
        Core.eval(ReviseTestPrivate, def)
        m = @which ReviseTestPrivate.Inner(Dict("a"=>1))
        @test Core.eval(ReviseTestPrivate, sigexs[1]) == m.sig

        # Annotations
        refex =  Revise.relocatable!(:(function foo(x) x^2 end))
        for ex in (:(@inline function foo(x) x^2 end),
                   :(@noinline function foo(x) x^2 end),
                   :(@propagate_inbounds function foo(x) x^2 end))
            @test Revise.get_signature(Revise.funcdef_expr(ex)) == :(foo(x))
            @test Revise.relocatable!(Revise.funcdef_expr(ex)) == refex
        end

        # @eval-defined methods
        ex = :(@eval getindex(A::Array, i1::Int, i2::Int, I::Int...) = (@_inline_meta; arrayref($(Expr(:boundscheck)), A, i1, i2, I...)))
        @test Revise.get_signature(Revise.funcdef_expr(ex)) == :(getindex(A::Array, i1::Int, i2::Int, I::Int...))
        @test Revise.relocatable!(Revise.funcdef_expr(ex)) == Revise.relocatable!(
            :(getindex(A::Array, i1::Int, i2::Int, I::Int...) = (@_inline_meta; arrayref($(Expr(:boundscheck)), A, i1, i2, I...)))
            )

        # empty keywords (issue #171)
        @test sig_type_exprs(:(ekwrds(x::Int;))) == [:(Tuple{$Typeof(ekwrds), Int})]

        # arg-modifying macros (issue #176)
        sigexs = Revise.sig_type_exprs(ReviseTestPrivate, :(foo(x::String, @addint(y), @addint(z))))
        @test sigexs == [:(Tuple{$Typeof(foo), String, $Int, $Int})]

        # modules with submodules named `Core` (issue #199)
        @test Core.eval(ReviseTestPrivate.A, Revise.sig_type_exprs(ReviseTestPrivate.A, :(f(x::Int)))[1]) ==
            Tuple{typeof(ReviseTestPrivate.A.f),Int}
        @test Core.eval(ReviseTestPrivate.B, Revise.sig_type_exprs(ReviseTestPrivate.B, :(f(x::Int)))[1]) ==
            Tuple{typeof(ReviseTestPrivate.B.f),Int}
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

        oldmd = Revise.parse_source(tmpfile, Main)
        Revise.instantiate_sigs!(oldmd)

        cp(fl2, tmpfile; force=true)
        newmd = Revise.parse_source(tmpfile, Main)
        revmd = Revise.eval_revised(newmd, oldmd)
        @test ReviseTest.cube(2) == 8
        @test ReviseTest.Internal.mult3(2) == 6

        @test length(revmd) == 3
        @test haskey(revmd, ReviseTest) && haskey(revmd, ReviseTest.Internal)

        dvs = collect(revmd[ReviseTest].defmap)
        @test length(dvs) == 3
        (def, val) = dvs[1]
        @test isequal(def,  Revise.relocatable!(:(square(x) = x^2)))
        @test val == (DataType[Tuple{typeof(ReviseTest.square),Any}], 0)
        @test Revise.firstlineno(def) == 5
        m = @which ReviseTest.square(1)
        @test m.line == 5
        @test revmd[ReviseTest].sigtmap[Tuple{typeof(ReviseTest.square),Any}] == def
        (def, val) = dvs[2]
        @test isequal(def, Revise.relocatable!(:(cube(x) = x^3)))
        @test val == (DataType[Tuple{typeof(ReviseTest.cube),Any}], 0)
        m = @which ReviseTest.cube(1)
        @test m.line == 7
        @test revmd[ReviseTest].sigtmap[Tuple{typeof(ReviseTest.cube),Any}] == def
        (def, val) = dvs[3]
        @test isequal(def, Revise.relocatable!(:(fourth(x) = x^4)))
        @test val == (DataType[Tuple{typeof(ReviseTest.fourth),Any}], 0)
        m = @which ReviseTest.fourth(1)
        @test m.line == 9
        @test revmd[ReviseTest].sigtmap[Tuple{typeof(ReviseTest.fourth),Any}] == def

        dvs = collect(revmd[ReviseTest.Internal].defmap)
        @test length(dvs) == 5
        (def, val) = dvs[1]
        @test isequal(def,  Revise.relocatable!(:(mult2(x) = 2*x)))
        @test val == (DataType[Tuple{typeof(ReviseTest.Internal.mult2),Any}], 2)  # 2 because it shifted down 2 lines and was not evaled
        @test Revise.firstlineno(def) == 11
        m = @which ReviseTest.Internal.mult2(1)
        @test m.line == 11
        @test revmd[ReviseTest.Internal].sigtmap[Tuple{typeof(ReviseTest.Internal.mult2),Any}] == def
        (def, val) = dvs[2]
        @test isequal(def, Revise.relocatable!(:(mult3(x) = 3*x)))
        @test val == (DataType[Tuple{typeof(ReviseTest.Internal.mult3),Any}], 0)  # 0 because it was freshly-evaled
        m = @which ReviseTest.Internal.mult3(1)
        @test m.line == 14
        @test revmd[ReviseTest.Internal].sigtmap[Tuple{typeof(ReviseTest.Internal.mult3),Any}] == def

        @test_throws MethodError ReviseTest.Internal.mult4(2)

        function cmpdiff(record, msg; kwargs...)
            record.message == msg
            for (kw, val) in kwargs
                @test record.kwargs[kw] == val
            end
            return nothing
        end
        logs = filter(r->r.level==Debug && r.group=="Action", rlogger.logs)
        @test length(logs) == 7
        cmpdiff(logs[1], "Eval"; deltainfo=(ReviseTest, Revise.relocatable!(:(cube(x) = x^3))))
        cmpdiff(logs[2], "Eval"; deltainfo=(ReviseTest, Revise.relocatable!(:(fourth(x) = x^4))))
        cmpdiff(logs[3], "DeleteMethod"; deltainfo=(Tuple{typeof(ReviseTest.Internal.mult4),Any}, MethodSummary(delmeth)))
        cmpdiff(logs[4], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.mult2),Any}], 13, 0 => 2))
        cmpdiff(logs[5], "Eval"; deltainfo=(ReviseTest.Internal, Revise.relocatable!(:(mult3(x) = 3*x))))
        cmpdiff(logs[6], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.unchanged),Any}], 19, 0 => 1))
        cmpdiff(logs[7], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.unchanged2),Any}], 21, 0 => 1))
        @test length(Revise.actions(rlogger)) == 4  # by default LineOffset is skipped
        @test length(Revise.actions(rlogger; line=true)) == 7
        @test length(Revise.diffs(rlogger)) == 2
        empty!(rlogger.logs)

        # Backtraces
        cp(fl3, tmpfile; force=true)
        newmd = Revise.parse_source(tmpfile, Main)
        revmd = Revise.eval_revised(newmd, revmd)
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
        @test length(logs) == 2
        cmpdiff(logs[1], "Eval"; deltainfo=(ReviseTest, Revise.relocatable!(:(cube(x) = error("cube")))))
        cmpdiff(logs[2], "Eval"; deltainfo=(ReviseTest.Internal, Revise.relocatable!(:(mult2(x) = error("mult2")))))

        # Turn off future logging
        Revise.debug_logger(; min_level=Info)

        # Gensymmed symbols
        rex1 = Revise.relocatable!(macroexpand(Main, :(t = @elapsed(foo(x)))))
        rex2 = Revise.relocatable!(macroexpand(Main, :(t = @elapsed(foo(x)))))
        @test isequal(rex1, rex2)
        @test hash(rex1) == hash(rex2)
        rex3 = Revise.relocatable!(macroexpand(Main, :(t = @elapsed(bar(x)))))
        @test !isequal(rex1, rex3)
        @test hash(rex1) != hash(rex3)
        sym1, sym2 = gensym(:hello), gensym(:hello)
        rex1 = Revise.relocatable!(:(x = $sym1))
        rex2 = Revise.relocatable!(:(x = $sym2))
        @test isequal(rex1, rex2)
        @test hash(rex1) == hash(rex2)
        sym3 = gensym(:world)
        rex3 = Revise.relocatable!(:(x = $sym3))
        @test isequal(rex1, rex3)
        @test hash(rex1) == hash(rex3)
    end

    @testset "Macro parsing" begin
        # issues Revise#148, Rebugger#3
        fm = Revise.FileModules(PlottingDummy)
        Revise.parse_expr!(fm, :(@recipe function f(pd::PlotDummy) -55 end), Symbol("dummyfile.jl"), PlottingDummy)
        def, sigex = first(fm[PlottingDummy].defmap)
        gr = GlobalRef(PlottingDummy.RecipesBase, :RecipesBase)
        @test convert(Expr, sigex) == :($gr.apply_recipe(plotattributes::Dict{Symbol, Any}, pd::PlotDummy))

        # macros that return a non-expression
        fm = Revise.FileModules(ReviseTestPrivate)
        Revise.parse_expr!(fm, :(@changeto1 function f(x) -55 end), Symbol("dummyfile.jl"), ReviseTestPrivate)
        @test isempty(fm[ReviseTestPrivate].defmap)

        # ensure that @doc doesn't trigger macro expansion in the body
        ex = quote
            """
            Some docstring
            """
            function foo(x)
                if x < 0
                    @warn "$x is negative"
                end
                return x
            end
        end
        mod = private_module()
        fm = Revise.FileModules(mod)
        Revise.parse_expr!(fm, ex, Symbol("dummyfile.jl"), mod)
        fmm = fm[mod]
        rex, sig = first(fmm.defmap)
        @test occursin("@warn", string(rex))

        # test that combination of docstring and performance annotations doesn't skip signatures
        ex = quote
            """
            An @inlined function with a docstring
            """
            @inline foo(x::Float16) = 1
        end
        mod = private_module()
        fm = Revise.FileModules(mod)
        Revise.parse_expr!(fm, ex, Symbol("dummyfile.jl"), mod)
        Core.eval(mod, :(foo(x::Float16) = 2))
        Revise.instantiate_sigs!(fm)
        @test haskey(fm[mod].sigtmap, Tuple{typeof(getfield(mod, :foo)), Float16})
    end

    @testset "Display" begin
        io = IOBuffer()
        show(io, Revise.relocatable!(:(@inbounds x[2])))
        str = String(take!(io))
        @test str == ":(@inbounds x[2])"
        fm = Revise.parse_source(joinpath(@__DIR__, "revisetest.jl"), Main)
        Revise.instantiate_sigs!(fm)
        @test string(fm) == "OrderedCollections.OrderedDict(Main=>FMMaps(<1 expressions>, <0 signatures>),Main.ReviseTest=>FMMaps(<2 expressions>, <2 signatures>),Main.ReviseTest.Internal=>FMMaps(<6 expressions>, <5 signatures>))"
        fmmr = fm[ReviseTest]
        @test string(fmmr) == "FMMaps(<2 expressions>, <2 signatures>)"
        io = IOBuffer()
        print(IOContext(io, :limit=>false), fmmr)
        str = String(take!(io))
        @test str == "FMMaps with the following expressions:\n  :(square(x) = begin\n          x ^ 2\n      end)\n  :(cube(x) = begin\n          x ^ 4\n      end)\n"
    end

    @testset "File paths" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        for (pcflag, fbase) in ((true, "pc"), (false, "npc"))  # precompiled & not
            modname = uppercase(fbase)
            pcexpr = pcflag ? :() : :(__precompile__(false))
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
            sleep(2.1)   # so the defining files are old enough not to trigger mtime criterion
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
            m = @eval first(methods($fn1))
            ex = Revise.get_def(m)
            @test ex == convert(Revise.RelocatableExpr, :( $fn1() = 1 ))
            # Check that get_def returns copies
            ex2 = deepcopy(ex)
            ex.args[end].args[end] = 2
            @test Revise.get_def(m) == ex2
            @test Revise.get_def(m) != ex
            sleep(0.1)  # to ensure that the file watching has kicked in
            # Change the definition of function 1 (easiest to just rewrite the whole file)
            open(joinpath(dn, modname*".jl"), "w") do io
                println(io, """
$pcexpr
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
            sleep(0.1)
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
                @test haskey(pkgdata.fileinfos, file)
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
        sleep(2.1)
        @eval using Mysupermodule
        @test Mysupermodule.Mymodule.func() == 1
        sleep(1.1)
        yry()
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
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using LoopInclude
        sleep(0.1) # to ensure file-watching is set up
        @test li_f() == 1
        @test li_g() == 2
        sleep(1.1)  # ensure watching is set up
        yry()
        open(joinpath(dn, "file1.jl"), "w") do io
            println(io, "li_f() = -1")
        end
        yry()
        @test li_f() == -1
        rm_precompile("LoopInclude")

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

    # issue #36
    @testset "@__FILE__" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "ModFILE", "src")
        mkpath(dn)
        open(joinpath(dn, "ModFILE.jl"), "w") do io
            println(io, """
module ModFILE

mf() = @__FILE__, 1

end
""")
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using ModFILE
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 1)
        sleep(0.1)
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
        testdir = randtmp()
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
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using ModDocstring
        sleep(2)
        @test ModDocstring.f() == 1
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Ahoy! "

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
        oldmd = Revise.parse_source(fn, Base)
        newmd = Revise.parse_source(fn, Base)
        odict = oldmd[Base].defmap
        ndict = newmd[Base].defmap
        for (k, v) in odict
            @test haskey(ndict, k)
        end
    end

    # issue #165
    @testset "Changing @inline annotations" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
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
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using PerfAnnotations
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
        sleep(0.1)
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

        # Check nesting
        ex = :(@propagate_inbounds @donothing @inline foo(x) = 1)
        ex0, ex1 = Revise.relocatable!.(Revise.macexpand(ReviseTestPrivate, ex))
        @test ex0 == Revise.relocatable!(:(@propagate_inbounds foo(x) = ($(Expr(:meta, :inline)); 1)))
        @test ex1 == Revise.relocatable!(:(foo(x) = ($(Expr(:meta, :inline)); 1)))
        @test Revise.get_signature(ex1) == Revise.relocatable!(:(foo(x)))
        ex = :(@propagate_inbounds @inline @donothing foo(x) = 1)
        ex0, ex1 = Revise.relocatable!.(Revise.macexpand(ReviseTestPrivate, ex))
        @test ex0 == Revise.relocatable!(:(@propagate_inbounds @inline foo(x) = 1))
        @test ex1 == Revise.relocatable!(:(foo(x) = 1))
        @test Revise.get_signature(ex1) == Revise.relocatable!(:(foo(x)))
        pop!(LOAD_PATH)
    end

    @testset "Revising macros" begin
        # issue #174
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
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
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using MacroRevision
        @test MacroRevision.foo("hello") == 1

        sleep(0.1)
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

        sleep(0.1)
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
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
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
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using ArgModMacros
        @test ArgModMacros.hyper_loglikelihood((μ=1, σ=2, LΩ=3), (w̃s=4, α̃s=5, β̃s=6)) == [4,5,6]
        @test ArgModMacros.revision[] == 1
        sleep(0.1)
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
        testdir = randtmp()
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
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
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
        rm_precompile("LineNumberMod")
        pop!(LOAD_PATH)
    end

    # Issue #43
    @testset "New submodules" begin
        testdir = randtmp()
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
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
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
        rm_precompile("Submodules")
        pop!(LOAD_PATH)
    end

    @testset "Method deletion" begin
        Core.eval(Base, :(revisefoo(x::Float64) = 1)) # to test cross-module method scoping
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
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

end
""")
        end
        @eval using MethDel
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
        sleep(0.1)  # ensure watching is set up
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

        Base.delete_method(first(methods(Base.revisefoo)))
    end

    @testset "get_def" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "GetDef", "src")
        mkpath(dn)
        open(joinpath(dn, "GetDef.jl"), "w") do io
            println(io, """
            module GetDef

            f(x) = 1
            f(v::AbstractVector) = 2
            f(v::AbstractVector{<:Integer}) = 3

            end
            """)
        end
        @eval using GetDef
        @test GetDef.f(1.0) == 1
        @test GetDef.f([1.0]) == 2
        @test GetDef.f([1]) == 3
        m = @which GetDef.f([1])
        ex = Revise.get_def(m)
        @test ex isa Revise.RelocatableExpr
        @test isequal(ex, Revise.relocatable!(:(f(v::AbstractVector{<:Integer}) = 3)))

        rm_precompile("GetDef")
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
        includet(srcfile)
        @test revise_f(10) == 1
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
        srcfile = randtmp()*".jl"
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
    end

    @testset "Auto-track user scripts" begin
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        push!(to_remove, srcfile)
        open(srcfile, "w") do io
            println(io, "revise_g() = 1")
        end
        # By default user scripts are not tracked
        include(srcfile)
        yry()
        @test revise_g() == 1
        sleep(0.1)
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
            include(srcfile)
            yry()
            @test revise_g() == 1
            sleep(0.1)
            open(srcfile, "w") do io
                println(io, "revise_g() = 2")
            end
            yry()
            @test revise_g() == 2
        finally
            Revise.tracking_Main_includes[] = false  # restore old behavior
        end
    end

    @testset "Distributed" begin
        allworkers = [myid(); addprocs(2)]
        @everywhere using Revise
        dirname = randtmp()
        mkdir(dirname)
        @everywhere push_LOAD_PATH!(dirname) = push!(LOAD_PATH, dirname)
        for p in allworkers
            remotecall_wait(push_LOAD_PATH!, p, dirname)
        end
        push!(to_remove, dirname)
        modname = "ReviseDistributed"
        dn = joinpath(dirname, modname, "src")
        mkpath(dn)
        open(joinpath(dn, modname*".jl"), "w") do io
            println(io, """
module ReviseDistributed

f() = π
g(::Int) = 0

end
""")
        end
        sleep(2.1)   # so the defining files are old enough not to trigger mtime criterion
        using ReviseDistributed
        @everywhere using ReviseDistributed
        for p in allworkers
            @test remotecall_fetch(ReviseDistributed.f, p)    == π
            @test remotecall_fetch(ReviseDistributed.g, p, 1) == 0
        end
        sleep(0.1)
        open(joinpath(dn, modname*".jl"), "w") do io
            println(io, """
module ReviseDistributed

f() = 3.0

end
""")
        end
        yry()
        sleep(1.0)
        @test_throws MethodError ReviseDistributed.g(1)
        for p in allworkers
            @test remotecall_fetch(ReviseDistributed.f, p)    == 3.0
            p == myid() && continue
            @test_throws RemoteException remotecall_fetch(ReviseDistributed.g, p, 1)
        end
        rmprocs(allworkers[2:3]...; waitfor=10)
        rm_precompile("ReviseDistributed")
        pop!(LOAD_PATH)
    end

    @testset "Git" begin
        if haskey(ENV, "CI")   # if we're doing CI testing (Travis, Appveyor, etc.)
            # First do a full git checkout of a package (we'll use Revise itself)
            @warn "checking out a development copy of Revise for testing purposes"
            pkg = Pkg.develop("Revise")
        end
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
            @eval using $(Symbol(modname))
            mod = @eval $(Symbol(modname))
            # id = Base.PkgId(mod)
            id = Base.PkgId(Main)
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
            repo = LibGit2.GitRepo(randdir)
            LibGit2.add!(repo, joinpath("src", "extra.jl"))
            logs, _ = Test.collect_test_logs() do
                Revise.track_subdir_from_git(id, joinpath(randdir, "src"); commit="HEAD")
            end
            @test haskey(Revise.pkgdatas[id].fileinfos, mainjl)
            @test startswith(logs[1].message, "skipping src/extra.jl")
            rm_precompile("ModuleWithNewFile")
            pop!(LOAD_PATH)
        end
    end

    @testset "Recipes" begin
        # Tracking Base
        Revise.track(Base)
        id = Base.PkgId(Base)
        pkgdata = Revise.pkgdatas[id]
        @test any(k->endswith(k, "number.jl"), keys(pkgdata.fileinfos))
        @test length(filter(k->endswith(k, "file.jl"), keys(pkgdata.fileinfos))) == 2
        m = @which show([1,2,3])
        @test Revise.get_def(m) isa Revise.RelocatableExpr

        # Determine whether a git repo is available. Travis & Appveyor do not have this.
        repo, path = Revise.git_repo(Revise.juliadir)
        if repo != nothing
            # Tracking Core.Compiler
            Revise.track(Core.Compiler)
            id = Base.PkgId(Core.Compiler)
            pkgdata = Revise.pkgdatas[id]
            @test any(k->endswith(k, "compiler.jl"), keys(pkgdata.fileinfos))
            m = first(methods(Core.Compiler.typeinf_code))
            @test Revise.get_def(m) isa Revise.RelocatableExpr

            # Tracking stdlibs
            Revise.track(Unicode)
            id = Base.PkgId(Unicode)
            pkgdata = Revise.pkgdatas[id]
            @test any(k->endswith(k, "Unicode.jl"), keys(pkgdata.fileinfos))
            @test Revise.get_def(first(methods(Unicode.isassigned))) isa Revise.RelocatableExpr

            # Test that we skip over files that don't end in ".jl"
            logs, _ = Test.collect_test_logs() do
                Revise.track(REPL)
            end
            @test isempty(logs)
        else
            @test_throws Revise.GitRepoException Revise.track(Unicode)
            @warn "skipping Core.Compiler and stdlibs tests due to lack of git repo"
        end
    end

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
                    try yry() catch end
                end
            end
            if !Sys.isapple()
                @test occursin("is not an existing directory", read(warnfile, String))
            end
            rm(warnfile)
        end
    end
end

GC.gc(); GC.gc(); GC.gc()   # work-around for https://github.com/JuliaLang/julia/issues/28306

# Now do a large-scale real-world test, in an attempt to prevent issues like #155
if Sys.islinux()
    function pkgid(name)
        project = Base.active_project()
        uuid = Base.project_deps_get(project, name)
        return Base.PkgId(uuid, name)
    end
    @testset "Plots" begin
        idplots = pkgid("Plots")
        if idplots.uuid !== nothing && !haskey(Revise.pkgdatas, idplots)
            @eval using Plots
            yry()
            @test haskey(Revise.pkgdatas, Base.PkgId(Plots.JSON))  # issue #155
        end
        # https://github.com/timholy/Rebugger.jl/issues/3
        m = which(Plots.histogram, Tuple{Vector{Float64}})
        def = Revise.get_def(m)
        @test def isa Revise.RelocatableExpr

        # Tests for "module hygiene"
        @test !isdefined(Main, :JSON)  # internal to Plots
        id = Base.PkgId(Plots.JSON)
        pkgdata = Revise.pkgdatas[id]
        file = joinpath("src", "JSON.jl")
        Revise.maybe_parse_from_cache!(pkgdata, file)
        @test !isdefined(Main, :JSON)  # internal to Plots
    end
end
