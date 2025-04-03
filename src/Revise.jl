"""
Revise.jl tracks source code changes and incorporates the changes to a running Julia session.

Revise.jl works behind-the-scenes. To track a package, e.g. `Example`:
```julia
(@v1.6) pkg> dev Example        # make a development copy of the package
[...pkg output omitted...]

julia> using Revise             # this must come before the package under development

julia> using Example

[...develop the package...]     # Revise.jl will automatically update package functionality to match code changes

```

Functions in Revise.jl that may come handy in special circumstances:
- `Revise.track`: track updates to `Base` Julia itself or `Core.Compiler`
- `includet`: load a file and track future changes. Intended for small, quick works
- `entr`: call an additional function whenever code updates
- `revise`: evaluate any changes in `Revise.revision_queue` or every definition in a module
- `Revise.retry`: perform previously-failed revisions. Useful in cases of order-dependent errors
- `Revise.errors`: report the errors represented in `Revise.queue_errors`
"""
module Revise

# We use a code structure where all `using` and `import`
# statements in the package that load anything other than
# a Julia base or stdlib package are located in this file here.
# Nothing else should appear in this file here, apart from
# the `include("packagedef.jl")` statement, which loads what
# we would normally consider the bulk of the package code.
# This somewhat unusual structure is in place to support
# the VS Code extension integration.

using OrderedCollections, CodeTracking, JuliaInterpreter, LoweredCodeUtils

using CodeTracking: PkgFiles, basedir, srcfiles, line_is_decl, basepath
using JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return,
                        @lookup, moduleof, scopeof, pc_expr, is_quotenode_egal,
                        linetable, codelocs, LineTypes, isassign, isidentical
using LoweredCodeUtils: next_or_nothing!, trackedheads, callee_matches

include("packagedef.jl")

end # module
