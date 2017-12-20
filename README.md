# Revise

**NOTE: this page is for Julia 0.7-DEV and higher. For Julia 0.6 [see this branch](https://github.com/timholy/Revise.jl/tree/v0.6)**

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

It's even possible to use Revise on code in Julia's `Base` module: just say `Revise.track(Base)`.
Any changes that you've made since you last built Julia will be automatically incorporated.

## Manual revision

By default, Revise processes any modified source files every time you enter
a command at the REPL.
However, there might be times where you'd prefer to exert manual control over
the timing of revisions. `Revise` looks for an environment variable
`JULIA_REVISE`, and if it is set to anything other than `"auto"` it
will require that you manually call `revise()` to update code.

For example, on Linux you can start your Julia session as

```sh
$ JULIA_REVISE=manual julia
```

and then revisions will be processed only when you call `revise()`.
If you prefer this mode of operation, you can add that variable to your `bash`
environment or add `ENV["JULIA_REVISE"] = "manual"` to your
`.juliarc.jl` before you say `using Revise` (see below).

## Using Revise by default

If you like Revise, you can ensure that every Julia session uses it by
adding the following to your `.juliarc.jl` file:

```julia
@schedule begin
    sleep(0.1)
    @eval using Revise
end
```
This should work the REPL, Juno, and IJulia. For VSCode see [these instructions](https://github.com/JuliaEditorSupport/julia-vscode/wiki/Known-issues-and-workarounds).

## How it works

Revise is based on the fact that you can change functions even when
they are defined in other modules. Here's an example showing how you do that manually (without using Revise):

```julia
julia> convert(Float64, π)
3.141592653589793

julia> # That's too hard, let's make life easier for students

julia> @eval Base convert(::Type{Float64}, x::Irrational{:π}) = 3.0
convert (generic function with 714 methods)

julia> convert(Float64, π)
3.0
```

Revise removes some of the tedium of manually copying and pasting code
into `@eval` statements.
To decrease the amount of re-JITting
required, Revise avoids reloading entire modules; instead, it takes care
to `eval` only the *changes* in your package(s), much as you would if you were
doing it manually.

To accomplish this, Revise uses the following overall strategy:

- add callbacks to Base so that Revise gets notified when new
  packages are loaded or new files `include`d
- prepare source-code caches for every new file. These caches
  will allow Revise to detect changes when files are updated. For precompiled
  packages this happens on an as-needed basis, using the cached
  source in the `*.ji` file. For non-precompiled packages, Revise parses
  the source for each `include`d file immediately so that the initial state is
  known and changes can be detected.
- monitor the file system for changes to any of the dependent files;
  it immediately appends any updates to a list of file names that need future
  processing
- intercept the REPL's backend to ensure that the list of
  files-to-be-revised gets processed each time you execute a new
  command at the REPL
- when a revision is triggered, the source file(s) are re-parsed, and
  a diff between the cached version and the new version is
  created. `eval` the diff in the appropriate module(s).
- replace the cached version of each source file with the new version, so that
  further changes are `diff`ed against the most recent update.

## Caveats

`Revise` only tracks files that have been required as a consequence of
a `using` or `import` statement; files loaded by `include` are not
tracked, unless you explicitly use `Revise.track(filename)`.

Sometimes you might wish to change a method's type signature or number of arguments,
or remove a method specialized for specific types.
To prevent "stale" methods
from being called by dispatch, Revise accommodates method deletion, for example:
```julia
f(x) = 1
f(x::Int) = 2 # delete this method
```
If you save the file, the next time you call `f(5)` from the REPL you will get 1.

However, Revise needs to be able to parse the signature of the deleted method.
As a consequence, methods generated with code:
```julia
for T in (Int, Float64)
    @eval mytypeof(x::$T) = $T  # delete this line
end
```
will not disappear from the method lists until you restart, or manually call
`Base.delete_method(m::Method)`. You can use `m = @which ...` to obtain a method.

For changes to macros or to functions that affect the expansion of a `@generated` function,
you may explicitly call `revise(module)` to force reevaluating every definition in `module`.

Finally, there are some kinds of changes that Revise cannot incorporate into a running Julia session:

- changes to type definitions
- file or module renames

These kinds of changes require that you restart your Julia session.

## Credits

Revise became possible because of Jameson Nash's fix of [Julia issue 265](https://github.com/JuliaLang/julia/issues/265).
