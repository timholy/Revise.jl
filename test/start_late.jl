# For this test, Julia should be started without Revise and then it should be added to the running session
# Catches #664

using Test

@async(Base.run_main_repl(true, true, false, true, false))
while !isdefined(Base, :active_repl_backend)
    sleep(0.5)
end

using Revise
@test Revise.revise_first ∈ Base.active_repl_backend.ast_transforms

exit()
