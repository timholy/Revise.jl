# Tricks

## [Editing code that defines REPL](@id editREPL)

Updating the code in Julia's REPL stdlib requires some extra trickery, because modified method definitions can't be deployed until you exit any currently-running REPL functions, like those handling the prompt that you're using to interact with Julia. A workaround is to create a sub-REPL that you can shut down, and then restart a new one whenever you want to test new code:

```julia
using Revise
using REPL
Revise.track(REPL)

term = REPL.Terminals.TTYTerminal("dumb", stdin, stdout, stderr)
repl = REPL.LineEditREPL(term, true)
Revise.retry()

while true
    @info("Launching sub-REPL, use `^D` to reload, `exit()` to quit.")
    REPL.run_repl(repl)
    Revise.retry()
end
```

Many thanks to `staticfloat` for [contributing](https://github.com/timholy/Revise.jl/issues/741) this suggestion.

## Skipping re-precompilation after a restart

If you restart Julia while developing a package that is expensive to precompile,
`using MyBigPackage` will trigger precompilation before anything else can happen.
When the edits since the last precompilation are modest, it can be much faster to
load the old precompile cache and let Revise patch the loaded code up to date:

```julia
using Revise
Revise.stale_load("MyBigPackage")
using MyBigPackage
```

This mimics what Revise does during a running session, but across a restart.
See [`Revise.stale_load`](@ref) for the details and limitations.
