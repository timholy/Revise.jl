using Pkg
Pkg.activate(".")
Pkg.instantiate()

struct MyFile
    file::String
end
Base.abspath(file::MyFile) = MyFile(Base.abspath(file.file))
Base.isabspath(file::MyFile) = Base.isabspath(file.file)
Base.joinpath(str::String, file::MyFile) = MyFile(Base.joinpath(str, file.file))
Base.normpath(file::MyFile) = MyFile(Base.normpath(file.file))
Base.isfile(file::MyFile) = Base.isfile(file.file)
Base.findfirst(str::String, file::MyFile) = Base.findfirst(str, file.file)
Base.String(file::MyFile) = file.file

function make_module(file::MyFile)
    exprs = []
    for line in eachline(file.file)
       val, name = split(line, '=')
       push!(exprs, :(function $(Symbol(name))() $val end))
    end
    @show exprs
    Expr(:toplevel, :(baremodule test
       $(exprs...)
    end), :(using .test))
end

function Base.include(mod::Module, file::MyFile)
    Core.eval(mod, make_module(file))
end
Base.include(file::MyFile) = Base.include(Core.Main, file)

using Revise
function Revise.parse_source!(mod_exprs_sigs::Revise.ModuleExprsSigs, file::MyFile, mod::Module; kwargs...)
    ex = make_module(file)
    @show mod_exprs_sigs, file, mod, kwargs
    Revise.process_source!(mod_exprs_sigs, ex, file, mod; kwargs...)
end
try
    cp(joinpath("fake_lang", "test.program"), "tmp.program")
    m=MyFile("tmp.program")
    includet(m)
    @test test.y() == "2"
    @test test.x() == "1"
    cp(joinpath("fake_lang", "new_test.program"), "tmp.program", force=true)
    @test test.x() == "2"
    @test !isdefined(test, :y)
finally
    rm("tmp.program", force=true)
end
