# Revise

[![Build Status](https://travis-ci.org/timholy/Revise.jl.svg?branch=master)](https://travis-ci.org/timholy/Revise.jl)

[![codecov.io](http://codecov.io/github/timholy/Revise.jl/coverage.svg?branch=master)](http://codecov.io/github/timholy/Revise.jl?branch=master)

`Revise.jl` makes it easier to continuously update your code in a
running Julia session.  If you've said `using Revise` in a Julia
session, you can edit the source files of packages and expect that
most changes will be activated the next time you issue a command from
the REPL.

### Example:

```julia
julia> Pkg.add("Example")
INFO: Installing Example v0.4.1
INFO: Package database updated
INFO: METADATA is out-of-date — you may not have the latest version of Example
INFO: Use `Pkg.update()` to get the latest versions of your packages

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

## Using Revise automatically

If you like Revise, you can ensure that every Julia session uses it by
adding the following to your `.juliarc.jl` file:

```julia
@schedule begin
    sleep(0.1)
    @eval using Revise
end
```

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
