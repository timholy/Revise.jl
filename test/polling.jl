using Revise
using Test

include("common.jl")

@testset "Polling" begin
    @test Revise.polling_files[]

    testdir = randtmp()
    mkdir(testdir)
    push!(LOAD_PATH, testdir)
    dn = joinpath(testdir, "Polling", "src")
    mkpath(dn)
    srcfile = joinpath(dn, "Polling.jl")
    joinpath(dn, "Polling.jl")
    open(srcfile, "w") do io
        println(io, """
__precompile__(false)

module Polling

f() = 1

end
""")
    end
    sleep(0.5) # let the source file age a bit
    @eval using Polling
    @test Polling.f() == 1
    # I'm not sure why 2 sleeps are better than one, but here it seems to make a difference
    sleep(0.1)
    sleep(0.1)
    open(srcfile, "w") do io
        println(io, """
__precompile__(false)

module Polling

f() = 2

end
""")
    end
    # Wait through the polling interval
    yry()
    sleep(7)
    yry()
    @test Polling.f() == 2

    rm(testdir; force=true, recursive=true)
end
