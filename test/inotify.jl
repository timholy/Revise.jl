using Revise, Test
# This test should only be run if you have a very small inotify limit

@testset "inotify" begin
    logs, _ = Test.collect_test_logs() do
        Revise.track("revisetest.jl")
    end
    sleep(0.1)
    @test !isempty(logs)
    @test any(rec->occursin("inotify", rec.message), logs)
end
