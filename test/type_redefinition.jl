using Revise, Base.Test

to_remove = String[]
yry() = (sleep(0.1); revise(); sleep(0.1))

testdir = joinpath(tempdir(), randstring(10))
mkdir(testdir)
push!(to_remove, testdir)
push!(LOAD_PATH, testdir)
modname = :MyTypes
dn = joinpath(testdir, String(modname), "src")
mkpath(dn)
common = """
# Constructor methods
MyType(::String) = MyType(0)

# Functions that have the type in their signature
insignature(mt::MyType) = mt.x + 1

# Methods that call the constructor but don't declare it in their inputs
function callsconstructor(x)
    mt = MyType(x)
    storearg[] = mt  # to preserve it for later analysis
    return mt.x + 5
end
const storearg = Ref{Any}()

"""
open(joinpath(dn, String(modname)*".jl"), "w") do io
    println(io, """
module $modname

export MyType, insignature, callsconstructor

struct MyType
    x::Int
end

$common

end
"""
            )
end
@eval using $modname
mt = MyType(3)
@test insignature(mt) == 4
@test callsconstructor(20) == 25
@test MyTypes.storearg[] === MyType(20)

# Now redefine the type
sleep(0.1) # to ensure the file-watching has kicked in
open(joinpath(dn, String(modname)*".jl"), "w") do io
    println(io, """
module $modname

export MyType, insignature, callsconstructor

struct MyType
    x::Int
    y::Float64
end

# We need a new constructor method
MyType(x) = MyType(x, -1.8)

$common

end
"""
            )
end
yry()
mt = MyType(3, 3.7)
@test insignature(mt) == 4
@test callsconstructor(20) == 25
@test MyTypes.storearg[].y === -1.8
