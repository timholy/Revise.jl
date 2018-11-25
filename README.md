![splash](images/logo.png)

# Revise

**NOTE: this page is for Julia 0.7.0-alpha and higher. For Julia 0.6 [see this branch](https://github.com/timholy/Revise.jl/tree/v0.6)**

[![Build Status](https://travis-ci.org/timholy/Revise.jl.svg?branch=master)](https://travis-ci.org/timholy/Revise.jl)
[![Build status](https://ci.appveyor.com/api/projects/status/e1xnsj4e5q9308y6/branch/master?svg=true)](https://ci.appveyor.com/project/timholy/revise-jl/branch/master)
[![codecov.io](http://codecov.io/github/timholy/Revise.jl/coverage.svg?branch=master)](http://codecov.io/github/timholy/Revise.jl?branch=master)

`Revise.jl` may help you keep your sessions running longer, reducing the
need to restart Julia whenever you make changes to code.
With Revise, you can be in the middle of a session and then update packages, switch git branches
or stash/unstash code,
and/or edit the source code; typically, the changes will be incorporated
into the very next command you issue from the REPL.
This can save you the overhead of restarting, loading packages, and waiting for code to JIT-compile.

See the [documentation](https://timholy.github.io/Revise.jl/stable):

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://timholy.github.io/Revise.jl/stable)
[![](https://img.shields.io/badge/docs-latest-blue.svg)](https://timholy.github.io/Revise.jl/latest)

In particular, most users will probably want to alter their `.julia/config/startup.jl` file
to run Revise automatically, as described in the "Configuration" section of the documentation.

## Credits

Revise became possible because of Jameson Nash's fix of [Julia issue 265](https://github.com/JuliaLang/julia/issues/265).
[Juno](http://junolab.org/) is an IDE that offers an editor-based mechanism of achieving some
of the same aims.
