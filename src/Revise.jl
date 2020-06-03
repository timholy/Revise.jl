module Revise

using OrderedCollections, CodeTracking, JuliaInterpreter, LoweredCodeUtils
using CodeTracking: PkgFiles, basedir, srcfiles
using JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return
using JuliaInterpreter: @lookup, moduleof, scopeof, pc_expr, prepare_thunk, split_expressions,
                        linetable, codelocs, LineTypes
using LoweredCodeUtils: next_or_nothing!, isanonymous_typedef
using CodeTracking: line_is_decl
using JuliaInterpreter: is_global_ref
using CodeTracking: basepath

include("core.jl")

end # module
