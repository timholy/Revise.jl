# Developer reference: dependent statements

These implement [`Revise.revise_dependents`](@ref). See [When the work is done](@ref work-ahead)
for when Revise analyzes the statements.

A cached result that no longer holds is not brought up to date early: the revision that finds
it invalid learns from that which statements call code that changed.

```@docs
Revise.GlobalDeps
Revise.observed_reads
Revise.evaluated_deps
Revise.record_observed!
Revise.evaluated_code_deps
Revise.named_access_call
Revise.global_deps
Revise.expand_stmt
Revise.expand_literal_evals
Revise.expanded_deps
Revise.literal_eval
Revise.is_definition_call
Revise.expands_package_macro
Revise.old_value_reads
Revise.fallback_deps
Revise.strip_bodies
Revise.add_qualified_method_write!
Revise.add_namespace_writes!
Revise.assumed_value
Revise.is_include_function
Revise.add_transform_reads!
Revise.may_hold_mutable
Revise.may_hold_ref
Revise.value_may_hold_ref
Revise.stmt_key
Revise.cache_global_deps!
Revise.cache_deps!
Revise.DepIndex
Revise.refresh_index!
Revise.check_dep_index
Revise.affected_tracked
Revise.request_analysis_ahead
Revise.analyze_ahead
Revise.idle_work
Revise.idle_extract_sigs!
Revise.IdleCancelled
Revise.dependency_seeds
Revise.add_method_owners!
Revise.required_modules
Revise.prepare_dependents!
Revise.reeval_dependent_statements!
Revise.remove_includes!
Revise.rank_by_inclusion!
```
