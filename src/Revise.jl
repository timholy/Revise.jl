"""
Revise.jl tracks source code changes and incorporates the changes to a running Julia session.

Revise.jl works behind-the-scenes. To track a package, e.g. `Example`:
```julia-repl
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

using ReviseCore: OrderedCollections, CodeTracking, JuliaInterpreter, LoweredCodeUtils
using .CodeTracking: MethodInfoKey, PkgFiles
using .JuliaInterpreter: Compiled, Frame

using ReviseCore

using ReviseCore:
    CodeTrackingMethodInfo, DoNotParse, ExprsSigs, FileInfo, LoweringException, MethodSummary,
    ModuleExprsSigs, PkgData, RelocatableExpr, ReviseEvalException, TaskThunk,
    _debug_logger, _methods_by_execution!, add_modexs!, basebuilddir, basedir, basesrccache,
    bodymethod, cache_file_key, delete_missing!, empty_exs_sigs, eval_new!, eval_rex,
    fallback_juliadir, file_exists, fileindex, fileinfo, fixpath, handle_deletions, hasfile,
    instantiate_sigs!, is_some_include, juliadir, maybe_extract_sigs!,
    maybe_parse_from_cache!, methods_by_execution!, minimal_evaluation!, parse_source,
    parse_source!, read_from_cache, src_file_key, srcfiles, trim_toplevel!, unwrap

# Abstract Distributed API
using ReviseCore:
    AbstractWorker, DistributedWorker, register_workers_function, remotecall_impl,
    is_master_worker

include("packagedef.jl")

end # module
