using ReviseCore, InteractiveUtils, Test
using Revise.CodeTracking

@eval ReviseCore juliadir = ARGS[1]

@test ReviseCore.juliadir != ReviseCore.basebuilddir
@test ReviseCore.juliadir != ReviseCore.fallback_juliadir()

# https://github.com/timholy/Revise.jl/issues/697
let def = CodeTracking.definition(@which(Float32(π)))
    @test isa(def, Expr)
    @test Meta.isexpr(def, :macrocall)
end
