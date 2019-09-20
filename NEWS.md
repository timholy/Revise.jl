This lists only major changes, and does not include bug fixes,
cleanups, or minor enhancements.

# Revise 2.2

* Revise now warns you when the source files are not synchronized with running code.
  (https://github.com/timholy/Revise.jl/issues/317)

# Revise 2.1

New features:

* Add `entr` for re-running code any time a set of dependent files and/or
  packages change.
  
# Revise 2.0

Revise 2.0 is a major rewrite with
[JuliaInterpeter](https://github.com/JuliaDebug/JuliaInterpreter.jl)
at its foundation.

Breaking changes:

* Most of the internal data structures have changed

* The ability to revise code in Core.Compiler has regressed until technical
  issues are resolved in JuliaInterpreter.
  
* In principle, code that cannot be evaluated twice (e.g., library initialization)
  could be problematic.
  
New features:

* Revise now (re)evaluates top-level code to extract method signatures. This allows
  Revise to identify methods defined by code, e.g., by an `@eval` block.
  Moreover, Revise can identify important changes external to the definition, e.g.,
  if
  
  ```julia
  for T in (Float16, Float32, Float32)
      @eval foo(::Type{$T}) = 1
  end
  ```
  
  gets revised to
  
  ```julia
  for T in (Float32, Float32)
      @eval foo(::Type{$T}) = 1
  end
  ```
  
  then Revise correctly deletes the `Float16` method of `foo`. ([#243])

* Revise handles all method deletions before enacting any new definitions.
  As a consequence, moving methods from one file to another is more robust.
  ([#243])
  
* Revise was split, with a new package
  [CodeTracking](https://github.com/timholy/CodeTracking.jl)
  designed to be the "query" interface for Revise. ([#245])

* Line numbers in method lists are corrected for moving code (requires Julia 1.2 or higher)
  ([#278])

# Revise 1.0 (changes compared to the 0.7 branch)

Breaking changes:

* The internal structure has changed from using absolute paths for
  individual files to a package-level organization that uses
  `Base.PkgId` keys and relative paths ([#217]).

New features:

* Integration with Julia package manager. Revise now follows switches
  from `dev`ed packages to `free`d packages, and also follows
  version-upgrades of `free`d packages ([#217]).

* Tracking code in Julia's standard libraries even for users who
  download Julia binaries. Users of Rebugger will be able to step into
  such methods ([#222]).

[#217]: https://github.com/timholy/Revise.jl/pull/217
[#222]: https://github.com/timholy/Revise.jl/pull/222
[#243]: https://github.com/timholy/Revise.jl/pull/243
[#245]: https://github.com/timholy/Revise.jl/pull/245
[#278]: https://github.com/timholy/Revise.jl/pull/278
