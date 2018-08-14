# Introduction to Revise

`Revise.jl` may help you keep your Julia sessions running longer, reducing the
need to restart when you make changes to code.
With Revise, you can be in the middle of a session and then update packages, switch git branches
or stash/unstash code,
and/or edit the source code; typically, the changes will be incorporated
into the very next command you issue from the REPL.
This can save you the overhead of restarting, loading packages, and waiting for code to JIT-compile.

## Installation

You can obtain Revise using Julia's Pkg REPL-mode (hitting `]` as the first character of the command prompt):

```julia
(v0.7) pkg> add Revise
```

or with `using Pkg; Pkg.add("Revise")`.

## Usage example

```julia
(v0.7) pkg> dev Example
[...output related to installation...]

julia> using Revise        # importantly, this must come before `using Example`

julia> using Example

julia> hello("world")
"Hello, world"

julia> Example.f()
ERROR: UndefVarError: f not defined

julia> edit(hello)   # opens Example.jl in the editor you have configured

# Now, add a function `f() = π` and save the file

julia> Example.f()
π = 3.1415926535897...
```

Revise is not tied to any particular editor.
(The [EDITOR or JULIA_EDITOR](https://docs.julialang.org/en/latest/stdlib/InteractiveUtils/#InteractiveUtils.edit-Tuple{AbstractString,Integer}) environment variables can be used to specify your preference.)

It's even possible to use Revise on code in Julia's `Base` module or its standard libraries:
just say `Revise.track(Base)` or `using Pkg; Revise.track(Pkg)`.
For `Base`, any changes that you've made since you last built Julia will be automatically incorporated;
for the stdlibs, any changes since the last git commit will be incorporated.

See [Using Revise by default](@ref) if you want Revise to be available every time you
start julia.

## What Revise can track

Revise is fairly ambitious: if all is working you should be able to track changes to

- any package that you load with `import` or `using`
- any script you load with [`includet`](@ref)
- any file defining `Base` julia itself (with `Revise.track(Base)`)
- any file defining `Core.Compiler` (with `Revise.track(Core.Compiler)`)
- any of Julia's standard libraries (with, e.g., `using Unicode; Revise.track(Unicode)`)

The last two require that you clone Julia and build it yourself from source.

## If Revise doesn't work as expected

If Revise isn't working for you, here are some steps to try:

- See [Configuration](@ref) for information on customization options.
  In particular, some file systems (like NFS) might require special options.
- Revise can't handle all kinds of code changes; for more information,
  see the section on [Limitations](@ref).
- Try running `test Revise` from the Pkg REPL-mode.
  If tests pass, check the documentation to make sure you understand how Revise should work.
  If they fail (especially if it mirrors functionality that you need and isn't working), see
  [Fixing a broken or partially-working installation](@ref) for some suggestions.

If you still encounter problems, please [file an issue](https://github.com/timholy/Revise.jl/issues).
