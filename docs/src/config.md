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

## Fixing a broken or partially-working installation

During certain types of usage you might receive messages like

```julia
Warning: /some/system/path/stdlib/v1.0/SHA/src is not an existing directory, Revise is not watching
```

and this indicates that some of Revise's functionality is broken.

Revise's test suite covers a broad swath of functionality, and so if something
is broken a good first start towards resolving the problem is to run `pkg> test Revise`.
Note that some test failures may not really matter to you personally: if, for example, you don't
plan on hacking on Julia's compiler then you may not be concerned about failures
related to `Revise.track(Core.Compiler)`.
However, because Revise is used by [Rebugger](https://github.com/timholy/Rebugger.jl)
and it is common to step into `Base` methods while debugging,
there may be more cases than you might otherwise expect in which you might wish for Revise's
more "advanced" functionality.

In the majority of cases, failures come down to Revise having trouble locating source
code on your drive.
This problem should be fixable, because Revise includes functionality
to update its links to source files, as long as it knows what to do.

Here are some possible test warnings and errors, and steps you might take to fix them:

- `Error: Package Example not found in current path`:
  This (tiny) package is only used for testing purposes, and gets installed automatically
  if you do `pkg> test Revise`, but not if you `include("runtests.jl")` from inside
  Revise's `test/` directory.
  You can prevent the error with `pkg> add Example`.
- `Base & stdlib file paths: Test Failed at /some/path...  Expression: isfile(Revise.basesrccache)`
  This failure is quite serious, and indicates that you will be unable to access code in `Base`.
  To fix this, look for a file called `"base.cache"` somewhere in your Julia install
  or build directory (for the author, it is at `/home/tim/src/julia-1.0/usr/share/julia/base.cache`).
  Now compare this with the value of `Revise.basesrccache`.
  (If you're getting this failure, presumably they are different.)
  An important "top level" directory is `Sys.BINDIR`; if they differ already at this level,
  consider adding a symbolic link from the location pointed at by `Sys.BINDIR` to the
  corresponding top-level directory in your actual Julia installation.
  You'll know you've succeeded in specifying it correctly when, after restarting
  Julia, `Revise.basesrccache` points to the correct file and `Revise.juliadir`
  points to the directory that contains `base/`.
  If this workaround is not possible or does not succeed, please
  [file an issue](https://github.com/timholy/Revise.jl/issues) with a description of
  why you can't use it and/or
  + details from `versioninfo` and information about how you obtained your Julia installation;
  + the values of `Revise.basesrccache` and `Revise.juliadir`, and the actual paths to `base.cache`
    and the directory containing the running Julia's `base/`;
  + what you attempted when trying to fix the problem;
  + if possible, your best understanding of why this failed to fix it.
- `skipping Core.Compiler and stdlibs tests due to lack of git repo`: this likely indicates
  that you downloaded a Julia binary rather than building Julia from source.
  While Revise should be able to access the code in `Base`,
  at the current time it is not possible for Revise to access julia's stdlibs unless
  you clone Julia's repository and build it from source.
- `skipping git tests because Revise is not under development`: this warning should be
  harmless. Revise has built-in functionality for extracting source code using `git`,
  and it uses itself (i.e., its own git repository) for testing purposes.
  These tests run only if you have checked out Revise for development (`pkg> dev Revise`)
  or on the continuous integration servers (Travis and Appveyor).
