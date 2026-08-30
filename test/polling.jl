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

@testset "Polling startup gap" begin
    testdir = randtmp()
    mkdir(testdir)
    push!(LOAD_PATH, testdir)
    dn = joinpath(testdir, "PollGap", "src")
    mkpath(dn)
    srcfile = joinpath(dn, "PollGap.jl")
    write(srcfile, """
__precompile__(false)

module PollGap

f() = 1

end
""")
    sleep(0.5) # let the source file age a bit
    @eval using PollGap
    @test PollGap.f() == 1
    # Edit immediately, with no yield since loading: the per-file poll tasks
    # scheduled by init_watching have not run yet, so poll_file would baseline
    # on the already-edited file. The change must instead be caught by
    # comparing against the ctime recorded at init_watching time.
    write(srcfile, """
__precompile__(false)

module PollGap

f() = 2

end
""")
    yry()
    sleep(7)
    yry()
    @test PollGap.f() == 2

    rm(testdir; force=true, recursive=true)
end
