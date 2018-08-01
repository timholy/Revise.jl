using Random

const setseed = @static Random.seed!
const rseed = Ref(Random.GLOBAL_RNG)  # to get new random directories (see #24445)
function randtmp()
    setseed(rseed[])
    dirname = joinpath(tempdir(), randstring(10))
    rseed[] = Random.GLOBAL_RNG
    dirname
end

@static if Sys.isapple()
    yry() = (sleep(1.1); revise(); sleep(1.1))
else
    yry() = (sleep(0.1); revise(); sleep(0.1))
end
