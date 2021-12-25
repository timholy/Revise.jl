# Developer reference

## Internal global variables

### Configuration-related variables

These are set during execution of Revise's `__init__` function.

```@docs
Revise.watching_files
Revise.polling_files
Revise.tracking_Main_includes
```

### Path-related variables

```@docs
Revise.juliadir
Revise.basesrccache
Revise.basebuilddir
```

### Internal state management

```@docs
Revise.pkgdatas
Revise.watched_files
Revise.revision_queue
Revise.NOPACKAGE
Revise.queue_errors
Revise.included_files
```

The following are specific to user callbacks (see [`Revise.add_callback`](@ref)) and
the implementation of [`entr`](@ref):

```@docs
Revise.revision_event
Revise.user_callbacks_queue
Revise.user_callbacks_by_file
Revise.user_callbacks_by_key
```

## Types

```@docs
Revise.RelocatableExpr
Revise.ModuleExprsSigs
Revise.FileInfo
Revise.PkgData
Revise.WatchList
Revise.TaskThunk
Revise.ReviseEvalException
MethodSummary
```

## Function reference

### Functions called when you load a new package

```@docs
Revise.watch_package
Revise.parse_pkg_files
Revise.init_watching
```

### Monitoring for changes

These functions get called on each directory or file that you monitor for revisions.
These block execution until the file(s) are updated, so you should only call them from
within an `@async` block.
They work recursively: once an update has been detected and execution resumes,
they schedule a revision (see [`Revise.revision_queue`](@ref)) and
then call themselves on the same directory or file to wait for the next set of changes.

```@docs
Revise.revise_dir_queued
Revise.revise_file_queued
```

The following functions support user callbacks, and are used in the implementation of `entr`
but can be used more broadly:

```@docs
Revise.add_callback
Revise.remove_callback
```

### Evaluating changes (revising) and computing diffs

[`revise`](@ref) is the primary entry point for implementing changes. Additionally,

```@docs
Revise.revise_file_now
```

### Caching the definition of methods

```@docs
Revise.get_def
```

### Parsing source code

```@docs
Revise.parse_source
Revise.parse_source!
```

### Lowered source code

Much of the "brains" of Revise comes from doing analysis on lowered code.
This part of the package is not as well documented.

```@docs
Revise.minimal_evaluation!
Revise.methods_by_execution!
Revise.CodeTrackingMethodInfo
```

### Modules and paths

```@docs
Revise.modulefiles
```

### Handling errors

```@docs
Revise.trim_toplevel!
```

In current releases of Julia, hitting Ctrl-C from the REPL can stop tasks running in the background.
This risks stopping Revise's ability to watch for changes in files and directories.
Revise has a work-around for this problem.

```@docs
Revise.throwto_repl
```

### Git integration

```@docs
Revise.git_source
Revise.git_files
Revise.git_repo
```

### Distributed computing

```@docs
Revise.init_worker
```
