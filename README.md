<div align="center"> <img src="images/revise-wordmark.svg" alt="Revise.jl"></img></div>

[![CI](https://github.com/timholy/Revise.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/timholy/Revise.jl/actions/workflows/ci.yml)
[![codecov.io](http://codecov.io/github/timholy/Revise.jl/coverage.svg?branch=master)](http://codecov.io/github/timholy/Revise.jl?branch=master)

`Revise.jl` allows you to modify code and use the changes without restarting Julia.
With Revise, you can be in the middle of a session and then update packages, switch git branches,
and/or edit the source code in the editor of your choice; any changes will typically be incorporated
into the very next command you issue from the REPL.
This can save you the overhead of restarting Julia, loading packages, and waiting for code to JIT-compile.

See the [documentation](https://timholy.github.io/Revise.jl/stable):

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://timholy.github.io/Revise.jl/stable)

In particular, most users will probably want to alter their `.julia/config/startup.jl` file
to run Revise automatically, as described in the [Configuration section](https://timholy.github.io/Revise.jl/stable/config/#Using-Revise-by-default-1) of the documentation.

## Credits

Revise became possible because of Jameson Nash's fix of [Julia issue 265](https://github.com/JuliaLang/julia/issues/265).
[Julia for VSCode](https://www.julia-vscode.org/) and [Juno](http://junolab.org/) are IDEs that offer an editor-based mechanism for achieving a subset of
Revise's aims.

## Major releases

- Both the current 3.x and 2.x release cycles use JuliaInterpreter to step through your module-defining code.
- The 1.x release cycle does not use JuliaInterpreter, but does integrate with Pkg.jl. Try this if the more recent releases give you trouble. (But please report the problems first!)
- For Julia 0.6 [see this branch](https://github.com/timholy/Revise.jl/tree/v0.6). However, you really shouldn't be using Julia 0.6 anymore!

See the [NEWS](NEWS.md) for additional information.
