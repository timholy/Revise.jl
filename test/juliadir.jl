using Revise, InteractiveUtils, Test

@eval Revise juliadir = ARGS[1]

@test Revise.juliadir != Revise.basebuilddir
@test Revise.juliadir != Revise.fallback_juliadir()

@show Revise.juliadir

# https://github.com/timholy/Revise.jl/issues/697
@test Revise.definition(@which(Float32(π))) isa Expr
