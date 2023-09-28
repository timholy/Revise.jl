# Introduction to Revise

`Revise.jl` may help you keep your Julia sessions running longer, reducing the
need to restart when you make changes to code.
With Revise, you can be in the middle of a session and then edit source code,
update packages, switch git branches, and/or stash/unstash code;
typically, the changes will be incorporated into the very next command you issue from the REPL.
This can save you the overhead of restarting, loading packages, and waiting for code to JIT-compile.

Using Revise also improves your experience when using the
[debuggers](https://julialang.org/blog/2019/03/debuggers/).
Revise will keep track of changed locations of your methods in file, and ensure that the
debugger displays the source code of what you're actually debugging.

!!! note "Automatically loading Revise"

    Many users automatically load Revise on startup.
    On versions of Julia older than 1.5, this is slightly more involved
    than just adding `using Revise` to `.julia/config/startup.jl`: see
    [Using Revise by default](@ref) for details.

## Installation

You can obtain Revise using Julia's Pkg REPL-mode (hitting `]` as the first character of the command prompt):

```julia
(v1.0) pkg> add Revise
```

or with `using Pkg; Pkg.add("Revise")`.

## Usage example

We'll make changes to Julia's "Example" package (a trivial package designed to
illustrate the file and directory organization of typical packages).
We have to "develop" it in order to make changes:

```julia
(v1.0) pkg> dev Example
[...output related to installation...]

```
Now we load Revise (if we haven't already done so) and Example:
```julia
julia> using Revise        # importantly, this must come before `using Example`

julia> using Example

julia> hello("world")
"Hello, world"
```

Now we're going to check that the `Example` module currently lacks a function named `f`:

```julia
julia> Example.f()
ERROR: UndefVarError: f not defined
```

But say we really want `f`, so let's add it.
You can either navigate to the source code (at `.julia/dev/Example/src/Example.jl`)
in an editor manually, or you can use Julia to open it for you:

```julia
julia> edit(hello)   # opens Example.jl in the editor you have configured
```

Now, add a function `f() = π` and save the file.
Go back to the REPL (the *same* REPL, don't restart Julia) and try this:

```julia
julia> Example.f()
π = 3.1415926535897...
```

Voila! Even though we'd loaded Example before adding this function,
Revise noticed the change and inserted it into our running session.

!!! warning
    Revise's first revision has latency of several seconds--it's compiling all of its internal code, which includes a complete [Julia interpreter](https://github.com/JuliaDebug/JuliaInterpreter.jl) and all of Revise's parse/diff/patch/cache machinery.
    After your first revision, future revisions will generally be fast enough that they will seem nearly instantaneous. (There are exceptions, but they occur
    only in specific circumstances, for example when Revise's own code gets [invalidated](https://julialang.org/blog/2020/08/invalidations/) by your changes.)

Now suppose we realize we've made a horrible mistake: that `f` method will mess up everything, because it's part of a more complicated dispatch process and incorrectly intercepts certain `f` calls.
No problem, just delete `f` in your editor, save the file, and you're back to this:

```julia
julia> Example.f()
ERROR: UndefVarError: f not defined
```

all without restarting Julia.
While you can evaluate *new* methods without Revise using [inline evaluation](https://www.julia-vscode.org/docs/stable/userguide/runningcode/#Julia:-Execute-Code-Block-(AltEnter)-1) through your IDE,
method *deletion* is just one example of a change that can only be made easily by Revise.

If you need more examples, see [Revise usage: a cookbook](@ref).

## Other key features of Revise

Revise updates its internal paths when you change versions of a package.
To try this yourself, first re-insert that definition of `f` in the `dev` version of
`Example` and save the file.
Now try toggling back and forth between the `dev` and released versions of `Example`:

```julia
(v1.0) pkg> free Example   # switch to the released version of Example

julia> Example.f()
ERROR: UndefVarError: f not defined

(v1.0) pkg> dev Example

julia> Example.f()
π = 3.1415926535897...
```

Revise is not tied to any particular editor.
(The [EDITOR or JULIA_EDITOR](https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_EDITOR) environment variables can be used to specify your preference for which editor gets launched by Julia's `edit` function.)

If you don't want to have to remember to say `using Revise` each time you start
Julia, see [Using Revise by default](@ref).

## What Revise can track

Revise is fairly ambitious: if all is working, subject to a few [Limitations](@ref) you should be able to track changes to

- any package that you load with `import` or `using`
- any script you load with [`includet`](@ref) (see [Configuring the revise mode](@ref) for important default restrictions on `includet`)
- any file defining `Base` julia itself (with `Revise.track(Base)`)
- any of Julia's standard libraries (with, e.g., `using Unicode; Revise.track(Unicode)`)
- any file defining `Core.Compiler` (with `Revise.track(Core.Compiler)`)

The last one requires that you clone Julia and build it yourself from source.

## Secrets of Revise "wizards"

Revise can assist with methodologies like
[test-driven development](https://en.wikipedia.org/wiki/Test-driven_development).
While it's often desirable to write the test first, sometimes when fixing a bug
it's very difficult to write a good test until you understand the bug better.
Often that means basically fixing the bug before your write the test.
With Revise, you can

- fix the bug while simultaneously developing a high-quality test
- verify that your test passes with the fixed code
- `git stash` your fix and check that your new test fails on the old code,
  thus verifying that your test captures the essence of the former bug (if it doesn't fail,
  you need a better test!)
- `git stash pop`, test again, commit, and submit

all without restarting your Julia session.

## Other Revise workflows

Revise can be used to perform work when files update.
For example, let's say you want to regenerate a set of web pages whenever your code changes.
Suppose you've placed your Julia code in a package called `MyWebCode`,
and the pages depend on "file.js" and all files in the "assets/" directory; then

```julia
entr(["file.js", "assets"], [MyWebCode]) do
    build_webpages(args...)
end
```

will execute `build_webpages(args...)` whenever you save updates to the listed files
or `MyWebCode`.

If you want to regenerate the web page as soon as any change is detected, not
only in `MyWebCode` but also in any package tracked by Revise, you can provide
the `all` keyword argument to [`entr`](@ref):

```julia
entr(["file.js", "assets"]; all=true) do
    build_webpages(args...)
end
```

## Taking advantage of Revise in other packages

To make it easier for other packages to benefit from Revise without needing to add it
as a dependency or understand Revise's internals, Revise interfaces with
[CodeTracking](https://github.com/timholy/CodeTracking.jl),
which is a small package acting as Revise's "query" interface.

## What else do I need to know?

Except in cases of problems (see below), that's it!
Revise is a tool that runs in the background, and when all is well it should be
essentially invisible, except that you don't have to restart Julia so often.

Revise can also be used as a "library" by developers who want to add other new capabilities
to Julia; the sections [How Revise works](@ref) and [Developer reference](@ref) are
particularly relevant for them.

## If Revise doesn't work as expected

If Revise isn't working for you, here are some steps to try:

- See [Configuration](@ref) for information on customization options.
  In particular, some file systems (like [NFS](https://en.wikipedia.org/wiki/Network_File_System)) and current users of [WSL2](https://devblogs.microsoft.com/commandline/announcing-wsl-2/) might require special options.
- Revise can't handle all kinds of code changes; for more information,
  see the section on [Limitations](@ref).
- Try running `test Revise` from the Pkg REPL-mode.
  If tests pass, check the documentation to make sure you understand how Revise should work.
  If they fail (especially if it mirrors functionality that you need and isn't working), see
  [Debugging problems with paths](@ref) for one set of suggestions.

If you still encounter problems, please [file an issue](https://github.com/timholy/Revise.jl/issues).
Especially if you think Revise is making mistakes in adding or deleting methods, please
see the page on [Debugging Revise](@ref) for information about how to attach logs
to your bug report.
