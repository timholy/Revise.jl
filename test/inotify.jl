using Test

# Verifies that Revise emits a single, actionable warning when the OS refuses an
# inotify watch (ENOSPC). This is only meaningful when the inotify watch limit has
# been set very low first; see the (currently disabled) `inotify` step in
# `.github/workflows/ci.yml`. Relevant issues: #26, #1010.
#
# `using Revise` is loaded inside the log collector on purpose: the warning uses
# `maxlog=1`, so it fires only once per session and may be triggered as soon as
# Revise starts watching its own dependencies.

@testset "inotify" begin
    logs, _ = Test.collect_test_logs() do
        @eval using Revise
        Revise.track(joinpath(@__DIR__, "revisetest.jl"))
        sleep(1)   # let the watcher tasks run and hit the inotify limit
    end
    inotify_warnings = filter(rec -> occursin("inotify", rec.message), logs)
    # `maxlog=1` collapses the per-directory flood into a single warning
    @test length(inotify_warnings) == 1
    if !isempty(inotify_warnings)
        msg = first(inotify_warnings).message
        @test occursin("ENOSPC", msg)
        @test occursin("JULIA_REVISE_POLL", msg)
    end
end
