# News

This file describes only major changes, and does not include bug fixes,
cleanups, or minor enhancements.

## Revise 3.3

* Upgrade to JuliaInterpreter 0.9 and drop support for Julia prior to 1.6 (the new LTS).

## Revise 3.2

* Switch to synchronous processing of new packages and `@require` blocks.
  This is motivated by changes in Julia designed to make code-loading threadsafe.
  There are small (100-200ms) increases in latency on first use, but more guarantees that
  Revise's workqueue will finish before new operations commence.

## Revise 3.0

* Latencies at startup and upon first subsequent package load are greatly reduced.
* Support for selective evaluation: by default, `includet` will use a mode in which only
  method definitions, not "data," are revised. By default, packages still
  re-evaluate every changed expression, but packages can opt out of this behavior
  by defining `__revise_mode__ = :evalmeth`. See the documentation for details.
  This change should make `includet` more resistant to long latencies and other bad behavior.
* Evaluations now happen in order of dependency: if PkgA depends on PkgB,
  PkgB's evaluations will occur before PkgA's. Likewise, if a package loads `"file1.jl"` before
  `"file2.jl"`, `"file1.jl`"'s evaluations will be processed first.
* Duplicating a method and then deleting one copy no longer risks deleting the method from your
  session--method deletion happens only when the final copy is removed.
* Error handling has been extensively reworked. Messages and stacktraces should be more consistent
  with the error reporting of Julia itself. Only the first error in each file is shown.
  Users are reminded of outstanding revision errors only by changing the prompt color to yellow.
* By default, Revise no longer tracks its own code or that of its dependencies.
  Call `Revise.add_revise_deps()` (before making any changes) if you want Revise to track its
  own code.

## Revise 2.7

* Add framework for user callbacks
* Faster startup and revision, depending on Julia version

## Revise 2.6

* Starting with Julia 1.5 it will be possible to run Revise with just `using Revise`
  in your `startup.jl` file. Older Julia versions will still need the
  backend-stealing code.

## Revise 2.5

* Allow previously reported errors to be re-reported with `Revise.errors()`

## Revise 2.4

* Automatic tracking of methods and included files in `@require` blocks
  (needs Requires 1.0.0 or higher)

## Revise 2.3

* When running code (e.g., with `includet`), execute lines that "do work" rather than
  "define methods" using the compiler. The greatly improves performance in
  work-intensive cases.
* When analyzing code to compute method signatures, omit expressions that don't contribute
  to signatures. By skipping initialization code this leads to improved safety and
  performance.
* Switch to an O(N) algorithm for renaming frame methods to match their running variants.
* Support addition and deletion of source files.
* Improve handling and printing of errors.

## Revise 2.2

* Revise now warns you when the source files are not synchronized with running code.
  (https://github.com/timholy/Revise.jl/issues/317)

## Revise 2.1

New features:

* Add `entr` for re-running code any time a set of dependent files and/or
  packages change.

## Revise 2.0

Revise 2.0 is a major rewrite with
[JuliaInterpreter](https://github.com/JuliaDebug/JuliaInterpreter.jl)
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

## Revise 1.0 (changes compared to the 0.7 branch)

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
