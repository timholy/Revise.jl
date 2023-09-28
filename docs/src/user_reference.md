# User reference

There are really only six functions that most users would be expected to call manually:
`revise`, `includet`, `Revise.track`, `entr`, `Revise.retry`, and `Revise.errors`.
Other user-level constructs might apply if you want to debug Revise or
prevent it from watching specific packages, or for fine-grained handling of callbacks.

```@docs
revise
Revise.track
includet
entr
Revise.retry
Revise.errors
```

### Revise logs (debugging Revise)

```@docs
Revise.debug_logger
Revise.actions
Revise.diffs
```

### Prevent Revise from watching specific packages

```@docs
Revise.dont_watch_pkgs
Revise.silence
```

### Revise module

```@docs
Revise
```
