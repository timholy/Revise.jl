using Revise, InteractiveUtils, Test

@eval Revise juliadir = ARGS[1]

@test Revise.juliadir != Revise.basebuilddir
@test Revise.juliadir != Revise.fallback_juliadir()

# https://github.com/timholy/Revise.jl/issues/697
let def = Revise.definition(@which(Float32(π)))
    @test isa(def, Expr)
    @test Meta.isexpr(def, :macrocall)
end
