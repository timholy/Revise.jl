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
                        linetable, codelocs, LineTypes, is_GotoIfNot, isassign, isidentical
using LoweredCodeUtils: next_or_nothing!, trackedheads, structheads, callee_matches

include("packagedef.jl")

end # module
