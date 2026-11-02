# Configuration

!!! compat
    These instructions are applicable only for Julia 1.5 and higher. If you are running an older version of Julia, upgrading to at least 1.6 is recommended. If you cannot upgrade, see the documentation for Revise 3.2.x or earlier.

## Using Revise by default

If you like Revise, you can ensure that every Julia session uses it by
launching it from your `~/.julia/config/startup.jl` file.
Note that using Revise adds a small latency at Julia startup, generally about 0.7s when you first launch Julia and another 0.25s for your first package load.
Users should weigh this penalty against whatever benefit they may derive from not having to restart their entire session.

This can be as simple as adding

```julia
using Revise
```
as the first line in your `startup.jl`. If you have a Unix terminal available, simply run
```bash
mkdir -p ~/.julia/config/ && echo "using Revise" >> ~/.julia/config/startup.jl
```

If you use different package environments and do not always have Revise available,

```julia
try
    using Revise
catch e
    @warn "Error initializing Revise" exception=(e, catch_backtrace())
end
```

is recommended instead.

### Using Revise automatically within Jupyter/IJulia

IJulia has an integration with Revise and will automatically add it as a
[preexecute
hook](https://julialang.github.io/IJulia.jl/stable/library/public/#IJulia.push_preexecute_hook)
if Revise is loaded (e.g. through your `startup.jl`), *unless* the
`JULIA_REVISE` environment variable is set to something other than `auto`.

## [Editor configuration](@id edcfg)

At present, `vim` is the only editor known to benefit from configuration: if needed, you should modify your settings file so that `backupcopy=yes`.

More generally, Revise uses file-watching, and any editor that saves files with the following sequence:

1. rename the old version to a backup
2. write the new file

will generate *two* triggers per save; if Revise reacts to the "disappearance" of the file after step 1, it may end up needlessly deleting methods, and even if they get redefined after step 2, you'll need to recompile all the code the next time you execute any dependent methods.

Your best option is to change your editor settings, if possible, to ensure that Revise is triggered only after the new file is finished writing. Either of:

1. write the new file to a temporary name
2. rename the temporary to the real file name

or

1. save the old file to a backup name
2. write the new data to the real file name

should work fine. In `vim`, `backupcopy=yes` forces the latter of these two behaviors.

## Configuring the revise mode

By default, in packages all changes are tracked, but with `includet` only method definitions are tracked.
This behavior can be overridden by defining a variable `__revise_mode__` in the module(s) containing
your methods and/or data. `__revise_mode__` must be a `Symbol` taking one of the following values:

- `:eval`: evaluate everything (the default for packages)
- `:evalmeth`: evaluate changes to method definitions (the default for `includet`)
  This should work even for quite complicated method definitions, such as those that might
  be made within a `for`-loop and `@eval` block.
- `:evalassign`: evaluate method definitions and assignment statements. A top-level expression
  `a = Int[]` would be evaluated, but `push!(a, 1)` would not because the latter is not an assignment.
- `:sigs`: do not implement any changes, only scan method definitions for their signatures so that
  their location can be updated as changes to the file(s) are made. `using`, `import`, and `export`
  statements added by a revision are still executed, because a signature may be written in terms of
  a name the new statement brings into scope.

If you're using `includet` from the REPL, you can enter `__revise_mode__ = :eval` to set
it throughout `Main`. `__revise_mode__` can be set independently in each module.

### [Reevaluating dependent statements](@id revise-dependents)

By default, Revise reevaluates only the top-level statements whose text changed. An unchanged
statement keeps the value it computed from the old code: after editing `struct S`, an unchanged
`const K = S(1)` still holds an instance of the old `S`, and after editing `A = 1`, an unchanged
`B = [A]` still holds `[1]`.

Calling `Revise.set_revise_dependents(true)` (Julia 1.13+) makes Revise also reevaluate every
unchanged top-level statement that reads a global binding the revision changed, or calls code
that the revision changed, transitively and across all tracked files. A binding counts as
changed if

- a changed, removed, or reevaluated statement assigns it, also inside a method it calls, as
  `set(x) = (global A = x)` does,
- it is a type that the revision redefined, or
- it is a function with a method changed in the function's module.

Reads include those inside the methods a statement calls: `const C = f()` is reevaluated when
a global that the body of `f` reads changes. Asking about a global, as
`isdefined(@__MODULE__, :A)`, `@isdefined(A)`, or `isconst(@__MODULE__, :A)` do, reads it too,
also in a method that gets the name as an argument, as `has(s) = isconst(@__MODULE__, s)` does
for `has(:A)`. A statement also reads a global it assigns if it may read the old value first,
as `A = A + 1` does. `include(mapexpr, path)`
reads what `mapexpr` reads, and reevaluating it applies the current `mapexpr` to the file
again. Code counts as changed when Julia would compile it
anew, e.g. after a change of a method it calls, of a `const` it reads, or of a method added to
a function of another module such as `Base.show(io::IO, x::T)`.

Revise treats each dependent statement as if it had changed:

- It runs after the statements it depends on. Relative to the statements that mutate a global
  it reads, it keeps the order in which loading runs them, with the statements of an included
  file at the place of the `include`, and those of a nested module between those of its parent.
- Its module's revise mode applies, as listed above. Under `:sigs`, for example, it is not
  reevaluated.
- Its methods whose signature changed are deleted after it ran. After a change of `A`,
  `f(x::A) = …` therefore leaves only the method for the new `A`.

An edited statement runs once more if it reads a binding that a dependent statement assigns,
because it ran before that statement, or if code it calls changed after it ran, as `f()` does in
`const B = f()` once a dependent statement redefines a `const` that `f` reads. A statement runs
at most four times in one revision. A dependent statement that throws runs again at every
later revision, including the one `Revise.retry()` starts, until it succeeds.

A statement that may mutate a global, such as `push!(a, x)`, makes Revise rebuild `a`. This
applies to dependent statements and to edited or removed ones. Revise reevaluates the
statements that assign `a`, and then every statement that reads it. So after `x` changes, `a`
holds the new `x` instead of both values. Revise follows each call into the methods it reaches
to find what they mutate: `length(a)` mutates nothing, `push!(a, x)` mutates `a`, and
`register(:a)`, whose body runs `push!(REG, :a)`, mutates `REG`, so every statement that calls
`register` runs again after `REG` is rebuilt. After a change of `register`, the globals that
its old and its new body mutate are both rebuilt.

A value that may share memory with a global counts as that global. `push!(get!(D, k, Int[]), x)`
rebuilds `D`, and `push!(getglobal(M, :a), x)` rebuilds `a`, also through a method that gets
the name as an argument or when a global holds the name. After `b = a`, `push!(b, x)` rebuilds
both `b` and `a`. Once `b = a` becomes `b = c`, it rebuilds `a` as well, which its last run
mutated, and the same holds when the module or the name that selects the mutated global
changes. `a = push!(a, x)` rebuilds
`a`, since it assigns the mutated old value, and so does `a = a + 1`, since it computes the new
value from the old one. So does a call of `inc() = (global a += 1)`.

To turn this on in every session, set the `revise_dependents` preference in the
`LocalPreferences.toml` file of your active project:

```toml
[Revise]
revise_dependents = true
```

This is off by default because a selected statement runs again with all its side effects.
Keep in mind:

- Statements of `Base` and the compiler are never reevaluated as dependents, even after
  `Revise.track(Base)`, because they define the code the session itself runs on. An edited
  statement of `Base` still runs, and the statements of your packages that depend on it are
  reevaluated.
- A rebuilt global holds only what tracked statements of modules with revise mode `:eval` put
  into it.
  - Revise therefore does not rebuild a global whose name occurs in the definition of its
    module's `__init__` or that this `__init__` may read or mutate, that a statement of a
    module with another revise mode assigns or mutates, or that no tracked statement assigns,
    e.g. a global of `Base`. A mutating statement then runs again on the old value:
    `push!(a, x)` adds a second element.
  - Changes from untracked code are lost, e.g. entries a function added at run time to a
    cache, or a `push!(MyPkg.a, x)` typed at the REPL.
  - A variable or field that refers to the old object, such as `v = MyPkg.a` at the REPL,
    still refers to the old object.
- Some rebuilds are unnecessary, because a call counts as mutating whenever it may or may
  not be mutating:
  - A call that reaches code Revise cannot follow counts as mutating every argument whose
    type can hold mutable memory, and its result as sharing memory with every argument. Such
    code includes calls of `eval` or `include`, of unknown C functions, and of a function that
    a global holds unless the global is `const`.
  - A call whose argument types match more than three methods counts as code Revise cannot
    follow. A global that is not `const` has its declared type, usually `Any`, unless it holds a
    module: `Alias.x` reads `x` of the module that `Alias` currently holds. A variable local
    to a top-level `let` block or loop has the types of all values assigned to it.
  - A statement that Revise cannot analyze, e.g. one that calls a macro that no longer exists,
    counts as mutating every global it mentions.
  - A statement whose calls reach more code than a safety limit of 200,000 lowered statements
    counts as reading every global, so every revision that changes a binding reevaluates it.
    The largest statements of real packages reach about 40,000.
  - A statement that reads or asks about a global whose name is not known, e.g. one that
    loops over `names(M)`, counts as reading every global as well, also when output code
    reaches such a read.
- Some dependencies are not detected:
  - A mutation of a global whose name is computed, as in `push!(getglobal(M, Symbol(:a, i)), x)`.
    Only a quoted name or one that a global holds is known.
  - A read or mutation of a global inside code that Revise cannot follow, unless the global is
    passed as an argument.
  - A read or mutation of a global by output code of an untracked package, or by a method of
    a tracked package that output reaches through a printed value or a stream of unknown
    type. Revise assumes that output functions such as `print` mutate nothing but
    their stream and the globals that the methods of tracked packages they may reach mutate:
    output methods such as `show` for the printed value, and the methods for the types of
    tracked packages that the stream or the printed value holds, such as `getindex` of an
    array type or `write` of a stream type. It also assumes that logging, locks,
    `precompile`, and docstrings do not affect a value a statement computes.
  - A change of code outside tracked files, e.g. a method defined at the REPL. Revise
    analyzes the statements that call the code again, but does not reevaluate them.
  - A change of a method of a function of `Base`, such as `show(io::IO, x::T)`, in a statement
    of a package that requires neither the package defining the method nor one that owns a
    type in its signature. Such a statement can reach the method only through a value it gets
    from elsewhere, e.g. from a registry of another package.
- The first revision analyzes every top-level statement of the revised packages, of the
  packages that own a function or type named in the signature of a changed method, of the
  packages that depend on any of them, and of `Main`. This can take several seconds. Later
  revisions analyze only the statements that changed or that call code that changed. With
  [`Revise.prepare_ahead`](@ref) (see [Preparing revisions ahead](@ref prepare-ahead)), Revise
  does this analysis before you edit, so the first revision is usually fast as well. In an
  interactive session started with an interactive thread (the default on Julia 1.13+), the
  statements that call no macro of a package are analyzed in the background, shortly after
  Revise starts tracking a package or file. The others, whose macros may change state that code
  running at the same time uses, are analyzed while the REPL waits for input, and so are all
  statements without an interactive thread. The background analysis skips the standard
  libraries.

## [Preparing revisions ahead](@id prepare-ahead)

Revise can prepare the revisions of the tracked code while the REPL waits for your next
command: it parses the files and extracts the method signatures they define, which a revision
otherwise does when it first edits a file, and with `revise_dependents` it also analyzes the
dependencies of the tracked statements. The first edit of a large file then takes milliseconds
instead of seconds.

The preparation runs code of the tracked packages, as a revision does, but between your
commands. A command waits for the step in progress, such as parsing one file. Without a REPL,
for example in a script, or with `JULIA_REVISE=manual`, nothing is prepared ahead. To turn the
preparation on, set `Revise.prepare_ahead[] = true`, or the `prepare_ahead` preference to
`true` via [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl) by adding the
following to the `LocalPreferences.toml` file in your active project:

```toml
[Revise]
prepare_ahead = true
```

## Optional global configuration

Revise can be configured by setting environment variables. These variables have to be
set before you execute `using Revise`, because these environment variables are parsed
only during execution of Revise's `__init__` function.

There are several ways to set these environment variables:

- If you are [Using Revise by default](@ref) then you can include statements like
  `ENV["JULIA_REVISE"] = "manual"` in your `.julia/config/startup.jl` file prior to
  the line containing `using Revise`.
- On Unix systems, you can set variables in your shell initialization script
  (e.g., put lines like `export JULIA_REVISE=manual` in your
  [`.bashrc` file](https://www.linuxfromscratch.org/blfs/view/svn/postlfs/profile.html)
  if you use `bash`).
- On Unix systems, you can launch Julia from the Unix prompt as `$ JULIA_REVISE=manual julia`
  to set options for just that session.

The function of specific environment variables is described below.

### Manual revision: JULIA_REVISE

By default, Revise processes any modified source files every time you enter
a command at the REPL.
However, there might be times where you'd prefer to exert manual control over
the timing of revisions. `Revise` looks for an environment variable
`JULIA_REVISE`, and if it is set to anything other than `"auto"` it
will require that you manually call `revise()` to update code.

### User scripts: JULIA\_REVISE\_INCLUDE

By default, `Revise` only tracks files that have been required as a consequence of
a `using` or `import` statement; files loaded by `include` are not
tracked, unless you explicitly use `includet` or `Revise.track(filename)`. However, you can turn on
automatic tracking by setting the environment variable `JULIA_REVISE_INCLUDE` to the
string `"1"` (e.g., `JULIA_REVISE_INCLUDE=1` in a bash script).

!!! note
    Most users should avoid setting `JULIA_REVISE_INCLUDE`.
    Try `includet` instead.

### Disabling struct revision

On Julia 1.12+, Revise automatically revises `struct` definitions in a running
session; see [Limitations](@ref) for details. When a changed definition
requires deleting a type, Revise scans the session's method tables and type
hierarchy to find dependents, which can make such revisions slower than
ordinary ones. To disable struct revision (so that struct changes once again
require a session restart), set the `revise_structs` preference to `false` via
[Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl).

Add the following to the `LocalPreferences.toml` file in your active project:

```toml
[Revise]
revise_structs = false
```

## Configurations for fixing errors

### No space left on device

!!! note
    This applies only to Linux

Revise needs to be notified by your filesystem about changes to your code,
which means that the files that define your modules need to be watched for updates.
Some systems impose limits on the number of files and directories that can be
watched simultaneously; if such a limit is hit, on Linux this can result in Revise silently ceasing to work
(albeit with unit tests failing) or in a fairly cryptic error like

```sh
ERROR: start_watching (File Monitor): no space left on device (ENOSPC)
```

The cure is to investigate and possibly increase the number of files that can be watched.

Invoking
```sh
$ sysctl fs.inotify
```
at the linux prompt may e.g. result in
```
fs.inotify.max_queued_events = 16384
fs.inotify.max_user_instances = 128
fs.inotify.max_user_watches = 524288
```

For Revise usage, `max_user_watches >= 65536` is recommended, and more can be helpful; the value of 524288 above is common on modern systems. One can set higher values as needed, e.g.,
```sh
$ sudo sysctl fs.inotify.max_user_instances=2048
```
After changing these values, it is advised to run Revise's unit tests to see if they pass.

This change can be made [permanent](https://support.scc.suse.com/s/kb/360054835111).

For more information see issues [#26](https://github.com/timholy/Revise.jl/issues/26)
and  [#778](https://github.com/timholy/Revise.jl/issues/778).


### Polling and NFS-mounted code directories: JULIA\_REVISE\_POLL

!!! note
    This applies only to Unix systems with code on network-mounted drives

`Revise` works by monitoring your filesystem for changes to the files that define your code.
On most operating systems, Revise can work "passively" and wait to be signaled
that one or more watched directories has changed.

Unfortunately, a few file systems (notably, the Unix-based Network File System NFS) don't support this approach. In such cases, Revise needs to "actively" check each file periodically to see whether it has changed since the last check. This active process is called [polling](https://en.wikipedia.org/wiki/Polling_(computer_science)).
You turn on polling by setting the environment variable `JULIA_REVISE_POLL` to the
string `"1"` (e.g., `JULIA_REVISE_POLL=1` in a bash script).

!!! warning
    If you're using polling, you may have to wait several seconds before changes take effect.
    Polling is *not* recommended unless you have no other alternative.

!!! note
    NFS stands for [Network File System](https://en.wikipedia.org/wiki/Network_File_System) and is typically only used to mount shared network drives on *Unix* file systems.
    Despite similarities in the acronym, NTFS, the standard [filesystem on Windows](https://en.wikipedia.org/wiki/NTFS), is completely different from NFS; Revise's default configuration should work fine on Windows without polling.

!!! note
    Under WSL, the Windows filesystem mounted at `/mnt/...` does not deliver file-change
    notifications to Linux (an upstream [WSL bug](https://github.com/microsoft/WSL/issues/4739),
    surfaced in Julia as [this issue](https://github.com/JuliaLang/julia/issues/37029)).
    Revise detects this case automatically and falls back to polling for code stored there,
    so you should not need to set `JULIA_REVISE_POLL` manually. Code kept in the native Linux
    filesystem (e.g. under your home directory) continues to use fast notification-based watching.
    Polling these `/mnt/...` files means revisions may take a few seconds to register.
