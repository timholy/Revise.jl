# User reference

There are really only three functions that a user would be expected to call manually:
`revise`, `includet`, and `Revise.track`.
Other user-level constructs might apply if you want to debug Revise or
prevent it from watching specific packages.

```@docs
revise
Revise.track
includet
Revise.debug_logger
Revise.dont_watch_pkgs
Revise.silence
```
