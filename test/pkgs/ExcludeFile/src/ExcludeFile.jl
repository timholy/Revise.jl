module ExcludeFile

include_dependency(joinpath(dirname(@__DIR__), "deps", "dependency.txt"))
include("f.jl")

end # module
