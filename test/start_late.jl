# For this test, Julia should be started without Revise and then it should be added to the running session
# Catches #664

using Test
using REPL

# Keep the REPL alive when the test process receives EOF on stdin.
input = redirect_stdin()
t = @async(
    VERSION >= v"1.12.0-DEV.612" ? Base.run_main_repl(true, true, :no, true) :
    VERSION >= v"1.11.0-DEV.222" ? Base.run_main_repl(true, true, :no, true, false)   :
                                   Base.run_main_repl(true, true, false, true, false))
isdefined(Base, :errormonitor) && Base.errormonitor(t)
while !isdefined(Base, :active_repl_backend) || isnothing(Base.active_repl_backend)
    sleep(0.5)
end

using Revise
@test Revise.revise_first ∈ Base.active_repl_backend.ast_transforms

REPL.eval_user_input(:(exit()), Base.active_repl_backend, Main)
