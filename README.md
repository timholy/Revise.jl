# Revise

[![Build Status](https://travis-ci.org/timholy/Revise.jl.svg?branch=master)](https://travis-ci.org/timholy/Revise.jl)
[![Build status](https://ci.appveyor.com/api/projects/status/e1xnsj4e5q9308y6/branch/master?svg=true)](https://ci.appveyor.com/project/timholy/revise-jl/branch/master)
[![codecov.io](http://codecov.io/github/timholy/Revise.jl/coverage.svg?branch=master)](http://codecov.io/github/timholy/Revise.jl?branch=master)

`Revise.jl` may help you keep your sessions running longer, reducing the
need to restart Julia whenever you make changes to code.
With Revise, you can be in the middle of a session and then issue a `Pkg.update()`
and/or edit the source code; typically, the changes will be incorporated
into the very next command you issue from the REPL.
This can save you the overhead of restarting, loading packages, and waiting for code to JIT-compile.

### Example:

```julia
julia> Pkg.add("Example")
INFO: Installing Example v0.4.1
INFO: Package database updated

julia> using Revise        # importantly, this must come before `using Example`

julia> using Example

julia> hello("world")
"Hello, world"

julia> Example.f()
ERROR: UndefVarError: f not defined

julia> edit("Example.jl")  # add a function `f() = π` and save the file

julia> Example.f()
π = 3.1415926535897...
```

To a limited extent, it's even possible to use Revise on code in
Julia's `Base` module: just say `Revise.track(Base)`. You'll see
warnings about some files that are not tracked (see more information
below).

## Manual revision

There might be times where you'd prefer to exert manual control over
the timing of revisions. `Revise` looks for an environment variable
`JULIA_REVISE`, and if it is set to anything other than `"auto"` it
will avoid making automatic updates each time you enter a command at
the REPL. You can call `revise()` whenever you want to process
revisions.

On Linux, you can start your Julia session as

```sh
$ JULIA_REVISE=manual julia
```

and then revisions will be processed only when you call `revise()`.

## Using Revise by default

If you like Revise, you can ensure that every Julia session uses it by
adding the following to your `.juliarc.jl` file:

```julia
@schedule begin
    sleep(0.1)
    @eval using Revise
end
```

## How it works

Revise is based on the fact that you can change functions even when
they are defined in other modules:

```julia
julia> convert(Float64, π)
3.141592653589793

julia> # That's too hard, let's make life easier for students

julia> eval(Base, quote
       convert(::Type{Float64}, x::Irrational{:π}) = 3.0
       end)
WARNING: Method definition convert(Type{Float64}, Base.Irrational{:π}) in module Base at irrationals.jl:130 overwritten at REPL[2]:2.
convert (generic function with 700 methods)

julia> convert(Float64, π)
3.0
```

Revise removes some of the tedium of manually copying and pasting code
into `eval` statements.  To decrease the amount of re-JITting
required, rather than reloading the entire package Revise takes care
to `eval` only the *changes* in your package(s).  To accomplish this,
it uses the following overall strategy:

- add a callback to Base so that Revise gets notified when new
  packages are loaded
- parse the source code for newly-loaded packages to determine the
  module associated with each line of code, as well as the list of
  `include`d files; cache the parsed code so that it is possible to
  detect future changes
- monitor the file system for changes to any of the `include`d files;
  append any updated files to a list of file names that need future
  processing
- intercept the REPL's backend to ensure that the list of
  files-to-be-revised gets processed each time you execute a new
  command at the REPL
- when a revision is triggered, the source file(s) are re-parsed, and
  a diff between the cached version and the new version is
  created. `eval` the diff in the appropriate module(s).
- replace the cached version of each source file with the new version.

## Caveats

`Revise` only tracks files that have been required as a consequence of
a `using` or `import` statement; files loaded by `include` are not
tracked.

There are some kinds of changes that Revise cannot incorporate into a running Julia session:

- changes to type definitions
- function or method deletions
- file or module renames
- changes in files that are omitted by Revise (you should see a warning about these). Revise has to be able to statically parse the paths in your package; statements like `include("file2.jl")` are easy but `include(string((length(Core.ARGS)>=2 ? Core.ARGS[2] : ""), "build_h.jl"))` cannot be handled.

These kinds of changes require that you restart your Julia session.

## Credits

Revise became possible because of Jameson Nash's fix of [Julia issue 265](https://github.com/JuliaLang/julia/issues/265).
