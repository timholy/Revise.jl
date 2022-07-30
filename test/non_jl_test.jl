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
    Expr(:toplevel, :(baremodule fake_lang
       $(exprs...)
    end), :(using .fake_lang))
end

function Base.include(mod::Module, file::MyFile)
    Core.eval(mod, make_module(file))
end
Base.include(file::MyFile) = Base.include(Core.Main, file)

using Revise
function Revise.parse_source!(mod_exprs_sigs::Revise.ModuleExprsSigs, file::MyFile, mod::Module; kwargs...)
    ex = make_module(file)
    Revise.process_source!(mod_exprs_sigs, ex, file, mod; kwargs...)
end

path = joinpath(@__DIR__, "test.program")
try
    cp(joinpath(@__DIR__, "fake_lang", "test.program"), path, force=true)
    m=MyFile(path)
    includet(m)
    Revise.revise()
    @test fake_lang.y() == "2"
    @test fake_lang.x() == "1"
    cp(joinpath(@__DIR__, "fake_lang", "new_test.program"), path, force=true)
    Revise.revise()
    @test fake_lang.x() == "2"
    @test_throws MethodError fake_lang.y()
finally
    rm(path, force=true)
end
