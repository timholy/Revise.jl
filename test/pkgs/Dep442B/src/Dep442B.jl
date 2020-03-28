module Dep442B

using Requires

export check442B

check442B() = true

function link_442A()
    @debug "Loading 442A support into 442B"
    include("support_442A.jl")
end

function __init__()
    @require Dep442A="76238f47-ed95-4e4a-a4d9-95a3fb1630ea" link_442A()
end

end # module
