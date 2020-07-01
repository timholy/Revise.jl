module Revise

using OrderedCollections, CodeTracking, JuliaInterpreter, LoweredCodeUtils
using CodeTracking: PkgFiles, basedir, srcfiles, line_is_decl, basepath
using JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return
using JuliaInterpreter: @lookup, moduleof, scopeof, pc_expr, prepare_thunk, split_expressions,
                        linetable, codelocs, LineTypes, is_GotoIfNot, is_global_ref
using LoweredCodeUtils: next_or_nothing!, isanonymous_typedef, define_anonymous

include("packagedef.jl")

end # module
