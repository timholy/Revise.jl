# This test is intended to be run after `setup.sh` runs. ExponentialUtilities
# should be held at v1.9.0.

using Revise, Pkg, Test

const thisdir = dirname(@__FILE__)
Pkg.activate(thisdir)
# This is only needed on Pkg versions that don't notify
Revise.active_project_watcher()

using ExponentialUtilities
id = Base.PkgId(ExponentialUtilities)
pkgdata = Revise.pkgdatas[id]
A = rand(3, 3); A = A'*A; A = A' + A;
@test_throws UndefVarError exponential!(A)   # not present on v1.9
# From a different process, switch the active version of ExponentialUtilities
run(Cmd(`julia -e 'using Pkg; Pkg.activate("."); Pkg.add(name="ExponentialUtilities", version="1.10.0")'`; dir=thisdir))
sleep(0.2)
revise()
@test exponential!(A) isa Matrix   # present on v1.9
# ...and then switch back (check that it's bidirectional and also to reset state)
run(Cmd(`julia -e 'using Pkg; Pkg.activate("."); Pkg.add(name="ExponentialUtilities", version="1.9.0")'`; dir=thisdir))
sleep(0.2)
revise()
@test_throws MethodError exponential!(A)   # not present on v1.9
