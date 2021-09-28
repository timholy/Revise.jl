# This gets run by setup.sh

using Pkg

Pkg.activate(@__DIR__)
Pkg.add(name="ExponentialUtilities", version=ARGS[1])

using ExponentialUtilities
