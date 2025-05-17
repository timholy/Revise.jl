# Revise.jl Development Guide

This package provides developer support functionality to track code changes and reload definitions within a running Julia session.

## Build/Test Commands
- Run build: `jld4 --project -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'`
- Run all tests: `jld4 --project -e 'using Pkg; Pkg.test()'`
- Run specific test: `jld4 --project -e 'using Pkg; Pkg.test(test_args=["TestName"])'`
- Run with file watching: `jld4 --project -e 'using Pkg; Pkg.test(test_args=["REVISE_TESTS_WATCH_FILES"])'`
- Run with polling: `JULIA_REVISE_POLL=1 jld4 --project -e 'using Pkg; Pkg.test()'`

## Code Style Guidelines
- Follow standard Julia style conventions
- Include type annotations for function arguments and returns
- Keep function docstrings comprehensive and up-to-date
- Use NamedTuples for multiple return values
- Error messages should be clear and actionable
- Prefer immutable data structures where possible
- Test critical functionality with appropriate test cases

## Dependencies
- Main dependencies: CodeTracking, JuliaInterpreter, FileWatching, LibGit2, LoweredCodeUtils
- Requires Julia 1.11 or newer (use `jld4` for development)

## Development Notes
- The package is designed to track code changes and reload definitions
- This package is closely tied to its dependencies.
  In particular, the following dependency packages are critical, so please refer to them as needed.
  - [CodeTracking.jl](../CodeTracking/)
  - [JuliaInterpreter.jl](../JuliaInterpreter/)
  - [LoweredCodeUtils.jl](../LoweredCodeUtils/)
- File watching uses either inotify (Linux), FSEvents (macOS), or polling
- Consider performance impact on large codebases
