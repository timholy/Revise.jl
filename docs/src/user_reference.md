# User reference

There are really only a handful of functions that most users would be expected to call manually:
`revise`, `includet` (or [`@includet`](@ref)), `Revise.track`, `entr`, `Revise.retry`, `Revise.errors`,
`Revise.duplicate_methods`, and `Revise.stale_load`.
Other user-level constructs might apply if you want to debug Revise or
prevent it from watching specific packages, or for fine-grained handling of callbacks.

```@docs
revise
Revise.track
includet
@includet
entr
Revise.retry
Revise.errors
Revise.duplicate_methods
Revise.stale_load
```

### Revise logs (debugging Revise)

```@docs
Revise.debug_logger
Revise.actions
Revise.diffs
```

### Prevent Revise from watching specific packages

```@docs
Revise.dont_watch
Revise.allow_watch
Revise.dont_watch_pkgs
Revise.silence
Revise.unsilence
```

### Tolerance for missing files

```@docs
Revise.missing_file_grace
```

### Revise module

```@docs
Revise
```
