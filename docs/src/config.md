# Configuration

## Using Revise by default

If you like Revise, you can ensure that every Julia session uses it by
adding the following to your `.julia/config/startup.jl` file:

```julia
try
    @eval using Revise
    # Turn on Revise's automatic-evaluation behavior
    Revise.async_steal_repl_backend()
catch err
    @warn "Could not load Revise."
end
```

## System configuration

!!! note "Linux-specific configuration"

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

    at the Linux prompt. **This should be done automatically by Revise's `deps/build.jl` script**,
    but if you encounter the above error consider increasing it further (e.g., to 524288,
    which will allocate half a gigabyte of RAM to file-watching).
    For more information see [issue #26](https://github.com/timholy/Revise.jl/issues/26).

    You can prevent the build script from trying to increase the number of watched files
    by creating an empty file `/path/to/Revise/deps/user_watches`.
    For example, from the Linux prompt use `touch /path/to/Revise/deps/user_watches`.
    This will prevent Revise from prompting you for your password every time the build
    script runs (e.g., when a new version of Revise is installed).

## Configuration options

Revise can be configured by setting environment variables. These variables have to be
set before you execute `using Revise`, because these environment variables are parsed
only during execution of Revise's `__init__` function.

There are several ways to set these environment variables:

- If you are [Using Revise by default](@ref) then you can include statements like
  `ENV["JULIA_REVISE"] = "manual"` in your `.julia/config/startup.jl` file prior to
  the line `@eval using Revise`.
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

Alternatively, you can omit the call to `Revise.async_steal_repl_backend()` from your
`startup.jl` file (see [Using Revise by default](@ref)).

### Polling and NFS-mounted code directories: JULIA\_REVISE\_POLL

`Revise` works by scanning your filesystem for changes to the files that define your code.
Different operating systems and file systems [offer differing levels of support](https://nodejs.org/api/fs.html#fs_caveats)
for this feature.
Because [NFS doesn't support `inotify`](https://stackoverflow.com/questions/4231243/inotify-with-nfs),
if your code is stored on an NFS-mounted volume you should force Revise to use polling:
Revise will periodically (every 5s) scan the modification times of each dependent file.
You turn on polling by setting the environment variable `JULIA_REVISE_POLL` to the
string `"1"` (e.g., `JULIA_REVISE_POLL=1` in a bash script).

If you're using polling, you may have to wait several seconds before changes take effect.
Consequently polling is not recommended unless you have no other alternative.

### User scripts: JULIA\_REVISE\_INCLUDE

By default, `Revise` only tracks files that have been required as a consequence of
a `using` or `import` statement; files loaded by `include` are not
tracked, unless you explicitly use `Revise.track(filename)`. However, you can turn on
automatic tracking by setting the environment variable `JULIA_REVISE_INCLUDE` to the
string `"1"` (e.g., `JULIA_REVISE_INCLUDE=1` in a bash script).
