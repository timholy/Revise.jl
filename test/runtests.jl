using Revise
using Test

@test isempty(detect_ambiguities(Revise, Base, Core))

using Pkg, Unicode, Distributed, InteractiveUtils, REPL
using OrderedCollections: OrderedSet

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
    typex = Revise.sig_type_exprs(sig)
    compare_sigs(ex, typex)
end

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

        # Return type annotations
        @test Revise.sig_type_exprs(:(typeinfo_eltype(typeinfo::Type)::Union{Type,Nothing})) ==
              Revise.sig_type_exprs(:(typeinfo_eltype(typeinfo::Type)))
        def = quote
            function +(x::Bool, y::T)::promote_type(Bool,T) where T<:AbstractFloat
                return ifelse(x, oneunit(y) + y, y)
            end
        end
        sig = Revise.get_signature(def)
        @test Revise.sig_type_exprs(sig) == [:(Tuple{Core.Typeof(+), Bool, T} where T<:AbstractFloat)]

        # Overloading call
        def = :((i::Inner)(::String) = i.x)
        sig = Revise.get_signature(def)
        sigexs = Revise.sig_type_exprs(sig)
        Core.eval(ReviseTestPrivate, def)
        i = ReviseTestPrivate.Inner(3)
        m = @which i("hello")
        @test Core.eval(ReviseTestPrivate, sigexs[1]) == m.sig
        def = :((::Type{Inner})(::Dict) = 17)
        sig = Revise.get_signature(def)
        sigexs = Revise.sig_type_exprs(sig)
        Core.eval(ReviseTestPrivate, def)
        m = @which ReviseTestPrivate.Inner(Dict("a"=>1))
        @test Core.eval(ReviseTestPrivate, sigexs[1]) == m.sig

        # Annotations
        refex =  Revise.relocatable!(:(function foo(x) x^2 end))
        for ex in (:(@inline function foo(x) x^2 end),
                   :(@noinline function foo(x) x^2 end),
                   :(@propagate_inbounds function foo(x) x^2 end))
            @test Revise.get_signature(ex) == :(foo(x))
            @test Revise.relocatable!(Revise.funcdef_expr(ex)) == refex
        end

        # @eval-defined methods
        ex = :(@eval getindex(A::Array, i1::Int, i2::Int, I::Int...) = (@_inline_meta; arrayref($(Expr(:boundscheck)), A, i1, i2, I...)))
        @test Revise.get_signature(ex) == :(getindex(A::Array, i1::Int, i2::Int, I::Int...))
        @test Revise.relocatable!(Revise.funcdef_expr(ex)) == Revise.relocatable!(
            :(getindex(A::Array, i1::Int, i2::Int, I::Int...) = (@_inline_meta; arrayref($(Expr(:boundscheck)), A, i1, i2, I...)))
            )
    end

    @testset "Comparison and line numbering" begin
        fl1 = joinpath(@__DIR__, "revisetest.jl")
        fl2 = joinpath(@__DIR__, "revisetest_revised.jl")
        fl3 = joinpath(@__DIR__, "revisetest_errors.jl")
        include(fl1)  # So the modules are defined
        # test the "mistakes"
        @test ReviseTest.cube(2) == 16
        @test ReviseTest.Internal.mult3(2) == 8
        oldmd = Revise.parse_source(fl1, Main)
        Revise.instantiate_sigs!(oldmd)
        newmd = Revise.parse_source(fl2, Main)
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
        @test length(dvs) == 2
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

        # Backtraces
        newmd = Revise.parse_source(fl3, Main)
        revmd = Revise.eval_revised(newmd, revmd)
        try
            ReviseTest.cube(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "cube"
            bt = throwing_function(stacktrace(catch_backtrace()))
            @test bt.func == :cube && bt.file == Symbol(fl3) && bt.line == 7
        end
        try
            ReviseTest.Internal.mult2(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "mult2"
            bt = throwing_function(stacktrace(catch_backtrace()))
            @test bt.func == :mult2 && bt.file == Symbol(fl3) && bt.line == 13
        end
    end

    @testset "Display" begin
        io = IOBuffer()
        show(io, Revise.relocatable!(:(@inbounds x[2])))
        str = String(take!(io))
        @test str == ":(@inbounds x[2])"
        fm = Revise.parse_source(joinpath(@__DIR__, "revisetest.jl"), Main)
        Revise.instantiate_sigs!(fm)
        @test string(fm) == "OrderedCollections.OrderedDict(Main=>FMMaps(<1 expressions>, <0 signatures>),Main.ReviseTest=>FMMaps(<2 expressions>, <2 signatures>),Main.ReviseTest.Internal=>FMMaps(<2 expressions>, <2 signatures>))"
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
            @test Revise.get_def(m) == convert(Revise.RelocatableExpr, :( $fn1() = 1 ))
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
            # Check module2files
            files = [joinpath(dn, modname*".jl"), joinpath(dn, "file2.jl"),
                     joinpath(dn, "subdir", "file3.jl"),
                     joinpath(dn, "subdir", "file4.jl"),
                     joinpath(dn, "file5.jl")]
            @test Revise.module2files[Symbol(modname)] == files
        end
        # Remove the precompiled file
        rm_precompile("PC")

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

        pop!(LOAD_PATH)
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
        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "MethDel.jl"), "w") do io
            println(io, """
module MethDel
f(x) = 1
g(x::Array{T,N}, y::T) where N where T = 2
h(x::Array{T}, y::T) where T = g(x, y)
k(::Int; goodchoice=-1) = goodchoice
dfltargs(x::Int8, yz::Tuple{Int,Float32}=(0,1.0f0)) = x+yz[1]+yz[2]
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

        Base.delete_method(first(methods(Base.revisefoo)))
    end

    @testset "Pkg exclusion" begin
        push!(Revise.dont_watch_pkgs, :Example)
        push!(Revise.silence_pkgs, :Example)
        @eval import Example
        for k in keys(Revise.fileinfos)
            if occursin("Example", k)
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
    end

    @testset "Git" begin
        if haskey(ENV, "CI")   # if we're doing CI testing (Travis, Appveyor, etc.)
            # First do a full git checkout of a package (we'll use Revise itself)
            @warn "checking out a development copy of Revise for testing purposes"
            pkg = Pkg.Types.PackageSpec("Revise")
            pkg.repo = Pkg.Types.GitRepo("", "")
            Pkg.API.add_or_develop(Pkg.Types.Context(), [pkg], mode=:develop)
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
    end

    @testset "Recipes" begin
        # Tracking Base
        Revise.track(Base)
        @test any(k->endswith(k, "number.jl"), keys(Revise.fileinfos))
        @test length(filter(k->endswith(k, "file.jl"), keys(Revise.fileinfos))) == 2

        # Determine whether a git repo is available. Travis & Appveyor do not have this.
        repo, path = Revise.git_repo(Revise.juliadir)
        if repo != nothing
            # Tracking Core.Compiler
            Revise.track(Core.Compiler)
            @test any(k->endswith(k, "compiler.jl"), keys(Revise.fileinfos))

            # Tracking stdlibs
            Revise.track(Unicode)
            @test any(k->endswith(k, "Unicode.jl"), keys(Revise.fileinfos))
            @test Revise.get_def(first(methods(Unicode.isassigned))) isa Revise.RelocatableExpr

            # Test that we skip over files that don't end in ".jl"
            logs, _ = Test.collect_test_logs() do
                Revise.track(REPL)
            end
            @test isempty(logs)
        else
            @warn "skipping Core.Compiler and stdlibs tests due to lack of git repo"
        end
    end

    @testset "Cleanup" begin
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
                yry()
            end
        end
        if !Sys.isapple()
            @test occursin("is not an existing directory", read(warnfile, String))
        end
        rm(warnfile)
    end
end

GC.gc(); GC.gc(); GC.gc()   # work-around for https://github.com/JuliaLang/julia/issues/28306
