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
```

### Internal state management

```@docs
Revise.watched_files
Revise.revision_queue
Revise.included_files
Revise.fileinfos
Revise.module2files
```

## Types

```@docs
Revise.RelocatableExpr
Revise.DefMap
Revise.SigtMap
Revise.FMMaps
Revise.FileModules
Revise.FileInfo
Revise.WatchList
```

## Function reference

### Functions called during initialization of Revise

```@docs
Revise.async_steal_repl_backend
Revise.steal_repl_backend
```

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

### Evaluating changes (revising) and computing diffs

```@docs
Revise.revise_file_now
Revise.eval_revised
Revise.get_method
```

### Parsing source code

```@docs
Revise.parse_source
Revise.parse_source!
Revise.parse_expr!
Revise.parse_module!
Revise.funcdef_expr
Revise.get_signature
Revise.get_callexpr
Revise.signature_names
Revise.sig_type_exprs
Revise.argtypeexpr
```

### Git integration

```@docs
Revise.git_source
Revise.git_files
Revise.git_repo
```
