# Advanced usage

## Tracking files loaded conditionally with Requires.jl

[Requires.jl](https://github.com/MikeInnes/Requires.jl) allows you to declare conditional dependencies for a package.
When those dependencies result in the inclusion of new source files, Revise will not
automatically track them. However, you can force Revise to track them by registering the file(s).
An example registration might look like this:

```julia
function __init__()
    @require SomePackage="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" begin
        include("newcode.jl")
        # Register newcode.jl with Revise
        @require Revise="295af30f-e4ad-537b-8983-00126c2a3abe" begin
            import .Revise
            Revise.add_file(TrackRequires, "src/newcode.jl")
        end
    end
end
```

The inner `@require` statement makes registration conditional on Revise, allowing
your package to be used with and without Revise.
In the `add_file` call (which is what performs the registration),
note that you must use the relative path from the package top-level directory
(here, `"src/newcode.jl"` rather than just `"newcode.jl"`).

!!! note
    In principle, Revise could parse the `__init__` function and perform this
    registration itself. However, this would lead to a performance problem:
    for this to work, Revise would have to "defensively" parse the top-level source file
    of every loaded package.
    Since Revise takes pains to parse only source files that
    have changes (see the first section of [How Revise works](@ref)),
    we instead opt for manual registration of `@require` dependencies.
