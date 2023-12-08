# Revise usage: a cookbook

## Package-centric usage

For code that might be useful more than once, it's often a good idea to put it in
a package.
Revise cooperates with the package manager to enforce its distinction between
["versioned" and "under development" packages](https://julialang.github.io/Pkg.jl/v1/managing-packages/);
packages that you want to modify and have tracked by `Revise` should be `dev`ed rather than `add`ed.

!!! note
    You should never modify package files in your `.julia/packages` directory,
    because this breaks the "contract" that such package files correspond to registered versions of the code.
    In recent versions of Julia, the source files in `.julia/packages` are read-only,
    and you should leave them this way.

    In keeping with this spirit, Revise is designed to avoid tracking changes in such files.
    The correct way to make and track modifications is to `dev` the package.

For creating packages, the author recommends [PkgTemplates.jl](https://github.com/invenia/PkgTemplates.jl).
A fallback is to use "plain" `Pkg` commands.
Both options are described below.

### PkgTemplates

!!! note
    Because PkgTemplates integrates nicely with [`git`](https://git-scm.com/),
    this approach might require you to do some configuration.
    (Once you get things set up, you shouldn't have to do this part ever again.)
    PkgTemplates needs you to configure your `git` user name and email.
    Some instructions on configuration are [here](https://docs.github.com/en/github/getting-started-with-github/set-up-git)
    and [here](https://git-scm.com/book/en/v2/Getting-Started-First-Time-Git-Setup).
    It's also helpful to sign up for a [GitHub account](https://github.com/)
    and set git's `github.user` variable.
    The [PkgTemplates documentation](https://juliaci.github.io/PkgTemplates.jl/stable/)
    may also be useful.

    If you struggle with this part, consider trying the "plain" `Pkg` variant below.

!!! note
    If the current directory in your Julia session is itself a package folder, PkgTemplates
    will use it as the parent environment (project) for your new package.
    To reduce confusion, before trying the commands below it may help to first ensure you're in a
    a "neutral" directory, for example by typing `cd()` at the Julia prompt.

Let's create a new package, `MyPkg`, to play with.

```julia
julia> using PkgTemplates

julia> t = Template()
Template:
  → User: timholy
  → Host: github.com
  → License: MIT (Tim Holy <tim.holy@gmail.com> 2019)
  → Package directory: ~/.julia/dev
  → Minimum Julia version: v1.0
  → SSH remote: No
  → Add packages to main environment: Yes
  → Commit Manifest.toml: No
  → Plugins: None

julia> t("MyPkg")
Generating project MyPkg:
    /home/tim/.julia/dev/MyPkg/Project.toml
    /home/tim/.julia/dev/MyPkg/src/MyPkg.jl
[lots more output suppressed]
```

In the first few lines you can see the location of your new package, here
the directory `/home/tim/.julia/dev/MyPkg`.

Press `]` to enter the [Pkg REPL](https://pkgdocs.julialang.org/v1/getting-started/#Basic-Usage).
Then add the new package to your current environment with the `dev` command.

```julia
(<environment>) pkg> dev MyPkg   # the dev command will look in the ~/.julia/dev folder automatically
```

Press the backspace key to return to the Julia REPL.

Now let's try it out:

```julia
julia> using Revise   # you must do this before loading any revisable packages

julia> using MyPkg
[ Info: Precompiling MyPkg [102b5b08-597c-4d40-b98a-e9249f4d01f4]
```

(It's perfectly fine if you see a different string of digits and letters after the "Precompiling MyPkg" message.)
You'll note that Julia found your package without you having to take any extra steps.

*Without* quitting this Julia session, open the `MyPkg.jl` file in an editor.
You might be able to open it with

```julia
julia> edit(pathof(MyPkg))
```

although that might require [configuring your EDITOR environment variable](https://askubuntu.com/questions/432524/how-do-i-find-and-set-my-editor-environment-variable).

You should see something like this:

```julia
module MyPkg

# Write your package code here.

end
```

This is the basic package created by PkgTemplates.
Let's create a simple `greet` function to return a message:

```julia
module MyPkg

greet() = print("Hello World!")

end # module
```

Now go back to that same Julia session, and try calling `greet`.
After a pause (while Revise's internal code compiles), you should see

```julia
julia> MyPkg.greet()
Hello World!
```

From this point forward, revisions should be fast. You can modify `MyPkg.jl`
quite extensively without quitting the Julia session, although there are some [Limitations](@ref).


### Using Pkg

[Pkg](https://julialang.github.io/Pkg.jl/v1/) works similarly to `PkgTemplates`,
but requires less configuration while also doing less on your behalf.
Let's create a blank `MyPkg` using `Pkg`. (If you tried the `PkgTemplates` version
above, you might first have to delete the package with `Pkg.rm("MyPkg")` following by
a complete removal from your `dev` directory.)

```julia
julia> using Revise, Pkg

julia> cd(Pkg.devdir())   # take us to the standard "development directory"

(v1.2) pkg> generate MyPkg
Generating project MyPkg:
    MyPkg/Project.toml
    MyPkg/src/MyPkg.jl

(v1.2) pkg> dev MyPkg
[ Info: resolving package identifier `MyPkg` as a directory at `~/.julia/dev/MyPkg`.
...
```

For the line starting `(v1.2) pkg>`, hit the `]` key at the beginning of the line,
then type `generate MyPkg`.
The next line, `dev MyPkg`, is necessary to tell `Pkg` about the existence of this new package.

Now you can do the following:
```julia
julia> using MyPkg
[ Info: Precompiling MyPkg [efe7ebfe-4313-4388-9b6c-3590daf47143]

julia> edit(pathof(MyPkg))
```
and the rest should be similar to what's above under `PkgTemplates`.
Note that with this approach, `MyPkg` has not been set up for version
control.

!!! note
    If you `add` instead of `dev` the package, the package manager will make a copy of the `MyPkg` files in your `.julia/packages` directory.
    This will be the "official" version of the files, and Revise will not track changes.


## `includet` usage

The alternative to creating packages is to manually load individual source files.
This approach is intended for early stages of development;
if you want to track multiple files and/or have some files include other files,
you should consider switching to the package style above.

Open your editor and create a file like this:

```julia
mygreeting() = "Hello, world!"
```

Save it as `mygreet.jl` in some directory. Here we will assume it's being saved in `/tmp/`.

Now load the code with `includet`, which stands for "include and track":

```julia
julia> using Revise

julia> includet("/tmp/mygreet.jl")

julia> mygreeting()
"Hello, world!"
```

Now, in your editor modify `mygreeting` to do this:

```julia
mygreeting() = "Hello, revised world!"
```

and then try it in the same session:

```julia
julia> mygreeting()
"Hello, revised world!"
```

As described above, the first revision you make may be very slow, but later revisions
should be fast.
