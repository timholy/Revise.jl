# Revise usage: a cookbook

## Package-centric usage

For code that might be useful more than once, it's often a good idea to put it in
a package.
For creating packages, the author recommends [PkgTemplates.jl](https://github.com/invenia/PkgTemplates.jl).

!!! note
    If you've never developed code before, this approach might require you to do some configuration.
    (Once you get things set up, you shouldn't have to do this part ever again.)
    PkgTemplates needs you to configure your `git` user name and email.
    (Some instructions on configuration are [here](https://help.github.com/en/articles/set-up-git)
    and [here](https://git-scm.com/book/en/v2/Getting-Started-First-Time-Git-Setup).)
    It's also helpful to sign up for a [GitHub account](https://github.com/)
    and set git's `github.user` variable.
    The [PkgTemplates documentation](https://invenia.github.io/PkgTemplates.jl/stable/)
    may also be useful.

!!! note
    If the current directory in your Julia session is itself a package folder, PkgTemplates
    with use it as the parent environment (project) for your new package.
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

julia> generate("MyPkg", t)
Generating project MyPkg:
    /home/tim/.julia/dev/MyPkg/Project.toml
    /home/tim/.julia/dev/MyPkg/src/MyPkg.jl
[lots more output suppressed]
```

In the first few lines you can see the location of your new package, here
the directory `/home/tim/.julia/dev/MyPkg`.

Before doing anything else, let's try it out:

```julia
julia> using Revise   # you must do this before loading any revisable packages

julia> using MyPkg
[ Info: Precompiling MyPkg [102b5b08-597c-4d40-b98a-e9249f4d01f4]

julia> MyPkg.greet()
Hello World!
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

greet() = print("Hello World!")

end # module
```

This is the basic package created by PkgTemplates. Let's modify `greet` to return
a different message:

```julia
module MyPkg

greet() = print("Hello, revised World!")

end # module
```

Now go back to that same Julia session, and try calling `greet` again.
After a pause (the code of Revise and its dependencies is compiling), you should see

```julia
julia> MyPkg.greet()
Hello, revised World!
```

From this point forward, revisions should be fast. You can modify `MyPkg.jl`
quite extensively without quitting the Julia session, although there are some [Limitations](@ref).

## includet usage

The alternative to creating packages is to manually load individual source files.
Note that this works best if these files are simple: if you find you want projects including
other projects, you should switch to the package style above.

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
