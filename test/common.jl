using Compat
using Compat.Random

const rseed = Ref(Random.GLOBAL_RNG)  # to get new random directories (see #24445)
function randtmp()
    srand(rseed[])
    dirname = joinpath(tempdir(), randstring(10))
    rseed[] = Random.GLOBAL_RNG
    dirname
end

@static if Sys.isapple()
    yry() = (sleep(1.1); revise(); sleep(1.1))
else
    yry() = (sleep(0.1); revise(); sleep(0.1))
end
