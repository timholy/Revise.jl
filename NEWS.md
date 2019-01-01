This lists only major changes, and does not include bug fixes,
cleanups, or minor enhancements.

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
