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

If you want Revise to launch automatically within IJulia, then you should also create a `.julia/config/startup_ijulia.jl` file with the contents

```julia
try
    @eval using Revise
catch e
    @warn "Error initializing Revise" exception=(e, catch_backtrace())
end
```
or simply run
```bash
mkdir -p ~/.julia/config/ && tee -a  ~/.julia/config/startup_ijulia.jl << END
try
    @eval using Revise
catch e
    @warn "Error initializing Revise" exception=(e, catch_backtrace())
end
END
```

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
  their location can be updated as changes to the file(s) are made.

If you're using `includet` from the REPL, you can enter `__revise_mode__ = :eval` to set
it throughout `Main`. `__revise_mode__` can be set independently in each module.

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
  [`.bashrc` file](http://www.linuxfromscratch.org/blfs/view/svn/postlfs/profile.html)
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

## Configurations for fixing errors

### No space left on device

!!! note
    This applies only to Linux

Revise needs to be notified by your filesystem about changes to your code,
which means that the files that define your modules need to be watched for updates.
Some systems impose limits on the number of files and directories that can be
watched simultaneously; if this limit is hit, on Linux this can result in a fairly cryptic
error like

```sh
ERROR: start_watching (File Monitor): no space left on device (ENOSPC)
```

The cure is to increase the number of files that can be watched, by executing

```sh
echo 65536 | sudo tee -a /proc/sys/fs/inotify/max_user_watches
```

at the Linux prompt. (The maximum value is 524288,
which will allocate half a gigabyte of RAM to file-watching).
For more information see [issue #26](https://github.com/timholy/Revise.jl/issues/26).

Changing the value this way may not last through the next reboot,
but [you can also change it permanently](https://askubuntu.com/questions/716431/inotify-max-user-watches-value-resets-on-reboot-how-to-change-it-permanently).

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
    However, WSL2 users currently need polling due to [this bug](https://github.com/JuliaLang/julia/issues/37029).
