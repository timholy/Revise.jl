"""
    Revise.revise_dependents

A `Ref{Bool}` (default `false`) controlling whether [`revise`](@ref) reevaluates unchanged
top-level statements that read a global binding the revision changed.

This requires Julia 1.13 or later. On older versions, `true` logs a warning at the first
revision and is otherwise ignored.

When it is `true`, a statement such as `const K = S(1)` is reevaluated after the definition
of `S` changes, and `const B = [A]` after the value of `A` changes, transitively and across
tracked files. A selected statement is evaluated as if it had changed, with the revise mode
of its module (see `__revise_mode__`), so in `:sigs` modules nothing is reevaluated. A global
that a statement may mutate, as in `push!(a, x)`, is rebuilt from the statements that assign
it, unless its module's `__init__` mentions it. Statements with side effects run again when
selected, which is why this is off by default.

The initial value comes from the `revise_dependents` preference. Setting the `Ref` takes
effect at the next revision. [`Revise.set_revise_dependents`](@ref) also prepares the code that
is already tracked.
"""
const revise_dependents = Ref(false)

"""
    Revise.prepare_ahead

A `Ref{Bool}` (default `false`) controlling whether Revise prepares revisions before they are needed, while the REPL waits for input.

Revise then parses the tracked files and extracts the method signatures they define, which a
revision otherwise does when it first edits a file, and with [`Revise.revise_dependents`](@ref)
also analyzes the dependencies of the tracked statements. This runs code of the tracked
packages as a revision would, but between your commands: a command waits for the unit in
progress, such as parsing one file or analyzing one statement, and cancels a run of a statement
in `:sigs` mode at its next step (see [`Revise.idle_work`](@ref)). Without a REPL, or with
`JULIA_REVISE=manual`, nothing is prepared ahead. A call of [`revise`](@ref) while the REPL
waits for input, as an editor makes before running code, stops the preparation until the next
REPL command.

The initial value comes from the `prepare_ahead` preference. Setting the `Ref` to `false`
stops the preparation after the unit in progress.
"""
const prepare_ahead = Ref(false)

# The dependency analysis recognizes global writes by the builtins Julia 1.13 lowers them to.
const dependents_supported = isdefined(Core, :declare_const) && isdefined(Core, :declare_global)

function dependents_active()
    revise_dependents[] || return false
    dependents_supported && return true
    @warn "`Revise.revise_dependents` requires Julia 1.13 or later and is ignored" maxlog=1
    return false
end

"""
    Revise.set_revise_dependents(on::Bool)

Set [`Revise.revise_dependents`](@ref) to `on`, and when it turns on, start preparing the revisions of the code that is already tracked if [`Revise.prepare_ahead`](@ref) is on.

The preparation is the one Revise starts after loading a package. Without it, a package
loaded while the setting was off is analyzed only by its first revision.

# Examples

```jldoctest; setup = :(using Revise)
julia> Revise.set_revise_dependents(true); Revise.revise_dependents[]
true

julia> Revise.set_revise_dependents(false); Revise.revise_dependents[]
false
```
"""
function set_revise_dependents(on::Bool)
    was = revise_dependents[]
    revise_dependents[] = on
    on && !was && dependents_supported && request_analysis_ahead()
    return nothing
end

"""
    Revise.GlobalDeps

Hold the global bindings a top-level statement reads, assigns, and may mutate, found by [`Revise.global_deps`](@ref).

- `reads`, `writes`, `mutates`: `(owner, name)` pairs of bindings. A statement that may read
  the old value of a binding it writes, as `A = A + 1` does, also reads and mutates it.
- `readsall`: the statement may read any binding, as `names(M)` does, or a summary was cut.
- `dynamic`: `readsall` comes only from builtin calls in the statement's own code that select
  a global by a computed module or name, as `isdefined(@__MODULE__, name)` in a loop does.
  The globals that an interpreted run selects (see [`Revise.observed_reads`](@ref)) then
  replace `readsall` and are listed in `observed`.
- `assumed`, `checks`: the values of bindings and the method lookups the analysis relied on.
- `evaluated`: what [`Revise.evaluated_deps`](@ref) added, or `nothing`.
"""
mutable struct GlobalDeps
    const reads::Set{Tuple{Module,Symbol}}
    const writes::Set{Tuple{Module,Symbol}}
    const mutates::Set{Tuple{Module,Symbol}}
    const assumed::Vector{Pair{Tuple{Module,Symbol},Any}}
    const checks::Vector{CallCheck}
    readsall::Bool
    dynamic::Bool
    const observed::Set{Tuple{Module,Symbol}}
    evaluated::Union{Nothing,GlobalDeps}
end
GlobalDeps() = GlobalDeps(Set{Tuple{Module,Symbol}}(), Set{Tuple{Module,Symbol}}(),
                          Set{Tuple{Module,Symbol}}(), Pair{Tuple{Module,Symbol},Any}[], CallCheck[], false, false,
                          Set{Tuple{Module,Symbol}}(), nothing)

reads_any(deps::GlobalDeps, bindings) = deps.readsall ? !isempty(bindings) : !isdisjoint(deps.reads, bindings)

const StmtKey = Tuple{Symbol,Module,RelocatableExpr}

"""
    Revise.stmt_key(mod::Module, rex::RelocatableExpr) -> Tuple{Symbol,Module,RelocatableExpr}

Return the key of the statement `rex` of `mod` in the caches of its dependencies and runs: the file its first line number names, `mod`, and `rex`.

Equal statements of two files get two keys, since a macro may expand differently per file
through `__source__`.

# Examples

```jldoctest; setup = :(using Revise)
julia> key(file) = Revise.stmt_key(Main, Revise.RelocatableExpr(Expr(:block, LineNumberNode(1, file), :(const A = 1))));

julia> key(Symbol("a.jl"))[1], key(nothing)[1]
(Symbol("a.jl"), :none)

julia> key(:a) == key(:a), key(:a) == key(:b)
(true, false)
```
"""
function stmt_key(mod::Module, rex::RelocatableExpr)
    line = firstline(rex)
    file = isnothing(line) ? nothing : line.file
    return (isa(file, Symbol) ? file : :none, mod, rex)::StmtKey
end

# Keyed by statement; entries of deleted statements are dropped when the deletion is seen.
# Locking is covered by `revise_lock`.
const global_deps_cache = Dict{StmtKey,GlobalDeps}()

# The `lowered` argument of `expanded_deps` for each statement, kept across revisions and
# dropped with the statement. Locking is covered by `revise_lock`.
const lowered_cache = Dict{StmtKey,Dict{Any,Any}}()

# A tracked statement of a `DepIndex`, with `deps`, the entry of `global_deps_cache` that the
# indices list, or `nothing`.
mutable struct IndexedStmt
    const pkgdata::PkgData
    const file::String
    const fi::FileInfo
    const mod::Module
    const exs_infos::ExprsInfos
    const rex::RelocatableExpr
    deps::Union{Nothing,GlobalDeps}
end

# The statements of one file in a `DepIndex`, and the `FileInfo` and the number of statements per
# module they were read from.
struct IndexedFile
    fi::FileInfo
    parts::Vector{Tuple{Module,ExprsInfos,Int}}
    ids::Vector{Int}
end

"""
    Revise.DepIndex()

Hold the tracked statements whose dependencies [`Revise.revise_dependents`](@ref) analyzed, and indices from each binding, value, and method lookup to the statements whose dependencies list it.

The statements are numbered in `stmts`, where a statement no longer tracked holds `nothing`.
`files` lists the statements of each file per package, and `bykey` those of a key of
`global_deps_cache` (see [`Revise.stmt_key`](@ref)). `readers`, `writers`, `mutators`, `assumed`, and `checks` map a
binding, an assumed value, or a method lookup to the statements that rely on it, `readsall`
holds those that may read any binding, and `nodeps` those without an entry. `changed` collects
the keys whose entry changed since [`Revise.refresh_index!`](@ref) last ran.
"""
struct DepIndex
    stmts::Vector{Union{Nothing,IndexedStmt}}
    files::IdDict{PkgData,IdDict{ModuleExprsInfos,IndexedFile}}
    bykey::Dict{StmtKey,Vector{Int}}
    readers::Dict{Tuple{Module,Symbol},Set{Int}}
    writers::Dict{Tuple{Module,Symbol},Set{Int}}
    mutators::Dict{Tuple{Module,Symbol},Set{Int}}
    assumed::Dict{Tuple{Module,Symbol},IdDict{Any,Set{Int}}}
    checks::IdDict{CallCheck,Set{Int}}
    readsall::Set{Int}
    nodeps::Set{Int}
    changed::Set{StmtKey}
end
DepIndex() = DepIndex(Union{Nothing,IndexedStmt}[], IdDict{PkgData,IdDict{ModuleExprsInfos,IndexedFile}}(),
                      Dict{StmtKey,Vector{Int}}(), Dict{Tuple{Module,Symbol},Set{Int}}(),
                      Dict{Tuple{Module,Symbol},Set{Int}}(), Dict{Tuple{Module,Symbol},Set{Int}}(),
                      Dict{Tuple{Module,Symbol},IdDict{Any,Set{Int}}}(), IdDict{CallCheck,Set{Int}}(),
                      Set{Int}(), Set{Int}(), Set{StmtKey}())

# Kept across revisions. Locking is covered by `revise_lock`.
const dep_index = DepIndex()

# When set, every selection of dependent statements first verifies `dep_index` (for tests).
const verify_dep_index = Ref(false)

"""
    Revise.cache_deps!(key, deps::GlobalDeps) -> deps

Store `deps` in `global_deps_cache` as the dependencies of the statement with key `key` (see [`Revise.stmt_key`](@ref)).

Every change of `global_deps_cache` goes through this or `Revise.uncache_deps!`, which note the
key for [`Revise.refresh_index!`](@ref).

# Examples

```jldoctest; setup = :(using Revise)
julia> key = Revise.stmt_key(Main, Revise.RelocatableExpr(:(cache_doc = 1)));

julia> Revise.cache_deps!(key, Revise.GlobalDeps()) === Revise.global_deps_cache[key]
true

julia> key in Revise.dep_index.changed
true
```
"""
function cache_deps!(key::StmtKey, deps::GlobalDeps)
    apply_evaluated!(key, apply_observed!(key, deps))
    global_deps_cache[key] = deps
    push!(dep_index.changed, key)
    return deps
end

function uncache_deps!(key::StmtKey)
    push!(dep_index.changed, key)
    return pop!(global_deps_cache, key, nothing)
end

# Locking is covered by `revise_lock`.
"""
    Revise.observed_reads

Map the key of each statement (see [`Revise.stmt_key`](@ref)) to the globals that calls in its code read or tested by a module or name computed while it ran (see [`Revise.named_access_call`](@ref)), in its last run in the interpreter.

A statement has no entry if that run skipped such a call of its own code, or ran it compiled.
A change of any global the statement reads selects it, and its run records the globals again.
"""
const observed_reads = Dict{StmtKey,Set{Tuple{Module,Symbol}}}()

# Replace `readsall` of `deps`, the dependencies of the statement `key`, by the globals in
# `observed_reads`, if `readsall` comes only from such globals and an entry exists.
function apply_observed!(key::StmtKey, deps::GlobalDeps)
    deps.readsall && deps.dynamic || return deps
    obs = get(observed_reads, key, nothing)
    isnothing(obs) && return deps
    # Also keyed by the module the access named, as a `using` or `import` there writes it.
    for (m, s) in obs, b in ((m, s), (binding_owner(m, s), s))
        b[1] === Core || b in deps.reads || (push!(deps.reads, b); push!(deps.observed, b))
    end
    deps.readsall = false
    return deps
end

# Locking is covered by `revise_lock`.
"""
    Revise.evaluated_deps

Map the key of each statement (see [`Revise.stmt_key`](@ref)) to what the code it ran through `eval` read, wrote, and mutated in its last run in the interpreter, as a [`Revise.GlobalDeps`](@ref) from [`Revise.evaluated_code_deps`](@ref).

Before the first such run, what its `eval` calls do is not known. Code that a called function
runs through `eval` is not covered.
"""
const evaluated_deps = Dict{StmtKey,GlobalDeps}()

# Add what `evaluated_deps` lists for the statement `key` to `deps`, and record the additions in
# `deps.evaluated`. Assumptions and method lookups that no longer hold are left out: only a new
# run of the statement can analyze its code run through `eval` again.
function apply_evaluated!(key::StmtKey, deps::GlobalDeps)
    ev = get(evaluated_deps, key, nothing)
    isnothing(ev) && return deps
    added = GlobalDeps()
    for b in ev.writes
        b in deps.writes || (push!(deps.writes, b); push!(added.writes, b))
    end
    for b in ev.reads
        b in deps.reads || b in deps.writes || (push!(deps.reads, b); push!(added.reads, b))
    end
    for b in ev.mutates
        b in deps.mutates || (push!(deps.mutates, b); push!(added.mutates, b))
    end
    for p in ev.assumed
        any(q -> q === p, deps.assumed) || !@invokelatest(assumed_hold((p,))) ||
            (push!(deps.assumed, p); push!(added.assumed, p))
    end
    for c in ev.checks
        any(x -> x === c, deps.checks) || invalid_since(c) != typemax(UInt) ||
            (push!(deps.checks, c); push!(added.checks, c))
    end
    ev.readsall && !deps.readsall && (deps.readsall = added.readsall = true)
    deps.evaluated = added
    return deps
end

"""
    Revise.record_observed!(key, exinfo::Revise.ExInfo)

Record in [`Revise.observed_reads`](@ref) and [`Revise.evaluated_deps`](@ref) what the interpreted run of the statement with key `key`, described by `exinfo`, showed, and apply it to the cached dependencies of `key`.

This does nothing unless [`Revise.revise_dependents`](@ref) is set.

# Examples

```jldoctest; setup = :(using Revise)
julia> module RecordDoc; const YY = 1; end;

julia> ex = :(for n in (:a, :b); Core.eval(RecordDoc, Expr(:const, Expr(:(=), Symbol(n, :_c), :YY))); end);

julia> key = Revise.stmt_key(RecordDoc, Revise.RelocatableExpr(ex)); record() = Revise.record_observed!(key, Revise.eval_with_signatures(RecordDoc, ex)[4]);

julia> record(); haskey(Revise.evaluated_deps, key)
false

julia> Revise.revise_dependents[] = true; record();

julia> d = Revise.evaluated_deps[key]; sort!([n for (_, n) in d.writes]), [n for (_, n) in d.reads]
([:a_c, :b_c], [:YY])

julia> Revise.revise_dependents[] = false; delete!(Revise.evaluated_deps, key);
```
"""
function record_observed!(key::StmtKey, exinfo::ExInfo)
    revise_dependents[] && dependents_supported || return nothing
    exinfo.unobserved[] ? delete!(observed_reads, key) : (observed_reads[key] = exinfo.namedreads)
    ev = evaluated_code_deps(exinfo.evaluated)
    isnothing(ev) ? delete!(evaluated_deps, key) : (evaluated_deps[key] = ev)
    deps = get(global_deps_cache, key, nothing)
    if !isnothing(deps) && (deps.dynamic || !isnothing(deps.evaluated) || !isnothing(ev))
        # A new entry without what the earlier records added, since the indices list the old one
        added = something(deps.evaluated, GlobalDeps())
        cache_deps!(key, GlobalDeps(setdiff(deps.reads, deps.observed, added.reads), setdiff(deps.writes, added.writes),
                                    setdiff(deps.mutates, added.mutates),
                                    filter(p -> !any(q -> q === p, added.assumed), deps.assumed),
                                    filter(c -> !any(x -> x === c, added.checks), deps.checks),
                                    deps.dynamic || deps.readsall && !added.readsall, deps.dynamic,
                                    Set{Tuple{Module,Symbol}}(), nothing))
    end
    return nothing
end

"""
    Revise.evaluated_code_deps(evaluated) -> Union{Nothing,GlobalDeps}

Return what the code in `evaluated` reads, writes, and mutates, or `nothing` if `evaluated` is empty.

`evaluated` lists the `(mod, ex, lowered)` pieces of code that a statement ran through `eval`
(see [`Revise.ExInfo`](@ref)), analyzed by [`Revise.expanded_deps`](@ref) with `evaluated=true`,
so conditions do not fold on the contents of a `Ref`, which may change before the next run.

# Examples

```jldoctest; setup = :(using Revise)
julia> module EvDoc; const YY = 1; const LIST = Int[]; end;

julia> evdeps(ex) = Revise.evaluated_code_deps([(EvDoc, ex, Meta.lower(EvDoc, ex))]);

julia> d = evdeps(:(const XX = YY)); [n for (_, n) in d.reads], [n for (_, n) in d.writes]
([:YY], [:XX])

julia> [n for (_, n) in evdeps(:(push!(LIST, YY))).mutates]
1-element Vector{Symbol}:
 :LIST
```
"""
function evaluated_code_deps(evaluated::Vector{Tuple{Module,Expr,Expr}})
    isempty(evaluated) && return nothing
    deps = GlobalDeps()
    for (mod, ex, lwr) in evaluated
        # Keyed by identity: hashing `ex` hashes the values spliced into it, whose methods may postdate Revise's world.
        d = expanded_deps(mod, ex, Set{Tuple{Module,Symbol}}(), IdDict{Any,Any}(ex => lwr); evaluated=true)
        union!(deps.reads, d.reads)
        union!(deps.writes, d.writes)
        union!(deps.mutates, d.mutates)
        append!(deps.assumed, d.assumed)
        append!(deps.checks, d.checks)
        deps.readsall |= d.readsall
    end
    setdiff!(deps.reads, deps.writes)
    unique!(deps.checks)
    return deps
end

# Run the statement `key`, whose cached dependencies `deps` read any binding only because its
# code selects globals by computed modules or names, in `:sigs` mode to observe these globals.
# Return its dependencies afterwards. If the run does not show all of them, `deps` stays as it
# is, and is not run again for this.
function observe_reads!(key::StmtKey, deps::GlobalDeps)
    _, mod, rex = key
    exinfo = try
        eval_with_signatures(mod, rex.ex; mode=:sigs)[4]
    catch err
        isa(err, Union{InterruptException,IdleCancelled}) && rethrow()
        log_caught(err, catch_backtrace(), "ObserveReadsFailed"; deltainfo=(mod, rex.ex))
        nothing
    end
    if isnothing(exinfo) || exinfo.unobserved[]
        deps.dynamic = false
        return deps
    end
    record_observed!(key, exinfo)
    return global_deps_cache[key]
end

# An exception and the backtrace of the place where it was caught.
struct CaughtError
    err::Any
    bt::Vector{Union{Ptr{Nothing},Base.InterpreterIP}}
end

# The dependent statements whose last reevaluation failed, by file, module, and expression,
# with their packages and errors. Every revision selects them again. Locking is covered by
# `revise_lock`.
const failed_dependents = Dict{Tuple{String,Module,RelocatableExpr},Tuple{PkgId,CaughtError}}()

# The world after the last run of each `(file, mod, rex)` statement the current revision
# evaluated, and the number of its runs. Locking is covered by `revise_lock`.
const run_worlds = Dict{Tuple{String,Module,RelocatableExpr},Tuple{UInt,Int}}()

# For each global assigned by a statement whose dependencies the current revision replaced or
# dropped, the globals that statement read. The value of the global may still share memory with
# theirs. Locking is covered by `revise_lock`.
const former_reads = Dict{Tuple{Module,Symbol},Set{Tuple{Module,Symbol}}}()

function record_former_reads!(deps::GlobalDeps)
    isempty(deps.reads) && return nothing
    for b in deps.writes
        union!(get!(Set{Tuple{Module,Symbol}}, former_reads, b), deps.reads)
    end
    return nothing
end

# Runs of one statement in one revision, after which a change of the code it calls no longer
# selects it again. Two statements that each change code the other calls would run forever.
const max_runs = 4

# Record that the statement `rex` of `mod` in `file` ran.
function record_run!(file::String, mod::Module, rex::RelocatableExpr)
    revise_dependents[] && dependents_supported || return nothing
    n = get(run_worlds, (file, mod, rex), (UInt(0), 0))[2]
    run_worlds[(file, mod, rex)] = (Base.get_world_counter(), n + 1)
    return nothing
end

# Whether the method lookup or an inference result that `c` lists changed after `world`.
function changed_after(c::CallCheck, world::UInt)
    since = invalid_since(c)
    since != typemax(UInt) && since > world && return true
    any(m -> m.primary_world > world, c.methods) && return true
    return any(ci -> !isnothing(ci) && ci.min_world > world, c.cis)
end

# Whether code that the statement `key` with dependencies `deps` calls changed after its last
# run in this revision. After `max_runs` runs, a warning is logged instead.
function ran_before_change(key::Tuple{String,Module,RelocatableExpr}, deps::GlobalDeps)
    run = get(run_worlds, key, nothing)
    isnothing(run) && return false
    world, n = run
    any(c -> changed_after(c, world), deps.checks) || return false
    n < max_runs && return true
    if n == max_runs
        file, mod, rex = key
        @warn "Code that a statement calls changed after its last run, but it ran $max_runs times in this revision and is not evaluated again" file mod ex=rex.ex
        run_worlds[key] = (world, n + 1)
    end
    return false
end

# A tracked top-level statement: its package, file, module, and expression. The same
# expression in two files of one module makes two statements.
const TrackedStmt = Tuple{PkgData,String,Module,RelocatableExpr}

"""
    global_deps(mod::Module, ex::Expr; unknown=Set{Tuple{Module,Symbol}}(), lowered=Dict{Any,Any}()) -> GlobalDeps

Return the global bindings that evaluating the top-level statement `ex` in `mod` reads and writes.

`ex` is expanded by [`Revise.expand_stmt`](@ref) and lowered, not evaluated. Reads in the bodies
of the methods that `ex` only defines are left out, reads in their signatures are not. A method
definition writes its function's name only if `mod` owns that binding. Code run through `eval`
is analyzed if it is quoted without interpolation (see [`Revise.literal_eval`](@ref)), else it is
known only from runs of `ex` (see [`Revise.evaluated_deps`](@ref)). Requires Julia 1.13 or later.

Each call is followed into the methods it may reach (see [`Revise.summarize`](@ref)). `ex`
mutates the globals that these methods mutate, and the globals whose memory a mutated argument
may share. Globals of untracked modules, globals that cannot reach mutable memory (see
[`Revise.may_hold_mutable`](@ref)), and calls without side effects are left out.

The value of a global gives type information only if it is `const` or a module, `ex` does not
assign it, and it is not in `unknown`, the bindings that may change before `ex` runs. `lowered`
holds lowered code to reuse (see [`Revise.expanded_deps`](@ref)).

# Examples

```jldoctest; setup = :(using Revise)
julia> deps = Revise.global_deps(Main, :(const B = (A, 1)));

julia> [n for (_, n) in deps.reads], [n for (_, n) in deps.writes]
([:A], [:B])

julia> const V = [1]; [n for (_, n) in Revise.global_deps(@__MODULE__, :(push!(V, 2))).mutates]
1-element Vector{Symbol}:
 :V

julia> [n for (_, n) in Revise.global_deps(@__MODULE__, :(L = length(V))).mutates]
Symbol[]
```
"""
function global_deps(mod::Module, ex::Expr; unknown::Set{Tuple{Module,Symbol}}=Set{Tuple{Module,Symbol}}(),
                     lowered::Dict{Any,Any}=Dict{Any,Any}())
    return expanded_deps(mod, expand_stmt(mod, ex), unknown, lowered)
end

"""
    Revise.expand_stmt(mod::Module, ex::Expr) -> Expr

Return the top-level statement `ex` of `mod` with its macros expanded and the bodies of the methods it only defines stripped, ready for [`Revise.expanded_deps`](@ref).

The quoted expressions without interpolation that `ex` runs through `eval` are expanded the
same way (see [`Revise.expand_literal_evals`](@ref)). This runs the code of the macros that `ex`
calls, so it must run on the task that holds `revise_lock`: a macro may call into Revise or
load a package.

# Examples

```jldoctest; setup = :(using Revise)
julia> Revise.expand_stmt(Main, :(f(x) = @inbounds x[1]))
:(f(x) = begin
          nothing
      end)

julia> Revise.expand_stmt(Main, :(const C = @__MODULE__))
:(const C = Main)
```
"""
function expand_stmt(mod::Module, ex::Expr)
    ex = strip_bodies(ex)
    needs_macroexpand(ex) && (ex = expand_literal_evals(mod, strip_bodies(macroexpand(mod, ex))))
    return ex
end

"""
    Revise.expand_literal_evals(mod::Module, ex)

Return `ex`, a macro-expanded expression of `mod`, with each quoted expression without interpolation that it runs through `eval` replaced by its [`Revise.expand_stmt`](@ref) in the module it is evaluated in.

The module is that of `Core.eval(M, …)` if `M` names a module, or `mod` for `eval(…)`. `ex`
is returned unchanged if it holds no such expression.

# Examples

```jldoctest; setup = :(using Revise)
julia> payload(ex) = ex.args[end].args[1].value;   # the quoted expression of `eval(:(…))`

julia> ex = macroexpand(Main, :(eval(:(@inline f(x) = x))));

julia> Revise.needs_macroexpand(payload(ex)), Revise.needs_macroexpand(payload(Revise.expand_literal_evals(Main, ex)))
(true, false)

julia> ex = macroexpand(Main, :(eval(Expr(:call, :f)))); Revise.expand_literal_evals(Main, ex) === ex
true
```
"""
function expand_literal_evals(mod::Module, @nospecialize(ex))
    isa(ex, Expr) || return ex
    if ex.head === :call && length(ex.args) in (2, 3) && isexpr(ex.args[end], :copyast, 1)
        q = ex.args[end].args[1]
        f = ex.args[1]
        evalmod = if length(ex.args) == 2
            f === :eval ? mod : nothing
        elseif isa(f, GlobalRef) ? f.name === :eval : isexpr(f, :., 2) && f.args[2] == QuoteNode(:eval)
            resolve_module_literal(mod, ex.args[2])
        end
        if isa(q, QuoteNode) && isa(q.value, Expr) && isa(evalmod, Module)
            return Expr(:call, ex.args[1:end-1]..., Expr(:copyast, QuoteNode(expand_stmt(evalmod, q.value))))
        end
    end
    args = ex.args
    for (i, a) in enumerate(ex.args)
        b = expand_literal_evals(mod, a)
        b === a && continue
        args === ex.args && (args = copy(ex.args))
        args[i] = b
    end
    return args === ex.args ? ex : Expr(ex.head, args...)
end

"""
    Revise.expanded_deps(mod::Module, ex, unknown::Set{Tuple{Module,Symbol}}, lowered=Dict{Any,Any}(); evaluated=false, refs=!evaluated) -> Revise.GlobalDeps

Return [`Revise.global_deps`](@ref) of the statement `ex` of `mod` that [`Revise.expand_stmt`](@ref) returned.

This runs no macro, so it can run on any task. `lowered` maps the parts of `ex` to their lowered
code, and is emptied first unless it holds `ex`. With `evaluated`, `ex` is code that a statement
ran through `eval`: the bodies of named methods are skipped, and definitions mutate nothing
(see [`Revise.is_definition_call`](@ref)).

A condition folds on the contents of a `Ref` (see [`Revise.reachable`](@ref)) only with `refs`,
and only if `ex` can neither assign the global that holds the `Ref` nor mutate a global that
may reach a `Ref`, such as an alias `const B = A`, since `ex` may set it before the condition.

# Examples

```jldoctest; setup = :(using Revise)
julia> const EX = 1; deps = Revise.expanded_deps(Main, Revise.expand_stmt(Main, :(const Y = EX)), Set{Tuple{Module,Symbol}}());

julia> [n for (_, n) in deps.reads], [n for (_, n) in deps.writes]
([:EX], [:Y])

julia> V2 = Int[]; [n for (_, n) in Revise.expanded_deps(Main, :(push!(V2, 1)), Set{Tuple{Module,Symbol}}()).mutates]
1-element Vector{Symbol}:
 :V2

julia> const SETS = Ref(false); const ALIAS = SETS; ex = :(begin ALIAS[] = true; SETS[] && push!(V2, 2); ALIAS[] = false end);

julia> sort!([n for (_, n) in Revise.expanded_deps(@__MODULE__, ex, Set{Tuple{Module,Symbol}}()).mutates])
2-element Vector{Symbol}:
 :ALIAS
 :V2
```
"""
function expanded_deps(mod::Module, @nospecialize(ex), unknown::Set{Tuple{Module,Symbol}},
                       lowered::AbstractDict{Any,Any}=Dict{Any,Any}(); evaluated::Bool=false, refs::Bool=!evaluated)
    haskey(lowered, ex) || empty!(lowered)
    w = DepsWalk(GlobalDeps(), CodeInfo[], lowered, evaluated, refs)
    add_global_deps!(w, mod, ex)
    deps, srcs, tops = w.deps, w.srcs, w.tops
    unknowns = union(unknown, deps.writes)
    assumed = w.assumed
    walk = Walk()   # one budget for all methods the statement may call
    readsat = IdDict{CodeInfo,Set{Tuple{GlobalId,Int}}}()
    assigned = Set{Tuple{Module,Symbol}}()
    dynamic = true
    cut = false
    for src in srcs
        fr = analyze_frame(src, walk, LoweredStmt(src, unknowns, assumed, walk), w.live[src])
        cut |= fr.precision === Cut
        # Negative ids left in the reads select a global whose name is not known, as `names(M)` does.
        if fr.precision === Cut || any(<(0), fr.reads)
            deps.readsall = true
            dynamic &= fr.precision !== Cut && !fr.hidden
        end
        foreach(id -> id > 0 && add_read!(deps, global_binding(id)...), fr.reads)
        add_owned!(deps.mutates, (global_binding(id) for id in fr.mutated.globals if id > 0))
        add_owned!(assigned, (global_binding(id) for id in fr.assigned if id > 0))
        readsat[src] = fr.readsat
    end
    append!(deps.assumed, assumed)
    append!(deps.checks, unique!(append!(walk.checks, w.checks)))
    deps.dynamic = deps.readsall && dynamic
    old = old_value_reads(tops, readsat)
    setdiff!(deps.reads, setdiff(deps.writes, old))
    setdiff!(deps.mutates, setdiff(deps.writes, old))
    union!(deps.mutates, old)
    # A global that called code assigns is written, and also mutated if the statement may read its old value.
    for b in setdiff!(assigned, deps.writes)
        push!(deps.writes, b)
        b in deps.reads && push!(deps.mutates, b)
    end
    if refs && any(v -> isa(v, RefContents), values(assumed)) &&
            (cut || any(value_may_hold_ref, deps.mutates) ||
             any(((b, v),) -> isa(v, RefContents) && b in deps.writes, assumed))
        return expanded_deps(mod, ex, unknown, lowered; evaluated, refs=false)
    end
    return deps
end

"""
    Revise.old_value_reads(tops, readsat) -> Set{Tuple{Module,Symbol}}

Return the globals that the lowered top-level code `tops` assigns with a builtin such as `setglobal!` and may read before assigning them.

`readsat` maps code in `tops`, and the method bodies the statement may run, to the reads that
the summaries of its calls found, each with the index of the statement it comes from. A read
in a method body counts as one before the assignment, since the body may run first. Running a
statement that reads such an old value again builds on the value of its last run.

# Examples

```jldoctest; setup = :(using Revise)
julia> old(ex) = [n for (_, n) in Revise.old_value_reads([Meta.lower(Main, ex).args[1]], IdDict())];

julia> A = 1; old(:(A = A + 1))
1-element Vector{Symbol}:
 :A

julia> old(:(begin A = 2; B = A end))
Symbol[]
```
"""
function old_value_reads(tops::Vector{CodeInfo}, readsat::AbstractDict)
    old = Set{Tuple{Module,Symbol}}()
    for src in tops, stmt in src.code
        id = assigned_global(src, stmt)
        isnothing(id) && continue
        b = global_binding(id)
        b in old && continue
        if any(s -> reads_before_assigning(s, id, get(readsat, s, nothing)), tops) ||
                any(((s, ra),) -> !any(t -> t === s, tops) && any(r -> r[1] == id, ra), readsat)
            push!(old, b)
        end
    end
    return old
end

# Whether a path through the lowered code `src` reads the global `id` before assigning it.
# `ra` holds the reads the summaries of the calls found, with their statement indices.
function reads_before_assigning(src::CodeInfo, id::GlobalId, ra)
    b = global_binding(id)
    n = length(src.code)
    seen = falses(n)
    work = [1]
    while !isempty(work)
        i = pop!(work)
        1 <= i <= n && !seen[i] || continue
        seen[i] = true
        stmt = src.code[i]
        (mentions_global(stmt, b) || !isnothing(ra) && (id, i) in ra) && return true
        assigned_global(src, stmt) == id && continue
        if isa(stmt, Core.GotoNode)
            push!(work, stmt.label)
        elseif isa(stmt, Core.GotoIfNot)
            push!(work, i + 1, stmt.dest)
        elseif isa(stmt, Core.EnterNode)
            push!(work, i + 1, stmt.catch_dest)
        elseif !isa(stmt, Core.ReturnNode)
            push!(work, i + 1)
        end
    end
    return false
end

# Whether the lowered code `x` names the global `b`, other than as the function a method
# definition adds a method to.
function mentions_global(@nospecialize(x), b::Tuple{Module,Symbol})
    x = as_globalref(x)
    isa(x, GlobalRef) && return x.name === b[2] && binding_owner(x.mod, x.name) === b[1]
    if isa(x, CodeInfo)
        for st in x.code
            mentions_global(st, b) && return true
        end
        return false
    end
    isa(x, Expr) || return false
    for i in (isexpr(x, :method) ? 2 : 1):length(x.args)
        mentions_global(x.args[i], b) && return true
    end
    return false
end

# The lowered code of a statement under analysis. The current values of the bindings in
# `unknown` may differ from those the statement sees when it runs. `assumed` collects the
# values the analysis relies on. `slottypes` holds the types of the local variables, `walk` the
# state of the summaries of the methods the statement may call. `ssavalues` and `ssatypes` hold
# `callee` and `arg_type` of the SSA values computed so far, the latter for the current `slottypes`.
struct LoweredStmt
    src::CodeInfo
    unknown::Set{Tuple{Module,Symbol}}
    assumed::Dict{Tuple{Module,Symbol},Any}
    slottypes::Dict{Int,Type}
    walk::Walk
    ssavalues::Dict{Int,Union{Nothing,Some{Any}}}
    ssatypes::Dict{Int,Any}
end
LoweredStmt(src::CodeInfo, unknown::Set{Tuple{Module,Symbol}}, assumed::Dict{Tuple{Module,Symbol},Any},
            walk::Walk=Walk()) =
    infer_slot_types!(LoweredStmt(src, unknown, assumed, Dict{Int,Type}(), walk,
                                  Dict{Int,Union{Nothing,Some{Any}}}(), Dict{Int,Any}()))

const max_slot_rounds = 8

# Type each local variable of `ls` as the union of the types of the values assigned to it,
# starting from `Union{}` and repeated until no type changes. If that takes more than
# `max_slot_rounds` rounds, every local variable has type `Any`.
function infer_slot_types!(ls::LoweredStmt)
    assigns = Tuple{Int,Any}[]
    for stmt in ls.src.code
        isexpr(stmt, :(=), 2) || continue
        lhs = stmt.args[1]
        isa(lhs, Core.SlotNumber) || continue
        push!(assigns, (lhs.id, stmt.args[2]))
        ls.slottypes[lhs.id] = Union{}
    end
    for _ in 1:max_slot_rounds
        changed = false
        for (id, v) in assigns
            T = isa(v, Expr) ? expr_type(ls, v) : arg_type(ls, v)
            old = ls.slottypes[id]
            T <: old && continue
            ls.slottypes[id] = Union{old, T}
            empty!(ls.ssatypes)
            changed = true
        end
        changed || return ls
    end
    for id in keys(ls.slottypes)
        ls.slottypes[id] = Any
    end
    empty!(ls.ssatypes)
    return ls
end

# The state of the walk over the lowered code of a statement: its dependencies `deps`, the code
# `srcs` with calls that may mutate, its top-level code `tops`, and the lowered code of its parts
# to reuse, `lowered`. `evaluated` tells that the code ran through `eval` and kept its method bodies.
# `live` holds the statements of each code that can run, which may rely on the values in
# `assumed`, on the contents of a `Ref` if `refs` is set, and on the method lookups in `checks`
# (see `reachable`).
struct DepsWalk
    deps::GlobalDeps
    srcs::Vector{CodeInfo}
    tops::Vector{CodeInfo}
    lowered::Union{Dict{Any,Any},IdDict{Any,Any}}
    evaluated::Bool
    refs::Bool
    assumed::Dict{Tuple{Module,Symbol},Any}
    checks::Vector{CallCheck}
    live::IdDict{CodeInfo,BitVector}
end
DepsWalk(deps::GlobalDeps, tops::Vector{CodeInfo}, lowered, evaluated::Bool, refs::Bool) =
    DepsWalk(deps, CodeInfo[], tops, lowered, evaluated, refs, Dict{Tuple{Module,Symbol},Any}(), CallCheck[],
             IdDict{CodeInfo,BitVector}())

# Record the dependencies of `ex`, a statement of `mod` that `expand_stmt` returned, in `w`.
# Parts lowered before are taken from `w.lowered`.
function add_global_deps!(w::DepsWalk, mod::Module, @nospecialize(ex))
    lwr = get!(() -> lower_stmt(mod, ex), w.lowered, ex)
    isa(lwr, Expr) || return w
    if lwr.head === :thunk
        src = lwr.args[1]::CodeInfo
        push!(w.tops, src)
        add_global_deps!(w, mod, src)
    elseif lwr.head === :toplevel
        for a in lwr.args
            isa(a, Expr) && add_global_deps!(w, mod, a)
        end
    end
    return w
end

# Whether `macroexpand` can change `ex`. It calls into the runtime even for an expression it leaves unchanged.
needs_macroexpand(@nospecialize(ex)) =
    isa(ex, Expr) && (ex.head === :macrocall || ex.head === :quote || any(needs_macroexpand, ex.args))

# Lower the top-level statement `ex` of `mod` for analysis, not for evaluation. JuliaLowering,
# where available, is several times faster than the session's lowering, but may name generated
# functions differently. `Meta.lower` takes over where JuliaLowering fails.
function lower_stmt(mod::Module, @nospecialize(ex))
    @static if isdefined(Base, :JuliaLowering) && isdefined(Base.JuliaLowering, :core_lowering_hook)
        lwr = try
            @static if hasmethod(Base.JuliaLowering.core_lowering_hook, Tuple{Module, Any, UInt, Bool, LineNumberNode})
                Base.JuliaLowering.core_lowering_hook(mod, ex, typemax(Csize_t), false, LineNumberNode(0, :none))[1]
            else
                Base.JuliaLowering.core_lowering_hook(ex, mod)[1]
            end
        catch err
            isa(err, Base.JuliaLowering.LoweringError) || rethrow()
            nothing
        end
        isnothing(lwr) || isexpr(lwr, :error) || return lwr
    end
    return Meta.lower(mod, ex)
end

"""
    strip_bodies(ex)

Return `ex` with the body of every method and macro definition that only defines replaced by a
block holding only `nothing`.

These are the definitions at the top level of `ex`, in its blocks and branches, and in the
bodies of `struct`, `global`, and `const`. A function defined elsewhere, as in a `let` block or
as an anonymous function, may run while `ex` runs, so its body is kept. Macro calls are left
alone, except for the documented expression of `@doc`. Lowering a stripped statement is much
cheaper and yields the same signatures.

# Examples

```jldoctest; setup = :(using Revise)
julia> Revise.strip_bodies(:(f(x::Vector{T}) where {T} = sum(x)))
:((f(x::Vector{T}) where T) = begin
          nothing
      end)

julia> Revise.strip_bodies(:(@doc "Doc." f(x) = sum(x)))
:(#= none:1 =# @doc "Doc." f(x) = begin
              nothing
          end)

julia> ex = :(B = map(x -> x + A, v)); Revise.strip_bodies(ex) === ex
true
```
"""
function strip_bodies(@nospecialize(ex))
    isa(ex, Expr) || return ex
    head = ex.head
    if head === :macrocall
        # Revise tracks a docstring as `@doc str ex false`, which documents without defining.
        is_doc_expr(ex) || length(ex.args) == 5 && is_doc_expr(Expr(head, ex.args[1:4]...)) || return ex
        return Expr(head, ex.args[1:3]..., strip_bodies(ex.args[4]), ex.args[5:end]...)
    end
    if length(ex.args) == 2 && (head === :macro || (head === :function || head === :(=)) && is_call_signature(ex.args[1]))
        # Lowering segfaults on destructured arguments when the body is not a block.
        return Expr(head, ex.args[1], Expr(:block, nothing))
    end
    if head in (:block, :toplevel, :global, :const, :struct, :escape, Symbol("hygienic-scope"))
        return Expr(head, Any[strip_bodies(a) for a in ex.args]...)
    elseif head in (:if, :elseif) && !isempty(ex.args)
        return Expr(head, ex.args[1], Any[strip_bodies(a) for a in ex.args[2:end]]...)   # the condition runs
    end
    return ex
end

function is_call_signature(@nospecialize(lhs))
    while isexpr(lhs, :where) || isexpr(lhs, :(::), 2)
        lhs = lhs.args[1]
    end
    return isexpr(lhs, :call)
end

# Record the reads and writes of the lowered code `src` in `w.deps`, and add `src` to `w.srcs`
# for the analysis of mutations if it has a call that may mutate. Statements that cannot run,
# such as those guarded by `jl_generating_output`, are skipped.
function add_global_deps!(w::DepsWalk, mod::Module, src::CodeInfo)
    live = any(st -> isa(st, Core.GotoIfNot), src.code) ? first(reachable(src, w.assumed, w.checks; w.refs)) :
        trues(length(src.code))
    w.live[src] = live
    for (i, stmt) in enumerate(src.code)
        live[i] && add_stmt_deps!(w, mod, src, stmt)
    end
    return w
end

# Record the reads and writes of `x`, a statement or argument in `src`, in `w.deps`.
function add_stmt_deps!(w::DepsWalk, mod::Module, src::CodeInfo, @nospecialize(x))
    deps = w.deps
    if isa(x, GlobalRef)
        add_read!(deps, x.mod, x.name)
    elseif isa(x, Expr)
        head = x.head
        if head === :method
            if length(x.args) == 1
                add_method_write!(deps, mod, x.args[1])
            else
                isnothing(x.args[1]) && add_qualified_method_write!(deps, mod, src, x.args[2])
                add_stmt_deps!(w, mod, src, x.args[2])
                # A body left by `strip_bodies` may run during the statement. In code run through
                # `eval`, only a closure's may, which has `false` for a name.
                body = x.args[3]
                isa(body, CodeInfo) && (!w.evaluated || x.args[1] === false) && add_global_deps!(w, mod, body)
            end
        elseif head === :thunk
            body = x.args[1]
            isa(body, CodeInfo) && add_global_deps!(w, mod, body)
        else
            mutating = head === :foreigncall || head === :call && add_call_deps!(w, mod, src, x)
            mutating && !any(s -> s === src, w.srcs) && push!(w.srcs, src)
            named = w.evaluated && is_core_call(x, :define_method) && length(x.args) >= 3 && x.args[3] !== false
            for a in x.args
                if isa(a, CodeInfo)   # a method body, as `Core.define_method` takes it
                    named || add_global_deps!(w, mod, a)
                else
                    add_stmt_deps!(w, mod, src, a)
                end
            end
        end
    end
    return deps
end

# Record the binding `call` reads or writes in `w.deps`. Return whether `call` may mutate.
function add_call_deps!(w::DepsWalk, mod::Module, src::CodeInfo, call::Expr)
    deps = w.deps
    f = call.args[1]
    if length(call.args) >= 3 && isa(f, GlobalRef) && f.mod === Core &&
            (f.name === :declare_const || f.name === :declare_global || f.name === :setglobal!)
        m, s = call.args[2], unquote(call.args[3])
        isa(m, Module) && isa(s, Symbol) && push!(deps.writes, (m, s))
        return false
    end
    # Julia 1.14 lowers method definitions to this builtin instead of `Expr(:method)`.
    if length(call.args) >= 3 && isa(f, GlobalRef) && f.mod === Core && f.name === :define_method
        m = call.args[2]
        isa(m, Module) || return false
        name = unquote(call.args[3])
        if isnothing(name)
            length(call.args) >= 4 && add_qualified_method_write!(deps, m, src, call.args[4])
        else
            add_method_write!(deps, m, name)
        end
        return false
    end
    if is_namespace_call(f)
        add_namespace_writes!(deps, call)
        return false
    end
    if !w.evaluated
        lit = literal_eval(src, call)
        isnothing(lit) || add_global_deps!(w, lit...)
    end
    if is_global_read(f, src) && length(call.args) in (3, 4)
        m, s = resolve_module(src, call.args[2]), unquote(call.args[3])
        isa(m, Module) && isa(s, Symbol) && add_read!(deps, m, s)
    end
    return !w.evaluated || !is_definition_call(src, call)
end

"""
    Revise.literal_eval(src::CodeInfo, call::Expr) -> Union{Nothing,Tuple{Module,Expr}}

Return the module and the expression that `call`, a call in the lowered code `src`, runs through `eval`, if the expression is quoted without interpolation, as in `@eval f() = 1`, and else `nothing`.

`call` is `Core.eval(M, …)` with `M` a module or a `const` global that holds one, or `eval(…)`
with the `eval` of a module.

# Examples

```jldoctest; setup = :(using Revise)
julia> evalmods(ex) = (src = Meta.lower(Main, ex).args[1]; [r[1] for r in (Revise.literal_eval(src, st) for st in src.code if Meta.isexpr(st, :call)) if !isnothing(r)]);

julia> evalmods(:(@eval g() = 1))
1-element Vector{Module}:
 Main

julia> evalmods(:(Core.eval(Base, :(g() = 1))))
1-element Vector{Module}:
 Base

julia> evalmods(:(Core.eval(Main, Expr(:call, :g))))
Module[]
```
"""
function literal_eval(src::CodeInfo, call::Expr)
    length(call.args) in (2, 3) || return nothing
    x = call.args[end]
    isa(x, Core.SSAValue) && (x = src.code[x.id])
    isexpr(x, :copyast, 1) && (x = x.args[1])
    # JuliaLowering quotes through a call of `interpolate_expr`, here with nothing to interpolate
    @static if isdefined(Base, :JuliaLowering) && isdefined(Base.JuliaLowering, :interpolate_expr)
        if isexpr(x, :call, 2)
            g = x.args[1]
            isa(g, GlobalRef) && @invokelatest(isdefinedglobal(g.mod, g.name)) && (g = @invokelatest getglobal(g.mod, g.name))
            g === Base.JuliaLowering.interpolate_expr && (x = x.args[2])
        end
    end
    isa(x, QuoteNode) && isa(x.value, Expr) || return nothing
    b = resolve_binding(src, call.args[1])
    isnothing(b) && return nothing
    @invokelatest(isdefinedglobal(b...)) && @invokelatest(isconst(b...)) || return nothing
    f = @invokelatest getglobal(b...)
    if f === Core.eval && length(call.args) == 3
        m = resolve_module(src, call.args[2])
    elseif @static(isdefined(Core, :EvalInto) ? true : false) && f isa Core.EvalInto && length(call.args) == 2
        m = f.m
    else
        return nothing
    end
    return isa(m, Module) ? (m, x.value) : nothing
end

# The functions of `Core` that lowering calls to define methods and types.
const definition_functions = Set{Symbol}([:svec, :apply_type, :Typeof, :tuple, :typeof, :isa, :(===), :ifelse,
    :_typevar, :TypeVar, :UnionAll, :kwftype, :isdefinedglobal, :_structtype, :_abstracttype, :_primitivetype,
    :_setsuper!, :_typebody!, :_equiv_typedef, :_defaultctors, :resolve_typegroup, :declare_const, :declare_global,
    :define_method])

"""
    Revise.is_definition_call(src::CodeInfo, call::Expr) -> Bool

Return whether `call`, a call in the lowered code `src`, only helps to define methods or types: a call of a function of `Core` that builds a signature or a type, or the read of a global of a module.

# Examples

```jldoctest; setup = :(using Revise)
julia> function defonly(ex)
           src = Meta.lower(Main, ex).args[1]
           return all(st -> !Meta.isexpr(st, :call) || Revise.is_definition_call(src, st), src.code)
       end;

julia> defonly(:(f(x::Vector{T}) where {T} = x)), defonly(:(Base.g(x::Base.RefValue) = x))
(true, true)

julia> defonly(:(push!(V, 1)))
false
```
"""
function is_definition_call(src::CodeInfo, call::Expr)
    f = call.args[1]
    isa(f, GlobalRef) && f.mod === Core && f.name in definition_functions && return true
    return is_global_read(f, src) && length(call.args) == 3 && isa(resolve_module(src, call.args[2]), Module)
end

"""
    Revise.add_namespace_writes!(deps::GlobalDeps, call::Expr) -> deps

Record in `deps` the bindings that the lowered `using` or `import` statement `call` creates in its module, as writes.

These are the names it imports, and for `using M` the names that `M` exports, keyed by the
importing module. A `using M` whose module `M` cannot be found without loading a package writes
nothing.

# Examples

```jldoctest; setup = :(using Revise)
julia> module NsDoc; module Inner; export x; x = 1; end; end;

julia> [n for (_, n) in Revise.global_deps(NsDoc, :(using .Inner: x)).writes]
1-element Vector{Symbol}:
 :x

julia> sort!([n for (_, n) in Revise.global_deps(NsDoc, :(using .Inner)).writes])
2-element Vector{Symbol}:
 :Inner
 :x
```
"""
function add_namespace_writes!(deps::GlobalDeps, call::Expr)
    if is_using_call(call.args[1])
        length(call.args) == 3 || return deps
        to, path = call.args[2], unquote(call.args[3])
        isa(to, Module) && isexpr(path, :.) || return deps
        m = import_path_module(to, path)
        isnothing(m) && return deps
        for n in @invokelatest names(m)
            @invokelatest(Base.isexported(m, n)) && push!(deps.writes, (to, n))
        end
    else
        length(call.args) >= 5 || return deps
        to = call.args[3]
        isa(to, Module) || return deps
        for p in @view call.args[5:end]
            p = unquote(p)
            n = isexpr(p, :as, 2) ? p.args[2] : isexpr(p, :.) && !isempty(p.args) ? last(p.args) : nothing
            isa(n, Symbol) && n !== :. && push!(deps.writes, (to, n))
        end
    end
    return deps
end

# The module that the path `path` of a `using` or `import` in `to` names, or `nothing` if it is
# not reachable from `to` without loading a package.
function import_path_module(to::Module, path::Expr)
    args = path.args
    isempty(args) && return nothing
    m, i = to, 1
    if args[1] === :.
        i = 2
        while i <= length(args) && args[i] === :.
            m = parentmodule(m)
            i += 1
        end
    end
    for s in @view args[i:end]
        isa(s, Symbol) && @invokelatest(isdefinedglobal(m, s)) || return nothing
        m = @invokelatest getglobal(m, s)
        isa(m, Module) || return nothing
    end
    return m
end

# Whether `f`, the callee of a lowered call, possibly quoted, a `GlobalRef` to a `const`, or with
# `src` an `SSAValue`, is `getproperty`, `getglobal`, or `getfield`, which read a global of a module.
function is_global_read(@nospecialize(f), src::Union{Nothing,CodeInfo}=nothing)
    isa(f, Core.SSAValue) && !isnothing(src) && (f = src.code[f.id])
    isa(f, QuoteNode) && (f = f.value)
    if isa(f, GlobalRef)
        f.name === :getproperty || f.name === :getglobal || f.name === :getfield || return false
        @invokelatest(isdefinedglobal(f.mod, f.name)) && @invokelatest(isconst(f.mod, f.name)) || return false
        f = @invokelatest getglobal(f.mod, f.name)
    end
    return f === getproperty || f === getglobal || f === getfield
end

# Functions that change only bindings, as `using` does, documentation, or compiled code. Their
# calls mutate no value a statement computes.
const no_value_effect = Any[Base.Docs.Binding, Base.Docs.docstr, Base.Docs.doc!, precompile,
    eval_using_functions..., eval_import_functions..., eval_public_functions...]

# Whether `call` with callee `f` mutates no value a statement computes: a function in
# `no_value_effect`, a read of a module's global, or an `include`, whose file Revise tracks
# and evaluates as statements of its own.
function no_mutation(ls::LoweredStmt, @nospecialize(f), call::Expr)
    any(g -> g === f, no_value_effect) && return true
    is_global_read(f) && length(call.args) in (3, 4) && isa(resolve_module(ls.src, call.args[2], ls), Module) && return true
    return is_include_function(f, call_argtypes(ls, call))
end

"""
    Revise.is_include_function(f, argtypes=Tuple{Vararg{Any}}) -> Bool

Return whether a call of `f` with arguments of the types in the `Tuple` type `argtypes` is an `include`.

That is a call of `Base.include`, `Core.include`, or the `include` of a module, but not of a
function named `include` that a `baremodule` defines. Before Julia 1.12, the call counts only if
every method it may reach is one that defining the module adds.

# Examples

```jldoctest; setup = :(using Revise)
julia> module IncDoc end;

julia> Revise.is_include_function(IncDoc.include, Tuple{String}), Revise.is_include_function(Base.include)
(true, true)

julia> baremodule BareIncDoc
           function include end
           include(x) = x
       end;

julia> Revise.is_include_function(BareIncDoc.include, Tuple{String})
false
```
"""
function is_include_function(@nospecialize(f), @nospecialize(argtypes::Type=Tuple{Vararg{Any}}))
    (f === Base.include || f === Core.include) && return true
    @static if isdefined(Base, :IncludeInto)
        return isa(f, Base.IncludeInto)
    else
        isa(f, Function) && nameof(f) === :include && isa(argtypes, DataType) && argtypes <: Tuple || return false
        ms = Base._methods_by_ftype(Tuple{typeof(f), argtypes.parameters...}, -1, Base.get_world_counter())
        isref(x, mod, name) = x === getglobal(mod, name) || isa(x, GlobalRef) && x.mod === mod && x.name === name
        # The body of a generated method is `Core._call_latest(Base.include, ...)`.
        function generated(m::Method)
            code = Base.uncompressed_ast(m).code
            length(code) == 2 && isexpr(code[1], :call) && length(code[1].args) >= 3 || return false
            return isref(code[1].args[1], Core, :_call_latest) && isref(code[1].args[2], Base, :include)
        end
        return ms isa Vector && !isempty(ms) && all(m -> generated(m.method), ms)
    end
end

# The value flow of a call in the lowered code of a top-level statement, as `analyze` follows
# it. A read of a module's global, as in `Alias.x`, has the origins of that global. Otherwise
# the call does what the summaries of the methods it may reach say. Without exact summaries,
# it may also mutate and return what any argument reaches, unless its inferred effects rule
# out side effects.
function call_origins!(fr::SummaryFrame{LoweredStmt}, call::Expr)
    ls = fr.ctx
    b = resolve_binding(ls.src, call, ls)
    if !isnothing(b)
        push!(fr.reads, global_id(b...))
        return global_origins(fr, GlobalRef(b...))
    end
    f = callee(ls, call.args[1])
    isnothing(f) && return unknown!(fr, call.args)
    fv = something(f)
    if no_mutation(ls, fv, call)
        # A name that is not constant, as in `getglobal(M, s)`
        is_global_read(fv) && binding_access!(fr, binding_operand(fr, call.args[2]), binding_operand(fr, call.args[3]), false)
        add_transform_reads!(fr, call)
        return args_origins(fr, call.args)
    end
    mutates = may_mutate(ls, call)
    if isa(fv, Core.Builtin)
        nm = nameof(fv)
        queries = nm === :isdefinedglobal || nm === :isdefined && length(call.args) >= 3 && arg_type(ls, call.args[2]) <: Module
        return mutates || queries ? builtin!(fr, nm, call.args[2:end]) : args_origins(fr, call.args)
    end
    o = no_origins
    sums = call_summaries(ls, call)
    if !isnothing(sums)
        for s in sums
            # Inferred effects free of side effects override the summary.
            mutates || (s = Summary(no_origins, s.returned, no_origins, s.reads, no_globals,
                                    s.checks, s.nargs, s.isva, s.precision))
            o = o ∪ call!(fr, s, call.args)
        end
        all(s -> s.precision === Exact, sums) && return o
    end
    return o ∪ (mutates ? unknown!(fr, call.args) : args_origins(fr, call.args))
end

frame_type(fr::SummaryFrame{LoweredStmt}, @nospecialize(x)) = arg_type(fr.ctx, x)

# The module or name that `x`, an argument in the code of `fr`, holds if known, else `nothing`.
function binding_operand(fr::SummaryFrame{LoweredStmt}, @nospecialize(x))
    ls = fr.ctx
    m = resolve_module(ls.src, x, ls)
    isnothing(m) || return m
    return resolve_name(ls.src, x, ls)
end

"""
    Revise.add_transform_reads!(fr::Revise.SummaryFrame{Revise.LoweredStmt}, call::Expr)

Record in `fr` what the transform of `call`, an `include(mapexpr, path)` or `include(mapexpr, mod, path)`, reads.

The transform runs on each statement of the included file, so what it reads, including the
functions of the methods it calls, `call` reads. A change of a method of the transform changes
`call`. An unknown transform, or one with more than three methods, makes the summary `Partial`.

# Examples

```jldoctest; setup = :(using Revise)
julia> module TransformDoc
           @noinline body(ex) = ex
           mapper(ex) = body(ex)
       end;

julia> deps(ex) = sort!([n for (_, n) in Revise.global_deps(TransformDoc, ex).reads]);

julia> deps(:(include(mapper, "child.jl")))
3-element Vector{Symbol}:
 :body
 :include
 :mapper

julia> deps(:(include("child.jl")))
1-element Vector{Symbol}:
 :include
```
"""
function add_transform_reads!(fr::SummaryFrame{LoweredStmt}, call::Expr)
    ls = fr.ctx
    length(call.args) in (3, 4) || return nothing
    f = callee(ls, call.args[1])
    isnothing(f) && return nothing
    fv = something(f)
    is_include_function(fv, call_argtypes(ls, call)) || return nothing
    arg_type(ls, call.args[2]) <: Module && return nothing
    t = callee(ls, call.args[2])
    info = isnothing(t) || !isa(something(t), Function) ? nothing : call_lookup(ls, something(t), Tuple{Any})
    if isnothing(info)
        fr.precision = max(fr.precision, Partial)
        return nothing
    end
    for mi in info.mis
        s = summarize(mi, ls.walk)
        reads = unbound_ids(s.reads)
        append!(fr.reads, reads)
        any(<(0), reads) && (fr.hidden = true)
        fr.precision = max(fr.precision, s.precision)
    end
    return nothing
end

# The summaries of the methods `call` may reach, or `nothing` if the callee is unknown, a
# builtin, or has more than `max_methods` methods for the argument types. An empty vector means
# that no method matches, so the call throws.
function call_summaries(ls::LoweredStmt, call::Expr)
    f = callee(ls, call.args[1])
    f === nothing && return nothing
    fv = something(f)
    isa(fv, Core.Builtin) && return nothing
    argtypes = call_argtypes(ls, call)
    argtypes === Union{} && return Summary[]
    info = call_lookup(ls, fv, argtypes)
    info === nothing && return nothing
    return Summary[summarize(mi, ls.walk) for mi in info.mis]
end

function add_owned!(bindings::Set{Tuple{Module,Symbol}}, roots)
    for (m, s) in roots
        owner = binding_owner(m, s)
        owner === Core || push!(bindings, (owner, s))
    end
    return bindings
end

"""
    may_hold_mutable(T) -> Bool

Return `false` if no value of type `T` can reach mutable memory, `true` otherwise.

`String`, `Symbol`, `Module`, and types count as immutable, pointers as mutable. Other values
can reach mutable memory unless `T` is concrete, immutable, and has only field types that
cannot.

# Examples

```jldoctest; setup = :(using Revise)
julia> Revise.may_hold_mutable(Tuple{Int,String}), Revise.may_hold_mutable(Pair{Symbol,Float64})
(false, false)

julia> Revise.may_hold_mutable(Tuple{Int,Vector{Int}})
true

julia> Revise.may_hold_mutable(Any)
true
```
"""
function may_hold_mutable(@nospecialize(T), seen::Base.IdSet{Any}=Base.IdSet{Any}())
    T <: Union{Symbol,String,Module,Type} && return false
    isconcretetype(T) && !ismutabletype(T) || return true
    T <: Union{Ptr,Core.LLVMPtr} && return true
    isprimitivetype(T) && return false
    fieldcount(T) == 0 && return !isbitstype(T)   # a singleton, or opaque like `Core.SimpleVector`
    T in seen && return false
    push!(seen, T)
    for i in 1:fieldcount(T)
        may_hold_mutable(fieldtype(T, i), seen) && return true
    end
    return false
end

"""
    may_hold_ref(T) -> Bool

Return `false` if no value of type `T` can reach a `Base.RefValue`, `true` otherwise.

The elements of an array or `Memory` count, and so do the fields of other concrete types.
`String`, `Symbol`, `Module`, and types reach none, pointers and abstract types may.

# Examples

```jldoctest; setup = :(using Revise)
julia> Revise.may_hold_ref(Vector{Int}), Revise.may_hold_ref(Dict{Symbol,String})
(false, false)

julia> Revise.may_hold_ref(Tuple{Int,Base.RefValue{Bool}}), Revise.may_hold_ref(Vector{Base.RefValue{Bool}})
(true, true)

julia> Revise.may_hold_ref(Vector{Any})
true
```
"""
function may_hold_ref(@nospecialize(T), seen::Base.IdSet{Any}=Base.IdSet{Any}())
    T <: Base.RefValue && return true
    T <: Union{Symbol,String,Module,Type} && return false
    isconcretetype(T) || return true
    T <: Union{Ptr,Core.LLVMPtr} && return true
    T <: array_storage && return may_hold_ref(eltype(T), seen)
    isprimitivetype(T) && return false
    fieldcount(T) == 0 && return !isbitstype(T)   # a singleton, or opaque like `Core.SimpleVector`
    T in seen && return false
    push!(seen, T)
    for i in 1:fieldcount(T)
        may_hold_ref(fieldtype(T, i), seen) && return true
    end
    return false
end
const array_storage = isdefined(Core, :GenericMemory) ? Union{Array,Core.GenericMemory,Core.GenericMemoryRef} : Array

"""
    value_may_hold_ref(b::Tuple{Module,Symbol}) -> Bool

Return whether the global `b` may hold a value that reaches a `Base.RefValue` (see [`Revise.may_hold_ref`](@ref)).

A global that is not `const` may later hold any value, so it may.

# Examples

```jldoctest; setup = :(using Revise)
julia> module HoldRefDoc; const N = [1]; const R = (Ref(1), 2); var = 1; end;

julia> Revise.value_may_hold_ref.([(HoldRefDoc, :N), (HoldRefDoc, :R), (HoldRefDoc, :var)])
3-element BitVector:
 0
 1
 1
```
"""
function value_may_hold_ref(b::Tuple{Module,Symbol})
    @invokelatest(isdefinedglobal(b...)) && @invokelatest(isconst(b...)) || return true
    return may_hold_ref(Core.Typeof(@invokelatest getglobal(b...)))
end

# Whether the inferred effects of `call` allow side effects. An unknown callee may have them,
# and so may one with more than `max_methods` methods for the argument types.
function may_mutate(ls::LoweredStmt, call::Expr)
    f = callee(ls, call.args[1])
    f === nothing && return true
    argtypes = call_argtypes(ls, call)
    argtypes === Union{} && return false
    fv = something(f)
    isa(fv, Core.Builtin) && return cached_inference(infer_mutates, mutates_cache, fv, argtypes)
    info = call_lookup(ls, fv, argtypes)
    return info === nothing || info.mutates
end

# The `CallInfo` of a call of `f` with arguments of the types in `argtypes`, or `nothing` if
# more than `max_methods` methods match. The lookup is recorded in the walk of `ls`.
function call_lookup(ls::LoweredStmt, @nospecialize(f), argtypes::DataType)
    sig = Tuple{Core.Typeof(f), fieldtypes(argtypes)...}
    world = ls.walk.world
    info = @lock inference_lock begin
        world == inference_world[] || reset_inference_caches!(world)
        get(call_cache, sig, missing)
    end
    if info === missing
        info = call_info(sig, world)
        @lock inference_lock inference_world[] == world && (call_cache[sig] = info)
    end
    info === nothing || push!(ls.walk.checks, info.check)
    return info
end

# The current value of the global `b` wrapped in `Some` if `ls` may rely on it, else `nothing`.
# That requires `b` to be `const` and not in `ls.unknown`. The value is recorded in `ls.assumed`.
function known_value(ls::LoweredStmt, b::Tuple{Module,Symbol})
    m, s = binding_owner(b...), b[2]
    (m, s) in ls.unknown && return nothing
    @invokelatest(isdefinedglobal(m, s)) && @invokelatest(isconst(m, s)) || return nothing
    val = @invokelatest getglobal(m, s)
    assume!(ls.assumed, (m, s), val)
    return Some{Any}(val)
end

# The type of the values the global `b` may hold when the statement of `ls` runs.
function binding_type(ls::LoweredStmt, b::Tuple{Module,Symbol})
    v = known_value(ls, b)
    v === nothing || return Core.Typeof(something(v))
    m, s = binding_owner(b...), b[2]
    (m, s) in ls.unknown && return Any
    @invokelatest(isdefinedglobal(m, s)) || return Any
    return @invokelatest Core.get_binding_type(m, s)
end

# The value of the callee `f` in `ls` wrapped in `Some`, or `nothing` if it is not known.
function callee(ls::LoweredStmt, @nospecialize(f))
    b = resolve_binding(ls.src, f, ls)
    b === nothing || return known_value(ls, b)
    if isa(f, Core.SSAValue)
        v = get(ls.ssavalues, f.id, missing)
        v === missing || return v
        return ls.ssavalues[f.id] = folded_value(ls, ls.src.code[f.id])
    end
    isa(f, Union{Core.SlotNumber,Core.Argument,Expr}) && return nothing
    return Some{Any}(unquote(f))
end

# The value of `stmt` wrapped in `Some` if it calls `Core.apply_type`, `Core.tuple`,
# `TypeVar` or `UnionAll` with known arguments, as in `Dict{K, V}()`, a keyword call, or
# `Pair{<:AbstractString, V}`, else `nothing`. None of these has side effects. Calls of
# `Core.get_binding_type` are folded by `untyped_binding`, field reads by `field_value`.
function folded_value(ls::LoweredStmt, @nospecialize(stmt))
    isexpr(stmt, :call) || return nothing
    f = callee(ls, stmt.args[1])
    f === nothing && return nothing
    fv = something(f)
    fv === Core.apply_type || fv === Core.tuple || fv === TypeVar || fv === UnionAll ||
        fv === Core.get_binding_type || fv === getfield || fv === getproperty || return nothing
    if fv === getfield || fv === getproperty
        length(stmt.args) == 3 || return nothing
        xs, name = values_of(ls, stmt.args[2]), callee(ls, stmt.args[3])
        return xs === nothing || name === nothing ? nothing : field_value(fv, xs, something(name), ls.walk.checks)
    end
    args = Any[]
    for i in 2:length(stmt.args)
        v = callee(ls, stmt.args[i])
        v === nothing && return nothing
        push!(args, something(v))
    end
    fv === Core.get_binding_type && return length(args) == 2 ? untyped_binding(ls, args[1], args[2]) : nothing
    try
        return Some{Any}(fv(args...))
    catch err
        isa(err, Union{TypeError,ErrorException}) || rethrow()   # invalid type parameters
        return nothing
    end
end

# `Some(Any)` if the global `m.s` has binding type `Any` and `ls` declares no type for it,
# else `nothing`. Lowering converts a value assigned to a global to its binding type.
function untyped_binding(ls::LoweredStmt, @nospecialize(m), @nospecialize(s))
    isa(m, Module) && isa(s, Symbol) || return nothing
    for stmt in ls.src.code
        isexpr(stmt, :call, 5) || continue   # `Core.declare_global(m, s, strong, type)`
        f = stmt.args[1]
        isa(f, GlobalRef) && f.mod === Core && f.name === :declare_global &&
            stmt.args[2] === m && unquote(stmt.args[3]) === s && return nothing
    end
    return @invokelatest(Core.get_binding_type(m, s)) === Any ? Some{Any}(Any) : nothing
end

# The field `name` read from any of the values `xs`, wrapped in `Some`, as in `VERSION.major`,
# or `nothing` if the values disagree. Each value must be a type or immutable, and a
# `getproperty` call must reach a method that reads the field. That lookup is recorded in
# `checks`. A value without that field makes the call throw, so it is skipped.
function field_value(@nospecialize(f), xs::Vector{Any}, @nospecialize(name), checks::Vector{CallCheck})
    isa(name, f === getproperty ? Symbol : Union{Symbol,Int}) || return nothing
    vals = Any[]
    for x in xs
        isa(x, Type) || !ismutable(x) || return nothing
        if f === getproperty
            check = method_check(Tuple{typeof(getproperty),Core.Typeof(x),Symbol})
            all(m -> m.sig == Tuple{typeof(getproperty),Any,Symbol} || m.sig == Tuple{typeof(getproperty),Type,Symbol},
                check.methods) || return nothing
            push!(checks, check)
        end
        isdefined(x, name) && push!(vals, getfield(x, name))
    end
    isempty(vals) && return nothing
    return all(v -> v === vals[1], vals) ? Some{Any}(vals[1]) : nothing
end

# The values that `x`, an argument in `ls`, may have, or `nothing` if one is not known. A
# local variable may have each value assigned to it.
function values_of(ls::LoweredStmt, @nospecialize(x), seen::BitSet=BitSet())
    isa(x, Core.SSAValue) && isa(ls.src.code[x.id], Core.SlotNumber) && return values_of(ls, ls.src.code[x.id], seen)
    if isa(x, Core.SlotNumber)
        x.id in seen && return nothing
        push!(seen, x.id)
        vals = Any[]
        for stmt in ls.src.code
            isexpr(stmt, :(=), 2) && stmt.args[1] == x || continue
            v = values_of(ls, stmt.args[2], seen)
            v === nothing && return nothing
            append!(vals, v)
        end
        return vals
    end
    v = callee(ls, x)
    return v === nothing ? nothing : Any[something(v)]
end

# The type of the argument `x` in `ls`: see `binding_type` for a global, the inferred return
# type for a call result, `Any` if unknown.
function arg_type(ls::LoweredStmt, @nospecialize(x))
    if isa(x, Core.SSAValue)
        T = get(ls.ssatypes, x.id, missing)
        T === missing || return T
        return ls.ssatypes[x.id] = ssa_type(ls, x)
    end
    b = resolve_binding(ls.src, x, ls)
    b === nothing || return binding_type(ls, b)
    isa(x, Core.SlotNumber) && return get(ls.slottypes, x.id, Any)
    isa(x, Union{Core.Argument,Expr}) && return Any
    return Core.Typeof(unquote(x))
end

function ssa_type(ls::LoweredStmt, x::Core.SSAValue)
    b = resolve_binding(ls.src, x, ls)
    b === nothing || return binding_type(ls, b)
    v = callee(ls, x)
    v === nothing || return Core.Typeof(something(v))
    stmt = ls.src.code[x.id]
    isa(stmt, Union{Core.SlotNumber,Core.SSAValue}) && return arg_type(ls, stmt)
    return isa(stmt, Expr) ? expr_type(ls, stmt) : Any
end

# The type of the value of `ex`, a call or an `Expr(:new, T, …)` in `ls`, or `Any` if unknown.
function expr_type(ls::LoweredStmt, ex::Expr)
    ex.head === :call && return call_type(ls, ex)
    if ex.head === :new
        T = callee(ls, ex.args[1])
        T !== nothing && isa(something(T), DataType) && return something(T)
    end
    return Any
end

function call_type(ls::LoweredStmt, call::Expr)
    f = callee(ls, call.args[1])
    f === nothing && return Any
    argtypes = call_argtypes(ls, call)
    argtypes === Union{} && return Union{}
    fv = something(f)
    if fv === getfield && length(call.args) == 3
        name = callee(ls, call.args[3])
        T = name === nothing ? nothing : field_type(fieldtype(argtypes, 1), something(name))
        T === nothing || return T
    end
    # Destructuring a tuple: `indexed_iterate(t::Tuple, i, state)` returns `(getfield(t, i), i + 1)`.
    if fv === Base.indexed_iterate && length(call.args) >= 3 && fieldtype(argtypes, 1) <: Tuple
        i = callee(ls, call.args[3])
        T = i === nothing ? nothing : field_type(fieldtype(argtypes, 1), something(i))
        T === nothing || return T === Union{} ? Union{} : Tuple{T,Int}
    end
    isa(fv, Core.Builtin) && return cached_inference(infer_rettype, rettype_cache, fv, argtypes)
    info = call_lookup(ls, fv, argtypes)
    return info === nothing ? Any : info.rettype
end

# The type of field `name` of a value of type `T`, or `nothing` if unknown. Inference sees only
# the type of `name`, so for a literal name this is more precise: `(a, b) = (x, 1)` gives `b`
# the type `Int`.
function field_type(@nospecialize(T), @nospecialize(name))
    isa(name, Union{Symbol,Int}) && isa(T, DataType) && !isabstracttype(T) || return nothing
    n = Base.datatype_fieldcount(T)
    n === nothing && return nothing
    (isa(name, Int) ? 1 <= name <= n : hasfield(T, name)) || return Union{}   # the call throws
    return fieldtype(T, name)
end

# The argument types of `call` in `ls` as a `Tuple` type, or `Union{}` if one never returns,
# so that the call is never made.
function call_argtypes(ls::LoweredStmt, call::Expr)
    argtypes = Type[]
    for i in 2:length(call.args)
        T = arg_type(ls, call.args[i])
        T === Union{} && return Union{}
        push!(argtypes, T)
    end
    return Tuple{argtypes...}
end

# A call of a function of type `ft` with arguments of the types in `argtypes`. Fields of a type,
# not `Any`, keep the `Dict` methods from compiling a specialization per signature.
struct SigKey
    ft::Type
    argtypes::Type
end

# Inference results of builtins, `CallInfo`s by call signature, and the checks of
# `instance_check` by method instance, valid in the world `inference_world[]`.
const rettype_cache = Dict{SigKey,Type}()
const mutates_cache = Dict{SigKey,Bool}()
const call_cache = IdDict{Any,Union{Nothing,CallInfo}}()   # a `Dict{Type}` compiles `setindex!` per key type
const instance_check_cache = IdDict{Core.MethodInstance,CallCheck}()
const inference_world = Ref(typemax(UInt))
const inference_lock = ReentrantLock()

function reset_inference_caches!(world::UInt)
    empty!(rettype_cache)
    empty!(mutates_cache)
    empty!(call_cache)
    empty!(instance_check_cache)
    inference_world[] = world
    return nothing
end

infer_rettype(@nospecialize(f), @nospecialize(argtypes::Type), world::UInt) =
    Base.infer_return_type(f, argtypes; world)
# Whether the effects allow side effects.
infer_mutates(@nospecialize(f), @nospecialize(argtypes::Type), world::UInt) =
    !Core.Compiler.is_effect_free(Base.infer_effects(f, argtypes; world))

# The result of `infer(f, argtypes, world)` for the current world, from `cache` if present.
function cached_inference(infer, cache::Dict{SigKey,V}, @nospecialize(f), @nospecialize(argtypes::Type)) where V
    key = SigKey(Core.Typeof(f), argtypes)
    world = Base.get_world_counter()
    @lock inference_lock begin
        world == inference_world[] || reset_inference_caches!(world)
        val = get(cache, key, nothing)
        val === nothing || return val
    end
    val = infer(f, argtypes, world)::V
    @lock inference_lock inference_world[] == world && (cache[key] = val)
    return val
end

unquote(@nospecialize(x)) = isa(x, QuoteNode) ? x.value : x

function add_read!(deps::GlobalDeps, m::Module, s::Symbol)
    owner = binding_owner(m, s)
    owner === Core || push!(deps.reads, (owner, s))
    return deps
end

function add_method_write!(deps::GlobalDeps, mod::Module, @nospecialize(name))
    m, s = isa(name, GlobalRef) ? (name.mod, name.name) : (mod, name)
    isa(s, Symbol) && binding_owner(m, s) === m && push!(deps.writes, (m, s))
    return deps
end

"""
    add_qualified_method_write!(deps::GlobalDeps, mod::Module, src::CodeInfo, sig)

Record in `deps` the write of the function binding that a method definition in `mod` names by
a qualified path, as in `M.f() = 1`.

`sig` is the signature argument of the definition in the lowered code `src`. Only a function
that `mod` owns counts, as for an unqualified definition.

# Examples

```jldoctest; setup = :(using Revise)
julia> qf() = 0; [n for (_, n) in Revise.global_deps(Main, :(Main.qf() = 1)).writes]
1-element Vector{Symbol}:
 :qf

julia> [n for (_, n) in Revise.global_deps(Main, :(Base.show(io::IO, ::Nothing) = nothing)).writes]
Symbol[]
```
"""
function add_qualified_method_write!(deps::GlobalDeps, mod::Module, src::CodeInfo, @nospecialize(sig))
    def(x) = isa(x, Core.SSAValue) ? src.code[x.id] : x
    sv = def(sig)
    is_core_call(sv, :svec) && length(sv.args) >= 2 || return deps
    argtypes = def(sv.args[2])
    is_core_call(argtypes, :svec) && length(argtypes.args) >= 2 || return deps
    ft = def(argtypes.args[2])
    (is_core_call(ft, :Typeof) || is_core_call(ft, :TypeEqOf)) && length(ft.args) == 2 || return deps
    b = resolve_binding(src, ft.args[2])
    (isnothing(b) || b[1] !== mod) && return deps
    return add_method_write!(deps, mod, b[2])
end

function is_core_call(@nospecialize(x), name::Symbol)
    isexpr(x, :call) || return false
    f = x.args[1]
    return isa(f, GlobalRef) && f.mod === Core && f.name === name
end

# The module that owns the binding `m.s`, cached per world by `global_id`.
binding_owner(m::Module, s::Symbol) = global_binding(global_id(m, s))[1]

# The module that owns the binding `m.s` in the latest world, or `m` if `m.s` is undefined or
# implicitly imported from several modules.
function lookup_owner(m::Module, s::Symbol)
    @invokelatest(isdefinedglobal(m, s)) || return m
    try
        return (@invokelatest Base.which(m, s))::Module
    catch err
        isa(err, ErrorException) && occursin("imported from multiple modules", err.msg) || rethrow()
        return m
    end
end

# The `(module, name)` global binding that `x`, an argument in `src`, refers to, if any. The
# module of `M.name` is found as `resolve_module` finds it.
function resolve_binding(src::CodeInfo, @nospecialize(x), ls::Union{Nothing,LoweredStmt}=nothing)
    isa(x, Core.SSAValue) && return resolve_binding(src, src.code[x.id], ls)
    isa(x, GlobalRef) && return (x.mod, x.name)
    if isexpr(x, :call) && length(x.args) in (3, 4) && is_global_read(x.args[1], src)
        m, s = resolve_module(src, x.args[2], ls), resolve_name(src, x.args[3], ls)
        isa(m, Module) && isa(s, Symbol) && return (m, s)
    end
    return nothing
end

# The module that `x`, an argument in `src`, evaluates to, if a `const` global holds it. With
# the statement `ls`, a global that is not `const` counts too, as `assumed_value` records it.
function resolve_module(src::CodeInfo, @nospecialize(x), ls::Union{Nothing,LoweredStmt}=nothing)
    isa(x, Module) && return x
    b = resolve_binding(src, x, ls)
    isnothing(b) && return nothing
    isnothing(ls) || return assumed_value(ls, b, Module)
    @invokelatest(isdefinedglobal(b...)) && @invokelatest(isconst(b...)) || return nothing
    val = @invokelatest getglobal(b...)
    return isa(val, Module) ? val : nothing
end

"""
    Revise.assumed_value(ls::Revise.LoweredStmt, b::Tuple{Module,Symbol}, T::Type) -> Union{Nothing,T}

Return the current value of the global `b` if it is a `T`, and record it in `ls.assumed`.

The record makes a revision analyze the statement of `ls` again once the value changed, so the
global need not be `const`. A global in `ls.unknown` or not defined gives `nothing`.

# Examples

```jldoctest; setup = :(using Revise)
julia> src = Meta.lower(Main, :(identity(1))).args[1];

julia> ls = Revise.LoweredStmt(src, Set{Tuple{Module,Symbol}}(), Dict{Tuple{Module,Symbol},Any}());

julia> S = :a; b = (@__MODULE__, :S); Revise.assumed_value(ls, b, Symbol), ls.assumed[b]
(:a, :a)

julia> Revise.assumed_value(ls, b, Module) === nothing
true

julia> push!(ls.unknown, b); Revise.assumed_value(ls, b, Symbol) === nothing
true
```
"""
function assumed_value(ls::LoweredStmt, b::Tuple{Module,Symbol}, ::Type{T}) where T
    @invokelatest(isdefinedglobal(b...)) || return nothing
    owner = binding_owner(b...)
    (owner, b[2]) in ls.unknown && return nothing
    val = @invokelatest getglobal(b...)
    isa(val, T) || return nothing
    assume!(ls.assumed, (owner, b[2]), val)
    return val
end

# The name that `x`, an argument in `src`, holds, or `nothing` if it is not known. With the
# statement `ls`, a global that holds a name counts too, as `assumed_value` records it.
function resolve_name(src::CodeInfo, @nospecialize(x), ls::Union{Nothing,LoweredStmt})
    s = unquote(x)
    isa(s, Symbol) && return s
    isnothing(ls) && return nothing
    v = callee(ls, x)
    isnothing(v) || return isa(something(v), Symbol) ? something(v) : nothing
    b = resolve_binding(src, x, ls)
    return isnothing(b) ? nothing : assumed_value(ls, b, Symbol)
end

# Whether a name in `names` appears in the surface expression `ex`.
function mentions_any(@nospecialize(ex), names::Set{Symbol})
    isa(ex, Symbol) && return ex in names
    isa(ex, QuoteNode) && return mentions_any(ex.value, names)
    isa(ex, GlobalRef) && return ex.name in names
    if isa(ex, Expr)
        for a in ex.args
            mentions_any(a, names) && return true
        end
    end
    return false
end

"""
    fallback_deps(mod::Module, ex::Expr) -> GlobalDeps

Return conservative dependencies of the top-level statement `ex` in `mod`, for when
[`Revise.global_deps`](@ref) throws.

Reads and writes come from the lowered statement, and every global read counts as mutated
unless it is `const` and cannot reach mutable memory. If `ex` cannot be lowered, every name it
mentions counts as read, and the names that `mod` owns or does not define also count as written.
`assumed` lists the `const` bindings excluded from `mutates`, with their values.

# Examples

```jldoctest; setup = :(using Revise)
julia> V = [1]; const N = 2;

julia> deps = Revise.fallback_deps(@__MODULE__, :(push!(V, N)));

julia> sort!([n for (_, n) in deps.reads]), [n for (_, n) in deps.mutates]
([:N, :V, :push!], [:V])

julia> deps = Revise.fallback_deps(@__MODULE__, :(@no_such_macro W = V));

julia> sort!([string(n) for (_, n) in deps.writes])
3-element Vector{String}:
 "@no_such_macro"
 "V"
 "W"
```
"""
function fallback_deps(mod::Module, ex::Expr)
    deps = GlobalDeps()
    tops = CodeInfo[]
    # Every global read counts as mutated, so no `Ref` contents fold a condition.
    w = DepsWalk(deps, tops, Dict{Any,Any}(), false, false)
    lowered = try
        add_global_deps!(w, mod, expand_stmt(mod, ex))
        append!(deps.checks, w.checks)
        append!(deps.assumed, w.assumed)
        true
    catch err
        isa(err, InterruptException) && rethrow()
        empty!(deps.reads)
        empty!(deps.writes)
        add_mentioned!(deps, mod, ex)
        false
    end
    candidates = lowered ? copy(deps.reads) : union(deps.reads, deps.writes)
    setdiff!(deps.reads, setdiff(deps.writes, old_value_reads(tops, IdDict())))
    for b in candidates
        if value_may_hold_mutable(b)
            push!(deps.mutates, b)
        else
            push!(deps.assumed, b => @invokelatest getglobal(b...))
        end
    end
    return deps
end

# Record each global that `ex` mentions in `deps` as read, and as written as well if `mod`
# owns it or does not define it.
function add_mentioned!(deps::GlobalDeps, mod::Module, @nospecialize(ex))
    if isa(ex, Symbol)
        owner = binding_owner(mod, ex)
        owner === Core && return deps
        push!(deps.reads, (owner, ex))
        owner === mod && push!(deps.writes, (owner, ex))
    elseif isa(ex, QuoteNode)
        add_mentioned!(deps, mod, ex.value)
    elseif isa(ex, GlobalRef)
        add_mentioned!(deps, ex.mod, ex.name)
    elseif isa(ex, Expr)
        if isexpr(ex, :., 2) && isa(ex.args[2], QuoteNode) && isa(ex.args[2].value, Symbol)
            m = qualifier_module(mod, ex.args[1])
            if m !== nothing
                add_read!(deps, m, ex.args[2].value)
                return add_mentioned!(deps, mod, ex.args[1])
            end
        end
        for a in ex.args
            add_mentioned!(deps, mod, a)
        end
    end
    return deps
end

# The module that the surface expression `q`, such as `A` or `A.B`, names in `mod`, if any.
function qualifier_module(mod::Module, @nospecialize(q))
    if isa(q, Symbol)
        m, s = mod, q
    elseif isexpr(q, :., 2) && isa(q.args[2], QuoteNode)
        m, s = qualifier_module(mod, q.args[1]), q.args[2].value
        isa(m, Module) && isa(s, Symbol) || return nothing
    else
        return nothing
    end
    @invokelatest(isdefinedglobal(m, s)) && @invokelatest(isconst(m, s)) || return nothing
    val = @invokelatest getglobal(m, s)
    return isa(val, Module) ? val : nothing
end

# Whether the value of the global `b` may reach mutable memory. A global that is not `const`
# may later hold any value, so it may.
function value_may_hold_mutable(b::Tuple{Module,Symbol})
    @invokelatest(isdefinedglobal(b...)) && @invokelatest(isconst(b...)) || return true
    return may_hold_mutable(Core.Typeof(@invokelatest getglobal(b...)))
end

"""
    cache_global_deps!(stmts)

Store [`Revise.global_deps`](@ref) of each statement in `stmts`, given by its key (see
[`Revise.stmt_key`](@ref)), that is not yet in `global_deps_cache`.

Macros are expanded on the calling task, one statement after another (see
[`Revise.expand_stmt`](@ref)). The rest of the analysis is spread over up to
`Threads.nthreads()` tasks. A statement that cannot be analyzed is logged and gets [`Revise.fallback_deps`](@ref).
"""
function cache_global_deps!(stmts::Vector{StmtKey})
    todo = unique!(filter(key -> !haskey(global_deps_cache, key), stmts))
    isempty(todo) && return nothing
    results = Vector{Union{GlobalDeps,CaughtError}}(undef, length(todo))
    expanded = Vector{Any}(undef, length(todo))
    lowered = [get!(Dict{Any,Any}, lowered_cache, key) for key in todo]
    for (i, (_, mod, rex)) in enumerate(todo)
        expanded[i] = try
            expand_stmt(mod, rex.ex)
        catch err
            CaughtError(err, catch_backtrace())
        end
    end
    next = Threads.Atomic{Int}(1)
    @sync for _ in 1:min(Threads.nthreads(), length(todo))
        Threads.@spawn while (i = Threads.atomic_add!(next, 1)) <= length(todo)
            ex = expanded[i]
            results[i] = isa(ex, CaughtError) ? ex : try
                expanded_deps(todo[i][2], ex, Set{Tuple{Module,Symbol}}(), lowered[i])
            catch err
                CaughtError(err, catch_backtrace())
            end
        end
    end
    for (key, res) in zip(todo, results)
        if isa(res, GlobalDeps)
            cache_deps!(key, res)
        else
            isa(res.err, InterruptException) && throw(res.err)
            log_caught(res.err, res.bt, "GlobalDepsFailed"; deltainfo=(key[2], key[3].ex))
            cache_deps!(key, fallback_deps(key[2], key[3].ex))
        end
    end
    return nothing
end

# Where a tracked top-level statement lives: `(pkgdata, file, fi, mod, exs_infos, rex, mode, pos)`.
# `pos` is `(ipkg, ifile, istmt)`: the package's place in load order, the file's index in the
# package, and the statement's place in the order its file runs (see `stmts_in_source_order`).
# `rank_by_inclusion!` replaces `ifile` by the statement's place in the order loading runs the
# package's statements, which orders statements that do not depend on one another.
const StmtSite = Tuple{PkgData,String,FileInfo,Module,ExprsInfos,RelocatableExpr,Symbol,NTuple{3,Int}}

# The dependencies of the statement `key` from `global_deps_cache`, or `nothing`
# if it has no entry, and whether code the statement calls changed after `world`.
#
# An entry is replaced if a value it relied on changed, or a method lookup or inference result
# it relied on no longer holds. The replacement keeps the old `mutates` until the statement
# runs again, since its last run may have mutated them, and `former_reads` keeps the old
# reads of the globals it assigns. An entry that relied on a value in `dirty`, which the
# revision may still change, is recomputed with those values unknown, and the result is not
# cached.
function current_deps(key::StmtKey, dirty::Set{Tuple{Module,Symbol}}, world::UInt)
    deps = get(global_deps_cache, key, nothing)
    deps === nothing && return nothing, false
    changed = !@invokelatest assumed_hold(deps.assumed)
    affected = any(((b, _),) -> b in dirty, deps.assumed)
    stale = typemax(UInt)
    for c in deps.checks
        stale = min(stale, invalid_since(c))
    end
    codechanged = stale != typemax(UInt)
    changed || affected || codechanged || return deps, false
    _, mod, rex = key
    fresh = try
        global_deps(mod, rex.ex; unknown=affected ? dirty : Set{Tuple{Module,Symbol}}(),
                    lowered=get!(Dict{Any,Any}, lowered_cache, key))
    catch err
        isa(err, InterruptException) && rethrow()
        log_caught(err, catch_backtrace(), "GlobalDepsFailed"; deltainfo=(mod, rex.ex))
        fallback_deps(mod, rex.ex)
    end
    union!(fresh.mutates, setdiff(deps.mutates, fresh.writes))
    record_former_reads!(deps)
    affected ? apply_evaluated!(key, apply_observed!(key, fresh)) : cache_deps!(key, fresh)
    return fresh, codechanged && stale > world
end

# Whether every `(module, name) => value` pair of `assumed` still holds. Bindings postdate
# Revise's frozen world, so call it in the latest world.
assumed_hold(assumed) = all(((b, v),) -> isdefinedglobal(b...) && holds_value(getglobal(b...), v), assumed)

"""
    Revise.RefContents(ref, value)

The assumption that a global holds `ref` and that `ref[]` is `value`, as the analysis of a statement records it in place of `ref`.
"""
struct RefContents
    ref::Base.RefValue
    value::Any
end

# Whether a global that holds `current` satisfies the assumption `v`, a value or a `RefContents`.
holds_value(@nospecialize(current), @nospecialize(v)) = isa(v, RefContents) ? current === v.ref && v.ref[] === v.value : current === v

# Record in `assumed` that the global `b` holds `v`, unless a `RefContents` of `v` already records more.
function assume!(assumed::Dict{Tuple{Module,Symbol},Any}, b::Tuple{Module,Symbol}, @nospecialize(v))
    old = get(assumed, b, nothing)
    isa(old, RefContents) && old.ref === v || (assumed[b] = v)
    return assumed
end

# A top-level statement selected for reevaluation.
struct DependentStmt
    pkgdata::PkgData
    file::String
    fi::FileInfo
    mod::Module
    exs_infos::ExprsInfos
    rex::RelocatableExpr
    mode::Symbol
    pos::NTuple{3,Int}
    deps::GlobalDeps
end

"""
    dependency_seeds(changed, deleted; evaluated::Bool) -> (dirty, mutated, dirtypkgs, done)

Return the bindings written by the `(pkgdata, file, mod, rex)` statements in `changed` and
`deleted`, the bindings mutated by those of them evaluated under `:eval`, the packages holding
them, and the `(file, mod, rex)` keys of `changed`.

`evaluated` tells whether the revision has evaluated `changed` and removed `deleted`. Then the
dependencies of `changed` are analyzed again, and those of `deleted` are dropped from the cache.
"""
function dependency_seeds(changed::Vector{TrackedStmt}, deleted::Vector{TrackedStmt}; evaluated::Bool)
    dirty = Set{Tuple{Module,Symbol}}()
    mutated = Set{Tuple{Module,Symbol}}()
    dirtypkgs = Set{PkgId}(first(v) for v in values(failed_dependents))
    done = Set{Tuple{String,Module,RelocatableExpr}}()
    if evaluated
        for (_, _, mod, rex) in changed
            uncache_deps!(stmt_key(mod, rex))
        end
    end
    cache_global_deps!([stmt_key(mod, rex) for (_, _, mod, rex) in Iterators.flatten((changed, deleted))])
    for (isdeleted, stmts) in ((false, changed), (true, deleted)), (pkgdata, file, mod, rex) in stmts
        isdeleted || push!(done, (file, mod, rex))
        evaluated && forget_failure!(pkgdata, file, mod, rex)
        add_method_owners!(dirtypkgs, stmt_exinfos(pkgdata, file, mod, rex))
        key = stmt_key(mod, rex)
        deps, _ = current_deps(key, dirty, typemax(UInt))
        deps === nothing && continue
        if isdeleted && evaluated
            uncache_deps!(key)
            delete!(lowered_cache, key)
            delete!(observed_reads, key)
            delete!(evaluated_deps, key)
            record_former_reads!(deps)
        end
        union!(dirty, deps.writes)
        revise_mode(mod, default_revise_mode(pkgdata)) === :eval && union!(mutated, deps.mutates)
        push!(dirtypkgs, PkgId(pkgdata))
    end
    return dirty, mutated, dirtypkgs, done
end

# The signatures and types that the statement `rex` of `mod` in `file` of `pkgdata` defines, or
# `nothing` if they are not known.
function stmt_exinfos(pkgdata::PkgData, file::String, mod::Module, rex::RelocatableExpr)
    for idx in fileindices(pkgdata, file)
        exs_infos = get(fileinfo(pkgdata, idx).mod_exs_infos, mod, nothing)
        isnothing(exs_infos) && continue
        exinfos = get(exs_infos, rex, nothing)
        isnothing(exinfos) || return exinfos
    end
    return nothing
end

"""
    Revise.add_method_owners!(pkgs::Set{PkgId}, exinfos) -> pkgs

Add to `pkgs`, for each method in `exinfos`, a package that every call of the method requires.

A call matches the signature only with values of the types that
[`Revise.required_modules`](@ref) returns, so a change of the method can affect only the packages
that require all of their owners. Of these, the one loaded last is added, since it is the only
one that can require the others, or `Base` if there is none.

# Examples

```jldoctest; setup = :(using Revise)
julia> owners(sig) = sort!([id.name for id in Revise.add_method_owners!(Set{Base.PkgId}(), [Revise.SigInfo(nothing, sig)])]);

julia> owners(Tuple{typeof(push!), Vector{Revise.CodeTracking.PkgFiles}, Revise.PkgData})
1-element Vector{String}:
 "Revise"

julia> owners(Tuple{typeof(show), IO, Union{Revise.CodeTracking.PkgFiles, Revise.PkgData}})
1-element Vector{String}:
 "Base"
```
"""
function add_method_owners!(pkgs::Set{PkgId}, exinfos)
    isnothing(exinfos) && return pkgs
    order = nothing
    for e in exinfos
        isa(e, SigInfo) || continue
        owners = Module[]
        for m in required_modules(e.sig)
            root = Base.moduleroot(m)
            root === Base || root === Core || root in owners || push!(owners, root)
        end
        if length(owners) > 1
            loaded = isnothing(order) ? (order = Base.loaded_modules_array()) : order
            owner = argmax(m -> something(findfirst(x -> x === m, loaded), 0), owners)
        else
            owner = isempty(owners) ? Base : only(owners)
        end
        push!(pkgs, PkgId(owner))
    end
    return pkgs
end

"""
    Revise.required_modules(T) -> Set{Module}

Return the modules that own a type every value of type `T` involves, either as its own type or as one of its parameters.

A `Union` requires what all of its members require, a type variable what its upper bound
requires, and a `Vararg` nothing, since it can match zero arguments. Parameters that are not
types are ignored.

# Examples

```jldoctest; setup = :(using Revise)
julia> sort!(nameof.(collect(Revise.required_modules(Tuple{typeof(+), Vector{Revise.PkgData}, Int}))))
3-element Vector{Symbol}:
 :Base
 :Core
 :Revise

julia> sort!(nameof.(collect(Revise.required_modules(Tuple{Union{Int, Revise.PkgData}}))))
1-element Vector{Symbol}:
 :Core

julia> sort!(nameof.(collect(Revise.required_modules(Tuple{Vararg{Revise.PkgData}}))))
1-element Vector{Symbol}:
 :Core
```
"""
function required_modules(@nospecialize(T), path::Base.IdSet{Any}=Base.IdSet{Any}())
    mods = Set{Module}()
    T in path && return mods
    push!(path, T)
    if isa(T, UnionAll)
        union!(mods, required_modules(T.body, path))
    elseif isa(T, Union)
        union!(mods, intersect(required_modules(T.a, path), required_modules(T.b, path)))
    elseif isa(T, TypeVar)
        union!(mods, required_modules(T.ub, path))
    elseif is_typeeq(T)
        union!(mods, required_modules(typeeq_parameter(T), path))
    elseif isa(T, DataType)
        push!(mods, T.name.module)
        for p in T.parameters
            isa(p, Core.TypeofVararg) || union!(mods, required_modules(p, path))
        end
    end
    delete!(path, T)
    return mods
end

"""
    prepare_dependents!(added, deleted) -> dirtypkgs

Analyze the tracked statements that the revision can affect, and extract the method
signatures of the files holding statements that read a binding written by `added` or
`deleted`, before the revision changes any code or binding.

The analysis tells later which statements call code that the revision changed. Without the
extraction, a dependent statement would get signatures computed from the new bindings, and its
old methods could not be deleted. Failures are logged, not thrown. Return the packages whose statements the
revision can affect, including the owners of the methods `deleted` defines (see
[`Revise.add_method_owners!`](@ref)), which are not known once the methods are deleted.
"""
function prepare_dependents!(added::Vector{TrackedStmt}, deleted::Vector{TrackedStmt})
    dirty, mutated, dirtypkgs, done = dependency_seeds(added, deleted; evaluated=false)
    if isempty(dirty) && isempty(mutated)
        refresh_index!(dep_index, affected_tracked(dirtypkgs))
    else
        # `select_dependents!` analyzes the statements of `dirtypkgs` too.
        for d in select_dependents!(dirty, mutated, dirtypkgs, done, Base.get_world_counter())
            d.fi.extracted[] && continue
            try
                maybe_extract_sigs!(d.fi)
            catch err
                isa(err, InterruptException) && rethrow()
                log_caught(err, catch_backtrace(), "ExtractSigsFailed"; file=d.file)
            end
        end
    end
    # The owners of the bindings `added` reads can change once it is evaluated.
    for (_, _, mod, rex) in added
        uncache_deps!(stmt_key(mod, rex))
    end
    return dirtypkgs
end

"""
    reeval_dependent_statements!(revision_errors, changed, deleted, world; throw=false, pkgs=Set{PkgId}())

Reevaluate every unchanged tracked top-level statement that reads a binding written by a
statement in `changed` or `deleted`, or calls code that changed after `world`, transitively.

`changed` lists the `(pkgdata, file, mod, rex)` statements this revision evaluated, `deleted`
those it removed, and `world` is the world in which the revision started. `pkgs` adds packages
whose statements the revision can affect (see [`Revise.prepare_dependents!`](@ref)).

The selection repeats for what each round changed until a round selects nothing. Files that
reevaluated statements newly `include` are evaluated, and those they no longer include are
removed (see [`Revise.remove_includes!`](@ref)). Failures are recorded like other revision
errors. With `throw`, the first failure that no later run cleared is thrown at the end.
"""
function reeval_dependent_statements!(revision_errors::Vector{Tuple{PkgData,String}},
                                      changed::Vector{TrackedStmt}, deleted::Vector{TrackedStmt}, world::UInt;
                                      throw::Bool=false, pkgs::Set{PkgId}=Set{PkgId}())
    dirty, mutated, dirtypkgs, done = dependency_seeds(changed, deleted; evaluated=true)
    union!(dirtypkgs, pkgs)
    failures = CaughtError[]   # the first is thrown at the end under `throw` or `rethrow_errors[]`
    while true
        selected = select_dependents!(dirty, mutated, dirtypkgs, done, world)
        isempty(selected) && break
        world = Base.get_world_counter()
        empty!(dirty)
        empty!(mutated)
        sort!(rank_by_inclusion!(selected); by = d -> d.pos)
        pass = RevisionPass(revision_errors, IdSet{Union{Method,Type}}(), IdSet{Type}(), world, TypePredictions(), throw)
        dropped = IdDict{PkgData,Set{Tuple{String,Module}}}()
        for d in order_dependents(selected)
            reeval_dependent!(pass, dropped, failures, d, dirty, mutated, dirtypkgs)
        end
        evaluate_worklist!(pass)
        # Decided once every statement of the round ran, since one can include what another dropped.
        removed = Tuple{PkgData,String,Int,Bool}[]
        for (pkgdata, targets) in dropped
            try
                remove_includes!(revision_errors, pkgdata, targets, removed, dirty, mutated, dirtypkgs; throw)
            catch err
                handle_caught(err, catch_backtrace(), "OrphanScanFailed"; throw = throw || isa(err, InterruptException))
            end
        end
        # The evaluation relies on stable `pkgdata.fileinfos` indices.
        isempty(removed) || deregister_orphaned_includes!(removed)
        isempty(pass.reeval_list) || redefine_bindings!(revision_errors, pass.reeval_list, world, pass.evaluated)
        isempty(pass.evaluated) && continue
        newdirty, newmutated, newpkgs, newdone = dependency_seeds(pass.evaluated, TrackedStmt[]; evaluated=true)
        union!(dirty, newdirty)
        union!(mutated, newmutated)
        union!(dirtypkgs, newpkgs)
        union!(done, newdone)
    end
    filter!(c -> any(v -> v[2] === c, values(failed_dependents)), failures)
    isempty(failures) && return revision_errors
    throw && Base.throw(failures[1].err)
    throw_deferred(failures[1].err, failures[1].bt)
    return revision_errors
end

# Reevaluate `d`. The files it newly includes are evaluated in the `RevisionPass` `pass`. The
# `(path, module)` inclusions it no longer includes are added to `dropped`, per package.
function reeval_dependent!(pass, dropped::IdDict{PkgData,Set{Tuple{String,Module}}}, failures::Vector{CaughtError},
                           d::DependentStmt, dirty::Set{Tuple{Module,Symbol}}, mutated::Set{Tuple{Module,Symbol}},
                           dirtypkgs::Set{PkgId})
    (; pkgdata, file, fi, mod, exs_infos, rex, mode) = d
    revision_errors = pass.revision_errors
    # Its file is no longer included
    any(f -> f === fi, pkgdata.fileinfos) || return nothing
    # Analyzed again once it ran, without what its earlier runs may have mutated
    lastdeps = uncache_deps!(stmt_key(mod, rex))
    isnothing(lastdeps) || record_former_reads!(lastdeps)
    try
        maybe_extract_sigs!(fi)
        before = include_paths(pkgdata, file, get(fi.includes, (mod, rex), ()))
        includes = with_logger(_debug_logger) do
            @debug "ReevalDependent" _group="Action" time=time() deltainfo=(mod, rex.ex, mode)
            old = get(exs_infos, rex, nothing)
            newexinfos, incs, exinfo = eval_new_stmt(mod, rex.ex; mode)
            record_run!(file, mod, rex)
            record_observed!(stmt_key(mod, rex), exinfo)
            exs_infos[rex] = newexinfos
            delete_stale_methods!(old, newexinfos)
            add_method_owners!(dirtypkgs, old)
            add_method_owners!(dirtypkgs, newexinfos)
            return incs
        end
        record_includes!(fi.includes, mod, rex, includes)
        maybe_add_includes_to_pkgdata!(pkgdata, file, includes; eval_now=true,
            revise=(pd, incrp, i) -> schedule_include!(pass, pd, incrp, i, length(pass.worklist)))
        gone = setdiff(before, include_paths(pkgdata, file, includes))
        isempty(gone) || union!(get!(Set{Tuple{String,Module}}, dropped, pkgdata), gone)
        forget_failure!(pkgdata, file, mod, rex)
    catch err
        bt = catch_backtrace()
        caught = CaughtError(err, bt)
        prev = pop!(failed_dependents, (file, mod, rex), nothing)
        failed_dependents[(file, mod, rex)] = (PkgId(pkgdata), caught)
        log_caught(err, bt, "ReevalDependentFailed"; deltainfo=(mod, rex.ex))
        push!(revision_errors, (pkgdata, file))
        # The first error of a file is kept, unless it is this statement's previous one.
        qe = get(queue_errors, (pkgdata, file), nothing)
        if isnothing(qe) || !isnothing(prev) && qe[1] === prev[2].err
            queue_errors[(pkgdata, file)] = (err, bt)
        end
        push!(failures, caught)
    end
    return nothing
end

# Forget the failure of the dependent statement `rex` of `mod` in `file`, if any, and its error.
function forget_failure!(pkgdata::PkgData, file::String, mod::Module, rex::RelocatableExpr)
    prev = pop!(failed_dependents, (file, mod, rex), nothing)
    isnothing(prev) || clear_dependent_error!(pkgdata, file, prev[2])
    return nothing
end

# Remove `caught`, the error of a dependent statement in `file` that now succeeded, from
# `queue_errors`, or replace it with the error of another failed dependent statement in `file`.
# An error recorded by other code stays.
function clear_dependent_error!(pkgdata::PkgData, file::String, caught::CaughtError)
    qe = get(queue_errors, (pkgdata, file), nothing)
    (isnothing(qe) || qe[1] !== caught.err) && return nothing
    id = PkgId(pkgdata)
    for ((f, _, _), (pid, other)) in failed_dependents
        if pid == id && f == file
            queue_errors[(pkgdata, file)] = (other.err, other.bt)
            return nothing
        end
    end
    delete!(queue_errors, (pkgdata, file))
    return nothing
end

"""
    Revise.remove_includes!(revision_errors, pkgdata::PkgData, targets, removed, dirty, mutated, dirtypkgs; throw=false)

Remove the `(path, module)` inclusions `targets` of `pkgdata` that no `include` keeps, and the files only they include, as an edit that deletes their `include` does.

The methods of the removed files are deleted, and the bindings of their statements join
`dirty`, `mutated`, and `dirtypkgs`. The inclusions are appended to `removed` as
`(pkgdata, path, idx, unwatch)` and stay registered until
`Revise.deregister_orphaned_includes!(removed)`, which keeps the indices of `pkgdata.fileinfos`.
Targets that `pkgdata` does not include are skipped.

# Examples

```jldoctest; setup = :(using Revise)
julia> dir = mktempdir(); src = mkpath(joinpath(dir, "RmInc", "src")); push!(LOAD_PATH, dir);

julia> write(joinpath(src, "RmInc.jl"), "__precompile__(false)\\nmodule RmInc\\nconst CHILD = \\\"a.jl\\\"\\ninclude(CHILD)\\nend\\n");

julia> write(joinpath(src, "a.jl"), "f() = 1\\n"); using RmInc; pop!(LOAD_PATH);

julia> pd = Revise.pkgdatas[Base.PkgId(RmInc)]; errs = Tuple{Revise.PkgData,String}[]; removed = Tuple{Revise.PkgData,String,Int,Bool}[];

julia> seeds = (Set{Tuple{Module,Symbol}}(), Set{Tuple{Module,Symbol}}(), Set{Base.PkgId}());

julia> Revise.remove_includes!(errs, pd, [("src/b.jl", RmInc)], removed, seeds...); isempty(removed)
true

julia> Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
           Revise.remove_includes!(errs, pd, [("src/a.jl", RmInc)], removed, seeds...)
       end; Revise.deregister_orphaned_includes!(removed); basename.(Revise.srcfiles(pd))
1-element Vector{String}:
 "RmInc.jl"

julia> isempty(methods(RmInc.f)), (RmInc, :f) in seeds[1]
(true, true)
```
"""
function remove_includes!(revision_errors::Vector{Tuple{PkgData,String}}, pkgdata::PkgData, targets,
                          removed::Vector{Tuple{PkgData,String,Int,Bool}}, dirty::Set{Tuple{Module,Symbol}},
                          mutated::Set{Tuple{Module,Symbol}}, dirtypkgs::Set{PkgId}; throw::Bool=false)
    stmts = TrackedStmt[]
    remove_unincluded!(removed, revision_errors, pkgdata, Set{Tuple{String,Module}}(targets), stmts, dirtypkgs; throw)
    seeds = dependency_seeds(TrackedStmt[], stmts; evaluated=true)
    union!(dirty, seeds[1])
    union!(mutated, seeds[2])
    union!(dirtypkgs, seeds[3])
    return removed
end

add_id!(ix::AbstractDict, @nospecialize(k), id::Int) = (push!(get!(Set{Int}, ix, k), id); nothing)

function remove_id!(ix::AbstractDict, @nospecialize(k), id::Int)
    ids = get(ix, k, nothing)
    isnothing(ids) && return nothing
    delete!(ids, id)
    isempty(ids) && delete!(ix, k)
    return nothing
end

"""
    Revise.refresh_index!(dx::Revise.DepIndex, pkgs::Set{PkgId}) -> dx

Bring `dx` up to date for the tracked packages `pkgs`: list the statements of their files, analyze those without an entry in `global_deps_cache`, and index the current entries.

A file is listed anew when its `FileInfo`, its modules, or their numbers of statements changed.
A statement keeps its number while it is the same object (see [`Revise.adopt_twins!`](@ref)).
Files and packages no longer tracked are dropped. The entries that changed since the last call
(see [`Revise.cache_deps!`](@ref)) are indexed anew in every package.

# Examples

```jldoctest; setup = :(using Revise)
julia> dir = mktempdir(); src = mkpath(joinpath(dir, "IndexDoc", "src")); push!(LOAD_PATH, dir);

julia> write(joinpath(src, "IndexDoc.jl"), "__precompile__(false)\\nmodule IndexDoc\\nconst A = 1\\nconst B = A + 1\\nend\\n");

julia> using IndexDoc; pop!(LOAD_PATH); dx = Revise.DepIndex();

julia> Revise.refresh_index!(dx, Set([Base.PkgId(IndexDoc)])); [string(dx.stmts[id].rex.ex.args[end]) for id in dx.readers[(IndexDoc, :A)]]
1-element Vector{String}:
 "const B = A + 1"

julia> haskey(dx.readers, (IndexDoc, :B)), isempty(dx.nodeps)
(false, true)
```
"""
function refresh_index!(dx::DepIndex, pkgs::Set{PkgId})
    function setdeps!(id::Int, deps::Union{Nothing,GlobalDeps})
        s = dx.stmts[id]::IndexedStmt
        old = s.deps
        if isnothing(old)
            delete!(dx.nodeps, id)
        else
            foreach(b -> remove_id!(dx.readers, b, id), old.reads)
            foreach(b -> remove_id!(dx.writers, b, id), old.writes)
            foreach(b -> remove_id!(dx.mutators, b, id), old.mutates)
            for (b, v) in old.assumed
                byvalue = get(dx.assumed, b, nothing)
                isnothing(byvalue) && continue
                remove_id!(byvalue, v, id)
                isempty(byvalue) && delete!(dx.assumed, b)
            end
            foreach(c -> remove_id!(dx.checks, c, id), old.checks)
            delete!(dx.readsall, id)
        end
        s.deps = deps
        if isnothing(deps)
            push!(dx.nodeps, id)
        else
            foreach(b -> add_id!(dx.readers, b, id), deps.reads)
            foreach(b -> add_id!(dx.writers, b, id), deps.writes)
            foreach(b -> add_id!(dx.mutators, b, id), deps.mutates)
            foreach(((b, v),) -> add_id!(get!(IdDict{Any,Set{Int}}, dx.assumed, b), v, id), deps.assumed)
            foreach(c -> add_id!(dx.checks, c, id), deps.checks)
            deps.readsall && push!(dx.readsall, id)
        end
        return nothing
    end
    function addstmt!(pkgdata, file, fi, mod, exs_infos, rex)
        push!(dx.stmts, IndexedStmt(pkgdata, file, fi, mod, exs_infos, rex, nothing))
        id = length(dx.stmts)
        push!(get!(Vector{Int}, dx.bykey, stmt_key(mod, rex)), id)
        setdeps!(id, get(global_deps_cache, stmt_key(mod, rex), nothing))
        return id
    end
    function dropid!(id::Int)
        s = dx.stmts[id]::IndexedStmt
        setdeps!(id, nothing)
        delete!(dx.nodeps, id)
        key = stmt_key(s.mod, s.rex)
        ids = dx.bykey[key]
        filter!(!=(id), ids)
        isempty(ids) && delete!(dx.bykey, key)
        dx.stmts[id] = nothing
        return nothing
    end
    function liststmt!(reuse, pkgdata, file, fi, mod, exs_infos, rex)
        id = pop!(reuse, rex, 0)
        id == 0 && return addstmt!(pkgdata, file, fi, mod, exs_infos, rex)
        s = dx.stmts[id]::IndexedStmt
        dx.stmts[id] = IndexedStmt(pkgdata, file, fi, mod, exs_infos, rex, s.deps)
        deps = get(global_deps_cache, stmt_key(mod, rex), nothing)
        s.deps === deps || setdeps!(id, deps)
        return id
    end
    function applychanged!()
        for key in dx.changed, id in get(dx.bykey, key, ())
            deps = get(global_deps_cache, key, nothing)
            (dx.stmts[id]::IndexedStmt).deps === deps || setdeps!(id, deps)
        end
        empty!(dx.changed)
        return nothing
    end
    for (pkgdata, files) in collect(dx.files)
        get(pkgdatas, PkgId(pkgdata), nothing) === pkgdata && continue
        foreach(rec -> foreach(dropid!, rec.ids), values(files))
        delete!(dx.files, pkgdata)
    end
    for (id, pkgdata) in pkgdatas
        id in pkgs || continue
        files = get!(IdDict{ModuleExprsInfos,IndexedFile}, dx.files, pkgdata)
        current = IdSet{ModuleExprsInfos}()
        relist = Tuple{String,FileInfo,Vector{Tuple{Module,ExprsInfos,Int}}}[]
        for ifile in eachindex(srcfiles(pkgdata))
            file = srcfiles(pkgdata)[ifile]
            if is_not_populated(fileinfo(pkgdata, ifile))
                try
                    maybe_parse_from_cache!(pkgdata, file, fileinfo(pkgdata, ifile))
                catch err
                    isa(err, StaleCacheError) || rethrow()
                    continue
                end
            end
            fi = fileinfo(pkgdata, ifile)
            parts = Tuple{Module,ExprsInfos,Int}[(mod, exs_infos, length(exs_infos)) for (mod, exs_infos) in fi.mod_exs_infos]
            rec = get(files, fi.mod_exs_infos, nothing)
            if !isnothing(rec) && rec.fi === fi && length(rec.parts) == length(parts) &&
                    all(((p, q),) -> p[1] === q[1] && p[2] === q[2] && p[3] == q[3], zip(rec.parts, parts))
                push!(current, fi.mod_exs_infos)
                continue
            end
            push!(relist, (file, fi, parts))
        end
        reuse = IdDict{RelocatableExpr,Int}()
        for (k, rec) in collect(files)
            k in current && continue
            foreach(i -> reuse[(dx.stmts[i]::IndexedStmt).rex] = i, rec.ids)
            delete!(files, k)
        end
        for (file, fi, parts) in relist
            ids = Int[]
            for (mod, exs_infos) in fi.mod_exs_infos, rex in keys(exs_infos)
                push!(ids, liststmt!(reuse, pkgdata, file, fi, mod, exs_infos, rex))
            end
            files[fi.mod_exs_infos] = IndexedFile(fi, parts, ids)
        end
        foreach(dropid!, values(reuse))
    end
    applychanged!()
    todo = StmtKey[]
    for id in dx.nodeps
        s = dx.stmts[id]::IndexedStmt
        PkgId(s.pkgdata) in pkgs && push!(todo, stmt_key(s.mod, s.rex))
    end
    cache_global_deps!(todo)
    for key in todo, id in dx.bykey[key]
        setdeps!(id, get(global_deps_cache, key, nothing))
    end
    applychanged!()
    return dx
end

"""
    Revise.check_dep_index(dx::Revise.DepIndex) -> Bool

Return whether the indices of `dx` list exactly the current entries of `global_deps_cache` of its statements.

Changes that [`Revise.refresh_index!`](@ref) has not indexed yet count as a mismatch.

# Examples

```jldoctest; setup = :(using Revise)
julia> dir = mktempdir(); src = mkpath(joinpath(dir, "CheckIndexDoc", "src")); push!(LOAD_PATH, dir);

julia> write(joinpath(src, "CheckIndexDoc.jl"), "__precompile__(false)\\nmodule CheckIndexDoc\\nconst A = 1\\nconst B = A + 1\\nend\\n");

julia> using CheckIndexDoc; pop!(LOAD_PATH); dx = Revise.refresh_index!(Revise.DepIndex(), Set([Base.PkgId(CheckIndexDoc)]));

julia> Revise.check_dep_index(dx)
true

julia> push!(dx.readers[(CheckIndexDoc, :A)], 0); Revise.check_dep_index(dx)
false
```
"""
function check_dep_index(dx::DepIndex)
    isempty(dx.changed) || return false
    expect = DepIndex()
    for (id, s) in pairs(dx.stmts)
        isnothing(s) && continue
        key = stmt_key(s.mod, s.rex)
        s.deps === get(global_deps_cache, key, nothing) || return false
        any(==(id), get(dx.bykey, key, ())) || return false
        push!(get!(Vector{Int}, expect.bykey, key), id)
        d = s.deps
        if isnothing(d)
            push!(expect.nodeps, id)
            continue
        end
        foreach(b -> add_id!(expect.readers, b, id), d.reads)
        foreach(b -> add_id!(expect.writers, b, id), d.writes)
        foreach(b -> add_id!(expect.mutators, b, id), d.mutates)
        foreach(((b, v),) -> add_id!(get!(IdDict{Any,Set{Int}}, expect.assumed, b), v, id), d.assumed)
        foreach(c -> add_id!(expect.checks, c, id), d.checks)
        d.readsall && push!(expect.readsall, id)
    end
    return all(((k, ids),) -> sort(ids) == sort(get(expect.bykey, k, Int[])), dx.bykey) &&
           length(dx.bykey) == length(expect.bykey) &&
           dx.readers == expect.readers && dx.writers == expect.writers && dx.mutators == expect.mutators &&
           dx.assumed == expect.assumed && dx.checks == expect.checks &&
           dx.readsall == expect.readsall && dx.nodeps == expect.nodeps
end

# The statements in `assumed`, which maps a binding to the values that statements assumed for it,
# whose binding is undefined or holds another value. Call it in the latest world.
function changed_assumptions(assumed::Dict{Tuple{Module,Symbol},IdDict{Any,Set{Int}}})
    ids = Int[]
    for (b, byvalue) in assumed
        defined = isdefinedglobal(b...)
        current = defined ? getglobal(b...) : nothing
        for (v, s) in byvalue
            defined && holds_value(current, v) || append!(ids, s)
        end
    end
    return ids
end

# Select the tracked statements that read a binding in `dirty`, transitively: the writes of
# each selected one join `dirty`. The statements of the packages that `dirtypkgs` affects are
# brought up to date in `dep_index` first (see `refresh_index!`), and its indices give the
# statements to check: those that read a binding in `dirty`, or whose analysis relied on one,
# those whose method lookups no longer hold or whose assumed values changed, those of `done`,
# and those whose last reevaluation failed. Each is checked with its current dependencies
# (see `current_deps`), and every statement that a selected one can affect is checked as well.
#
# A statement of `done` that this revision evaluated is selected once more if it reads a
# binding a selected statement writes, since it ran before that statement, or if code it calls
# changed after its last run. A binding in `mutated`, or mutated by a selected statement under
# `:eval`, is replayed if `replayable` allows it: the statements that assign it are selected as
# well, and through them every statement that reads it. A statement that calls code that
# changed after `world` is selected as well, and so is a statement whose last reevaluation
# failed.
function select_dependents!(dirty::Set{Tuple{Module,Symbol}}, mutated::Set{Tuple{Module,Symbol}},
                            dirtypkgs::Set{PkgId}, done::Set{Tuple{String,Module,RelocatableExpr}}, world::UInt)
    dx = dep_index
    selected = DependentStmt[]
    evaluated = copy(done)
    selwrites = Set{Tuple{Module,Symbol}}()
    pending = Set{Tuple{Module,Symbol}}()
    decided = Set{Tuple{Module,Symbol}}()
    replay = Set{Tuple{Module,Symbol}}()
    affected = Set{PkgId}()
    # Per statement of `dx`: its current dependencies, once checked
    deps = Dict{Int,Union{Nothing,GlobalDeps}}()
    codechanged, isselected, nodeps = Set{Int}(), Set{Int}(), Set{Int}()
    # Current dependencies that the indices of `dx` may not list
    readers, writers, mutators, assumers = (Dict{Tuple{Module,Symbol},Set{Int}}() for _ in 1:4)
    readsall = Set{Int}()
    modes = Dict{Module,Symbol}()
    loadorder = Dict{PkgId,Int}()
    rexpos = IdDict{ModuleExprsInfos,IdDict{RelocatableExpr,Int}}()
    queue = Int[]   # statements to check
    stmt(id) = dx.stmts[id]::IndexedStmt
    keyof(id) = (s = stmt(id); (s.file, s.mod, s.rex))
    modeof(id) = (s = stmt(id); get!(() -> revise_mode(s.mod, default_revise_mode(s.pkgdata)), modes, s.mod))
    noids = Set{Int}()   # never filled: a default of the type of the values, for static dispatch
    readers_of(b) = Iterators.flatten((get(dx.readers, b, noids), get(readers, b, noids)))
    writers_of(b) = Iterators.flatten((get(dx.writers, b, noids), get(writers, b, noids)))
    mutators_of(b) = Iterators.flatten((get(dx.mutators, b, noids), get(mutators, b, noids)))
    assumers_of(b) = Iterators.flatten((Iterators.flatten(values(get(dx.assumed, b, IdDict{Any,Set{Int}}()))),
                                        get(assumers, b, noids)))
    function enqueue!(ids)
        for id in ids
            s = dx.stmts[id]
            isnothing(s) || PkgId(s.pkgdata) in affected && push!(queue, id)
        end
    end
    enqueue_key!(key) = enqueue!(id for id in get(dx.bykey, stmt_key(key[2], key[3]), ()) if stmt(id).file == key[1])
    function depsof(id)
        haskey(deps, id) && return deps[id]
        s = stmt(id)
        key = stmt_key(s.mod, s.rex)
        d, changedcode = current_deps(key, dirty, world)
        changedcode && push!(codechanged, id)
        if !isnothing(d) && d.readsall && d.dynamic && (isnothing(d.evaluated) || !d.evaluated.readsall) &&
                d === get(global_deps_cache, key, nothing) && modeof(id) !== :sigs
            d = observe_reads!(key, d)
        end
        deps[id] = d
        if isnothing(d)
            push!(nodeps, id)
            return d
        end
        delete!(nodeps, id)
        if d !== s.deps
            foreach(b -> add_id!(readers, b, id), d.reads)
            foreach(b -> add_id!(writers, b, id), d.writes)
            foreach(b -> add_id!(mutators, b, id), d.mutates)
            d.readsall && push!(readsall, id)
        end
        # The cached entry tells which bindings in `dirty` make `current_deps` analyze anew
        cached = get(global_deps_cache, key, nothing)
        isnothing(cached) || cached === s.deps || foreach(((b, _),) -> add_id!(assumers, b, id), cached.assumed)
        return d
    end
    function posof(s::IndexedStmt)
        if isempty(loadorder)
            for (i, (id, _)) in enumerate(pkgs_in_load_order())
                loadorder[id] = i
            end
        end
        ifile = findfirst(i -> fileinfo(s.pkgdata, i).mod_exs_infos === s.fi.mod_exs_infos, eachindex(srcfiles(s.pkgdata)))
        positions = get!(rexpos, s.fi.mod_exs_infos) do
            IdDict{RelocatableExpr,Int}(rex => k for (k, (_, rex)) in enumerate(stmts_in_source_order(s.fi.mod_exs_infos)))
        end
        return (get(loadorder, PkgId(s.pkgdata), 0), something(ifile, 0), positions[s.rex])
    end
    function note_mutated!(bindings)
        for b in bindings
            b in decided && continue
            push!(pending, b)
            push!(dirtypkgs, PkgId(Base.moduleroot(b[1])))
        end
    end
    function seed!()
        for b in dirty
            enqueue!(readers_of(b))
            enqueue!(assumers_of(b))
        end
        foreach(b -> enqueue!(readers_of(b)), selwrites)
        foreach(b -> enqueue!(writers_of(b)), replay)
        if !(isempty(dirty) && isempty(selwrites))
            enqueue!(dx.readsall)
            enqueue!(readsall)
        end
        for (c, ids) in dx.checks
            invalid_since(c) == typemax(UInt) || enqueue!(ids)
        end
        enqueue!((@invokelatest changed_assumptions(dx.assumed))::Vector{Int})
        foreach(enqueue_key!, collect(done))
        foreach(enqueue_key!, collect(keys(failed_dependents)))
        enqueue!(nodeps)
        enqueue!(dx.nodeps)
        return nothing
    end
    function check!(id)
        d = depsof(id)
        id in isselected && return nothing
        key = keyof(id)
        if key in done
            key in evaluated && !isnothing(d) && (reads_any(d, selwrites) || ran_before_change(key, d)) || return nothing
            delete!(done, key)
        end
        mode = modeof(id)
        mode === :sigs && return nothing
        if isnothing(d)
            push!(done, key)   # no entry, not checked again
            return nothing
        end
        reads_any(d, dirty) || !isdisjoint(d.writes, replay) || id in codechanged || haskey(failed_dependents, key) || return nothing
        push!(isselected, id)
        push!(done, key)
        s = stmt(id)
        push!(selected, DependentStmt(s.pkgdata, s.file, s.fi, s.mod, s.exs_infos, s.rex, mode, posof(s), d))
        for b in d.writes
            if !(b in selwrites)
                push!(selwrites, b)
                enqueue!(readers_of(b))
                length(selwrites) == 1 && (enqueue!(dx.readsall); enqueue!(readsall))
            end
            if !(b in dirty)
                push!(dirty, b)
                enqueue!(readers_of(b))
                length(dirty) == 1 && (enqueue!(dx.readsall); enqueue!(readsall))
                for j in collect(assumers_of(b))
                    delete!(deps, j)
                    enqueue!((j,))
                end
            end
        end
        push!(dirtypkgs, PkgId(s.pkgdata))
        mode === :eval && note_mutated!(d.mutates)
        return nothing
    end
    note_mutated!(mutated)
    npkgs = -1
    while true
        if length(dirtypkgs) != npkgs
            npkgs = length(dirtypkgs)
            union!(empty!(affected), affected_tracked(dirtypkgs))
            refresh_index!(dx, affected)
            verify_dep_index[] && !check_dep_index(dx) && error("`Revise.dep_index` does not match `Revise.global_deps_cache`")
            foreach(id -> delete!(deps, id), nodeps)   # may have an entry now
            seed!()
        elseif !isempty(queue)
            check!(pop!(queue))
        elseif !isempty(pending)
            # Every statement a change can affect is checked, so the indices are current.
            analyzed = isempty(nodeps) && !any(id -> PkgId(stmt(id).pkgdata) in affected, dx.nodeps)
            batch = collect(pending)
            empty!(pending)
            for b in batch
                push!(decided, b)
                if replayable(b, modeof, id -> stmt(id).rex.ex, depsof, writers_of, mutators_of, analyzed)
                    push!(replay, b)
                    enqueue!(collect(writers_of(b)))
                end
                note_mutated!(aliased_reads(b, depsof, writers_of, dirty))
            end
        else
            return selected
        end
    end
end

# The globals whose value may share mutable memory with `b`, because a statement that assigns
# `b` reads them, as in `b = a`, or read them in its last run (see `former_reads`). The value of
# a non-`const` global, or of one in `dirty`, may change before that statement runs, so any such
# global counts. `writers_of` returns the statements that may assign a binding, and `depsof`
# returns their dependencies.
function aliased_reads(b::Tuple{Module,Symbol}, depsof, writers_of, dirty)
    aliases = Tuple{Module,Symbol}[]
    for i in collect(writers_of(b))
        deps = depsof(i)
        (isnothing(deps) || !(b in deps.writes)) && continue
        for r in deps.reads
            (r in dirty || value_may_hold_mutable(r)) && push!(aliases, r)
        end
    end
    for r in get(former_reads, b, ())
        (r in dirty || value_may_hold_mutable(r)) && push!(aliases, r)
    end
    return aliases
end

# Whether the statements that assign the mutated binding `b` can be replayed: every tracked
# statement was `analyzed`, at least one assigns `b`, every statement that assigns or mutates
# `b` is evaluated under `:eval`, and the `__init__` of the module owning `b` neither mentions
# it nor, as far as its summary shows, reads or mutates it. `writers_of` and `mutators_of`
# return the statements that may assign or mutate a binding, `depsof` their dependencies,
# `modeof` their revise mode, and `exof` their expression.
function replayable(b::Tuple{Module,Symbol}, modeof, exof, depsof, writers_of, mutators_of, analyzed::Bool)
    analyzed || return false
    m, s = b
    init = (m, :__init__)
    name = Set([s])
    for i in collect(writers_of(init))
        deps = depsof(i)
        !isnothing(deps) && init in deps.writes && mentions_any(exof(i), name) && return false
    end
    nwriters = 0
    for i in collect(writers_of(b))
        deps = depsof(i)
        (isnothing(deps) || !(b in deps.writes)) && continue
        modeof(i) === :eval || return false
        nwriters += 1
    end
    for i in collect(mutators_of(b))
        deps = depsof(i)
        (isnothing(deps) || !(b in deps.mutates)) && continue
        modeof(i) === :eval || return false
    end
    return nwriters > 0 && !init_uses(b)
end

function init_uses(b::Tuple{Module,Symbol})
    m = b[1]
    @invokelatest(isdefinedglobal(m, :__init__)) || return false
    f = @invokelatest getglobal(m, :__init__)
    walk = Walk()
    info = call_info(Tuple{Core.Typeof(f)}, walk.world)
    info === nothing && return false
    id = global_id(b...)
    for mi in info.mis
        s = summarize(mi, walk)
        (insorted(id, s.reads) || insorted(id, s.mutated.globals)) && return true
    end
    return false
end

"""
    Revise.rank_by_inclusion!(selected::Vector{DependentStmt}) -> selected

Set the `pos` of each statement in `selected` to its place in the order loading runs its package's statements.

The second entry of `pos`, the index of the statement's file, is replaced by that place. The
statements of a file follow the statement that `include`s it.

# Examples

```jldoctest; setup = :(using Revise)
julia> dir = mktempdir(); src = mkpath(joinpath(dir, "RankDoc", "src")); push!(LOAD_PATH, dir);

julia> write(joinpath(src, "RankDoc.jl"), "__precompile__(false)\\nmodule RankDoc\\nconst A = 1\\ninclude(\\\"a.jl\\\")\\nmodule Sub\\nconst S = 0\\nend\\nconst B = 2\\nend\\n");

julia> write(joinpath(src, "a.jl"), "const C = 3\\n"); using RankDoc; pop!(LOAD_PATH);

julia> pd = Revise.pkgdatas[Base.PkgId(RankDoc)]; sites = Revise.StmtSite[];

julia> foreach(i -> Revise.add_file_sites!(sites, 1, pd, i), eachindex(Revise.srcfiles(pd)));

julia> selected = [Revise.DependentStmt(s..., Revise.GlobalDeps()) for s in sites];

julia> stmts(v) = [string(d.rex.ex.args[end]) for d in sort(v; by = d -> d.pos)][3:end];

julia> stmts(selected)
4-element Vector{String}:
 "include(\\\"a.jl\\\")"
 "const S = 0"
 "const B = 2"
 "const C = 3"

julia> stmts(Revise.rank_by_inclusion!(selected))
4-element Vector{String}:
 "include(\\\"a.jl\\\")"
 "const C = 3"
 "const S = 0"
 "const B = 2"
```
"""
function rank_by_inclusion!(selected::Vector{DependentStmt})
    ranks = Dict{Tuple{String,Module,RelocatableExpr},Int}()
    for pkgdata in IdSet{PkgData}(d.pkgdata for d in selected)
        sites = StmtSite[]
        for ifile in eachindex(srcfiles(pkgdata))
            add_file_sites!(sites, 0, pkgdata, ifile)
        end
        for site in order_by_inclusion!(sites, 1, pkgdata)
            ranks[(site[2], site[4], site[6])] = site[8][2]
        end
    end
    for (i, d) in enumerate(selected)
        (ipkg, ifile, istmt) = d.pos
        rank = get(ranks, (d.file, d.mod, d.rex), ifile)
        selected[i] = DependentStmt(d.pkgdata, d.file, d.fi, d.mod, d.exs_infos, d.rex, d.mode,
                                    (ipkg, rank, istmt), d.deps)
    end
    return selected
end

# Number the statements `sites[first:end]` of `pkgdata` in the order loading runs them: the
# statements of a file, which `add_file_sites!` lists in source order, follow the statement that
# includes it. Files that no statement is known to include follow in file order.
function order_by_inclusion!(sites::Vector{StmtSite}, first::Int, pkgdata::PkgData)
    byfile = Dict{Int,Vector{Int}}()
    for k in first:length(sites)
        push!(get!(Vector{Int}, byfile, sites[k][8][2]), k)
    end
    visited = falses(length(srcfiles(pkgdata)))
    rank = 0
    for ifile in eachindex(visited)
        visited[ifile] || (rank = rank_file!(sites, byfile, visited, pkgdata, ifile, rank))
    end
    return sites
end

# Rank the statements of file `ifile` from `rank + 1` on, each followed by the files it includes,
# and return the last rank given.
function rank_file!(sites::Vector{StmtSite}, byfile::Dict{Int,Vector{Int}}, visited::BitVector,
                    pkgdata::PkgData, ifile::Int, rank::Int)
    visited[ifile] = true
    for k in get(byfile, ifile, ())
        (_, file, fi, mod, exs_infos, rex, mode, (ipkg, _, istmt)) = sites[k]
        rank += 1
        sites[k] = (pkgdata, file, fi, mod, exs_infos, rex, mode, (ipkg, rank, istmt))
        for (path, m) in stmt_include_targets!(Tuple{String,Module}[], pkgdata, file, mod, rex, fi.includes)
            for j in fileindices(pkgdata, path)
                visited[j] || includemodule(pkgdata, j) !== m ||
                    (rank = rank_file!(sites, byfile, visited, pkgdata, j, rank))
            end
        end
    end
    return rank
end

# The tracked packages in the order Revise started tracking them, so a package follows those
# it loads. Code not loaded as a package, such as `Main`, comes last.
function pkgs_in_load_order()
    last = (NOPACKAGE, PkgId(Main))
    return sort!(collect(pkgdatas); by = p -> p.first in last)
end

"""
    Revise.affected_tracked(dirtypkgs::Set{PkgId}) -> Set{PkgId}

Return the tracked packages whose statements the statements of `dirtypkgs` may affect.

These are the packages of `dirtypkgs`, the packages that require one of them, transitively, and
code whose requirements are not known, such as `Main`. Statements of `Base` and the compiler are
never reevaluated as dependents, since that can replace code the session itself runs on.

# Examples

```jldoctest; setup = :(using Revise)
julia> dir = mktempdir(); src = mkpath(joinpath(dir, "AffectedDoc", "src")); push!(LOAD_PATH, dir);

julia> write(joinpath(src, "AffectedDoc.jl"), "__precompile__(false)\\nmodule AffectedDoc\\nconst A = 1\\nend\\n");

julia> using AffectedDoc; pop!(LOAD_PATH); id = Base.PkgId(AffectedDoc);

julia> id in Revise.affected_tracked(Set([id])), isempty(Revise.affected_tracked(Set{Base.PkgId}()))
(true, true)

julia> Base.PkgId(Base) in Revise.affected_tracked(Set([Base.PkgId(Base)]))
false
```
"""
function affected_tracked(dirtypkgs::Set{PkgId})
    pkgs = Set{PkgId}()
    for id in affected_pkgs(dirtypkgs)
        haskey(pkgdatas, id) && !is_base_pkg(id) && push!(pkgs, id)
    end
    return pkgs
end

function affected_pkgs(dirtypkgs::Set{PkgId})
    isempty(dirtypkgs) && return Set{PkgId}()
    # Every package uses `Base`, which requirements do not list.
    any(is_base_pkg, dirtypkgs) && return union(dirtypkgs, keys(pkgdatas))
    affected = copy(dirtypkgs)
    # Packages of Julia itself require only each other.
    skipped = any(is_julia_pkg, dirtypkgs) ? Set{PkgId}() : Set{PkgId}(id for id in keys(pkgdatas) if is_julia_pkg(id))
    grown = true
    while grown
        grown = false
        for (id, pkgdata) in pkgdatas
            (id in affected || id in skipped) && continue
            # Only a cache file records requirements, and those of every package include `Core`.
            known = id.uuid !== nothing && use_compiled_modules() && !isempty(pkgdata.requirements)
            # Requirements also list `Main`, `Core`, and `Base`, which have no UUID: no package can
            # depend on `Main`, `Core` is not tracked, and a revised `Base` affects every package.
            known && !any(r -> r.uuid !== nothing && r in affected, pkgdata.requirements) && continue
            push!(affected, id)
            grown = true
        end
    end
    return affected
end

# Add the statements of file `ifile` of `pkgdata`, the `ipkg`-th package, to `sites` in source
# order, parsing the file if it is not parsed yet. A file whose cached source is stale is skipped.
function add_file_sites!(sites::Vector{StmtSite}, ipkg::Int, pkgdata::PkgData, ifile::Int)
    file = srcfiles(pkgdata)[ifile]
    fi = fileinfo(pkgdata, ifile)
    if is_not_populated(fi)
        try
            maybe_parse_from_cache!(pkgdata, file, fi)
        catch err
            isa(err, StaleCacheError) || rethrow()
            return sites
        end
    end
    defaultmode = default_revise_mode(pkgdata)
    modes = IdDict{Module,Symbol}()
    for (istmt, (mod, rex)) in enumerate(stmts_in_source_order(fi.mod_exs_infos))
        mode = get!(() -> revise_mode(mod, defaultmode), modes, mod)
        push!(sites, (pkgdata, file, fi, mod, fi.mod_exs_infos[mod], rex, mode, (ipkg, ifile, istmt)))
    end
    return sites
end

# --- Analysis ahead of the first revision

# The task analyzing ahead, and whether it runs once more. Guarded by `revise_lock`.
const ahead_task = Ref{Union{Nothing,Task}}(nothing)
const ahead_again = Ref(false)
# Seconds the analysis waits, so that all packages that one `using` loads are tracked first.
const ahead_delay = 2.0
# Statements analyzed per acquisition of `revise_lock`. A revision waits for at most one chunk.
const ahead_chunk = 25

# The REPL must run on a thread of its own, so that the analysis does not delay it.
ahead_enabled() = prepare_ahead[] && revise_dependents[] && dependents_supported && isinteractive() &&
                  Threads.nthreads(:interactive) > 0

"""
    Revise.request_analysis_ahead()

Start [`Revise.analyze_ahead`](@ref) on a task of the default thread pool, unless it already
runs, in which case it runs once more when done, and [`Revise.idle_work`](@ref) after it.

The analysis ahead needs [`Revise.prepare_ahead`](@ref) and [`Revise.revise_dependents`](@ref)
on and a REPL on an interactive thread. Otherwise only the idle work is requested. Revise calls
this when it starts tracking code and after each revision.

# Examples

```jldoctest; setup = :(using Revise)
julia> Revise.ahead_enabled()   # doctests do not run interactively
false

julia> Revise.request_analysis_ahead(); Revise.ahead_task[] === nothing
true
```
"""
function request_analysis_ahead()
    prepare_ahead[] || return nothing
    ahead_enabled() || return request_idle_work()
    @lock revise_lock begin
        if ahead_task[] === nothing
            ahead_task[] = Threads.@spawn :default begin
                sleep(ahead_delay)
                frozen(run_analysis_ahead)
            end
        else
            ahead_again[] = true
        end
    end
    return nothing
end

function run_analysis_ahead()
    while true
        try
            analyze_ahead()
        catch err
            log_caught(err, catch_backtrace(), "AnalyzeAheadFailed")
        end
        @lock revise_lock begin
            if !ahead_again[]
                ahead_task[] = nothing
                break
            end
            ahead_again[] = false
        end
    end
    request_idle_work()
    return nothing
end

"""
    Revise.analyze_ahead()

Store [`Revise.global_deps`](@ref) of the statements that a first revision with
[`Revise.revise_dependents`](@ref) analyzes, in `global_deps_cache`.

These are the statements of the watched packages other than the standard libraries, and of the
packages these affect (see [`Revise.affected_tracked`](@ref)). Statements are analyzed in chunks
under `revise_lock`, so a revision waits for at most one chunk. Statements
whose expansion calls a macro of a package (see [`Revise.expands_package_macro`](@ref)) are
left to [`Revise.idle_work`](@ref), since this analysis runs while other code runs.

# Examples

```jldoctest; setup = :(using Revise)
julia> fn = joinpath(mktempdir(), "ahead.jl"); write(fn, "const AHEAD_A = 1\\nconst AHEAD_B = [AHEAD_A]\\n");

julia> includet(fn); isahead(k) = k[2] === Main && occursin("AHEAD_B", string(k[3].ex));

julia> count(isahead, keys(Revise.global_deps_cache))
0

julia> Revise.analyze_ahead(); count(isahead, keys(Revise.global_deps_cache))
1
```
"""
function analyze_ahead(files::Vector{Tuple{PkgData,Int}}=ahead_files())
    for (pkgdata, ifile) in files
        stmts = @lock revise_lock filter!(s -> !expands_package_macro(s[2], s[3].ex), file_statements(pkgdata, ifile))
        for chunk in Iterators.partition(stmts, ahead_chunk)
            @lock revise_lock cache_global_deps!(collect(chunk))
        end
    end
    return nothing
end

# The files whose statements a first revision analyzes, as `(pkgdata, index)`: see `analyze_ahead`.
# Without `dependents`, those of the watched packages, whose signatures a revision extracts.
function ahead_files(dependents::Bool=revise_dependents[] && dependents_supported)
    @lock revise_lock begin
        watched = Set{PkgId}(id for (id, pkgdata) in pkgdatas if !Base.is_stdlib(id) && is_watched(pkgdata))
        affected = dependents ? affected_pkgs(watched) : watched
        return Tuple{PkgData,Int}[(pkgdata, ifile) for (id, pkgdata) in pkgdatas if id in affected && !is_base_pkg(id)
                                  for ifile in eachindex(srcfiles(pkgdata))]
    end
end

# --- Idle work: preparing revisions while the REPL waits for input, including what the analysis
# ahead leaves because it runs code of packages.

"""
    Revise.IdleCancelled()

The exception that stops a run of package code in the idle worker once a REPL command starts.

See [`Revise.idle_work`](@ref).
"""
struct IdleCancelled <: Exception end

const idle_task = Ref{Union{Nothing,Task}}(nothing)
const idle_again = Ref(false)
# Held during one unit of idle work. A REPL command takes it before it runs (see `pause_idle_work`).
const idle_lock = ReentrantLock()
const idle_cancel = Threads.Atomic{Bool}(false)
# Seconds between two checks whether the REPL still runs a command
const idle_poll = 0.1

# The REPL backend whose task takes the commands from `repl_channel` and runs `revise_first`
# before each, or `nothing`. Without that hook a command would not wait for the unit in progress.
function idle_backend()
    active_repl_backend_available() || return nothing
    backend = Base.active_repl_backend
    T = typeof(backend)
    hasfield(T, :repl_channel) && isa(backend.repl_channel, Channel) || return nothing
    hasfield(T, :ast_transforms) && any(f -> f === revise_first, backend.ast_transforms) || return nothing
    return backend
end

# Whether the task of the REPL `backend` waits for the next command. Unlike `backend.in_eval`,
# which stays set after a command that threw, this also holds after an error.
repl_waiting(@nospecialize(backend)) = !isempty(backend.repl_channel.cond_take.waitq)

# Start `idle_work` on a task of the default thread pool if `prepare_ahead` is on and a REPL runs,
# or run it once more if it already runs.
function request_idle_work()
    prepare_ahead[] || return nothing
    backend = idle_backend()
    isnothing(backend) && return nothing
    @lock revise_lock begin
        if idle_task[] === nothing
            idle_task[] = Threads.@spawn :default frozen(run_idle_work, () -> !idle_suspended[] && repl_waiting(backend))
        else
            idle_again[] = true
        end
    end
    return nothing
end

function run_idle_work(@nospecialize(isidle))
    while true
        try
            idle_work(isidle)
        catch err
            log_caught(err, catch_backtrace(), "IdleWorkFailed")
        end
        @lock revise_lock begin
            if !idle_again[]
                idle_task[] = nothing
                return nothing
            end
            idle_again[] = false
        end
    end
end

"""
    Revise.idle_work(isidle, files=Revise.ahead_files())

Prepare revisions of `files` while `isidle()` returns `true` (see [`Revise.prepare_ahead`](@ref)).

With [`Revise.revise_dependents`](@ref), the statements that the analysis ahead left are
analyzed first. Then the signatures are extracted (see [`Revise.idle_extract_sigs!`](@ref)).
Last, with `revise_dependents`, the statements that may still read any global run in `:sigs`
mode to observe which they read (see [`Revise.observed_reads`](@ref)).

Each file parse and each statement is a unit, which starts only while `isidle()` returns `true`.
A REPL command cancels a run in `:sigs` mode (see [`Revise.IdleCancelled`](@ref)) and otherwise
waits for the unit in progress.

# Examples

```jldoctest; setup = :(using Revise)
julia> fn = joinpath(mktempdir(), "idle.jl");

julia> write(fn, "module IdleDoc\\nmacro two() 2 end\\nconst IDLE_C = @two\\nend\\n"); includet(fn);

julia> pkgdata = Revise.pkgdatas[Base.PkgId(Main)]; files = [(pkgdata, length(Revise.srcfiles(pkgdata)))];

julia> isidle(k) = nameof(k[2]) === :IdleDoc && occursin("IDLE_C", string(k[3].ex));

julia> Revise.analyze_ahead(files); count(isidle, keys(Revise.global_deps_cache))
0

julia> Revise.prepare_ahead[] = Revise.revise_dependents[] = true; Revise.idle_work(() -> true, files);

julia> Revise.prepare_ahead[] = Revise.revise_dependents[] = false; count(isidle, keys(Revise.global_deps_cache))
1
```
"""
function idle_work(@nospecialize(isidle), files::Vector{Tuple{PkgData,Int}}=ahead_files())
    dependents() = revise_dependents[] && dependents_supported
    for (pkgdata, ifile) in files
        idle_unit(isidle) do
            @lock revise_lock begin
                ifile <= length(pkgdata.fileinfos) && is_not_populated(fileinfo(pkgdata, ifile)) &&
                    try_parse_from_cache!(pkgdata, srcfiles(pkgdata)[ifile])
            end
        end || return nothing
    end
    if dependents()
        for (pkgdata, ifile) in files
            stmts = @lock revise_lock filter!(s -> !haskey(global_deps_cache, s), file_statements(pkgdata, ifile))
            for key in stmts
                idle_unit(() -> @lock(revise_lock, cache_global_deps!([key])), isidle) || return nothing
            end
        end
    end
    # Extracting a statement's signatures also observes what it reads, so few runs remain below.
    for (pkgdata, ifile) in files
        idle_extract_sigs!(pkgdata, ifile, isidle) || return nothing
    end
    dependents() || return nothing
    for (pkgdata, ifile) in files
        stmts = @lock revise_lock file_statements(pkgdata, ifile)
        for key in stmts
            observe = @lock revise_lock begin
                d = get(global_deps_cache, key, nothing)
                !isnothing(d) && d.readsall && d.dynamic && (isnothing(d.evaluated) || !d.evaluated.readsall) &&
                    revise_mode(key[2], default_revise_mode(pkgdata)) !== :sigs
            end
            observe || continue
            idle_unit(isidle) do
                @lock revise_lock begin
                    d = get(global_deps_cache, key, nothing)
                    isnothing(d) || !d.dynamic || observe_reads!(key, d)
                end
            end || return nothing
        end
    end
    return nothing
end

"""
    Revise.idle_extract_sigs!(pkgdata, ifile, isidle) -> Bool

Extract the signatures of file `ifile` of `pkgdata`, one statement per unit of [`Revise.idle_work`](@ref), as a revision does when it first needs them.

Statements extracted before, also by a cancelled unit, are skipped. A file that a revision
replaced meanwhile is left alone, and so is one that fails, which the revision that needs it
reports. Return `false` if
[`Revise.prepare_ahead`](@ref) was turned off.

# Examples

```jldoctest; setup = :(using Revise)
julia> fn = joinpath(mktempdir(), "sigs.jl"); write(fn, "module SigsIdleDoc\\nf(x) = x\\nend\\n"); includet(fn);

julia> pkgdata = Revise.pkgdatas[Base.PkgId(Main)]; ifile = length(Revise.srcfiles(pkgdata));

julia> Revise.prepare_ahead[] = true; Revise.idle_extract_sigs!(pkgdata, ifile, () -> true); Revise.prepare_ahead[] = false;

julia> Revise.fileinfo(pkgdata, ifile).extracted[]
true
```
"""
function idle_extract_sigs!(pkgdata::PkgData, ifile::Int, @nospecialize(isidle))
    current(fi) = any(f -> f === fi, pkgdata.fileinfos)
    fi = @lock revise_lock begin
        ifile <= length(pkgdata.fileinfos) || return true
        info = fileinfo(pkgdata, ifile)
        info.extracted[] && return true
        try_parse_from_cache!(pkgdata, srcfiles(pkgdata)[ifile]) === nothing && return true
        info
    end
    todo = @lock revise_lock [(mod, exs_infos, rex) for (mod, exs_infos) in fi.mod_exs_infos for rex in keys(exs_infos)
                              if exs_infos[rex] === nothing && !is_doc_expr(rex.ex)]
    try
        for (mod, exs_infos, rex) in todo
            idle_unit(isidle) do
                @lock revise_lock begin
                    current(fi) && !fi.extracted[] && exs_infos[rex] === nothing &&
                        instantiate_sig!(exs_infos, mod, rex; records=fi.includes)
                end
            end || return false
        end
    catch err
        isa(err, InterruptException) && rethrow()
        log_caught(err, catch_backtrace(), "IdleExtractSigsFailed"; file=srcfiles(pkgdata)[ifile])
        return true
    end
    @lock revise_lock current(fi) && (fi.extracted[] = true)
    return true
end

# Run `f` once `isidle()` holds; return `false` if `prepare_ahead` was turned off. What `f`
# logs goes to Revise's debug log: the user did not ask for this work.
function idle_unit(f, @nospecialize(isidle))
    while prepare_ahead[]
        if isidle()
            ran = @lock idle_lock begin
                !isidle() ? false : try
                    with_logger(f, _debug_logger)
                    true
                catch err
                    isa(err, IdleCancelled) || rethrow()
                    false
                end
            end
            ran && return true
        end
        sleep(idle_poll)
    end
    return false
end

# Called before each REPL command runs: cancel a run of `idle_work` in `:sigs` mode and wait
# until the unit in progress ended. The REPL no longer waits for input, so no next unit starts.
function pause_idle_work()
    isnothing(idle_task[]) && return nothing
    idle_cancel[] = true
    @lock idle_lock nothing
    idle_cancel[] = false
    return nothing
end

# Throw `IdleCancelled` if a REPL command waits for the idle worker running this.
check_idle_cancel() = idle_cancel[] && current_task() === idle_task[] && throw(IdleCancelled())

# Set by a `revise()` while the REPL waits for input, as an editor's inline evaluation calls it
# before running user code. Cleared when a REPL command starts.
const idle_suspended = Threads.Atomic{Bool}(false)

# During a REPL command the hook has already paused the idle work, which resumes after the command.
function suspend_idle_work(backend=idle_backend())
    !isnothing(backend) && repl_waiting(backend) || return nothing
    idle_suspended[] = true
    pause_idle_work()
    return nothing
end

"""
    Revise.expands_package_macro(mod::Module, ex) -> Bool

Return whether the expansion of the statement `ex` of `mod` calls a macro that neither `Core` nor a package of Julia itself defines.

A macro whose binding is not found counts as well. Macros in the method bodies that
[`Revise.strip_bodies`](@ref) removes, and in quoted code, are not expanded, so they do not count.

# Examples

```jldoctest; setup = :(using Revise)
julia> module MacroDoc
           macro m(x) x end
       end;

julia> Revise.expands_package_macro(Main, :(const C = MacroDoc.@m 1))
true

julia> Revise.expands_package_macro(Main, :(f(x) = MacroDoc.@m x))
false
```
"""
expands_package_macro(mod::Module, @nospecialize(ex)) = calls_package_macro(mod, strip_bodies(ex))

# Whether the expression `x` of `mod` calls a macro that neither `Core` nor a package of Julia
# defines, also in method bodies but not in quoted code. `@doc` counts if a package replaced the
# function that `Core.@doc` calls (see `Core.atdoc!`).
function calls_package_macro(mod::Module, @nospecialize(x))
    isa(x, Expr) || return false
    (x.head === :quote || x.head === :inert) && return false
    if x.head === :macrocall
        m = macro_module(mod, x.args[1])
        isnothing(m) && return true
        root = Base.moduleroot(m)
        root === Core || is_julia_pkg(PkgId(root)) || return true
        root === Core && macro_name(x.args[1]) === Symbol("@doc") && !julia_doc_function() && return true
    end
    return any(a -> calls_package_macro(mod, a), x.args)
end

macro_name(@nospecialize(name)) = isa(name, GlobalRef) ? name.name :
    isexpr(name, :., 2) && isa(name.args[2], QuoteNode) ? name.args[2].value : name

# Whether `Core.@doc` calls a function of Julia itself, not one a package installed.
function julia_doc_function()
    root = Base.moduleroot(parentmodule(getglobal(Core, :atdoc)))
    return root === Core || is_julia_pkg(PkgId(root))
end

# The module that owns the macro `name` of a macro call in `mod`, or `nothing` if not known.
function macro_module(mod::Module, @nospecialize(name))
    isa(name, GlobalRef) && return name.mod
    isa(name, Symbol) && return binding_owner(mod, name)
    if isexpr(name, :., 2) && isa(name.args[2], QuoteNode) && isa(name.args[2].value, Symbol)
        q = qualifier_module(mod, name.args[1])
        return isnothing(q) ? nothing : binding_owner(q, name.args[2].value)
    end
    return nothing
end

# The statements of file `ifile` of `pkgdata`, or none if `pkgdata` is no longer tracked.
function file_statements(pkgdata::PkgData, ifile::Int)
    stmts = StmtKey[]
    get(pkgdatas, PkgId(pkgdata), nothing) === pkgdata && ifile <= length(srcfiles(pkgdata)) || return stmts
    for site in add_file_sites!(StmtSite[], 0, pkgdata, ifile)
        push!(stmts, stmt_key(site[4], site[6]))
    end
    return stmts
end

# Whether Revise watches a file of `pkgdata`, so that a revision can start there.
function is_watched(pkgdata::PkgData)
    return any(srcfiles(pkgdata)) do file
        dir, base = splitdir(String(file))
        wl = get(watched_files, joinpath(basedir(pkgdata), dir), nothing)
        return wl !== nothing && haskey(wl.trackedfiles, base)
    end
end

# Whether `id` identifies `Base`, the compiler, or a standard library. Such a package requires
# only other packages of Julia itself.
is_julia_pkg(id::PkgId) = @lock julia_pkg_lock get!(() -> Base.is_stdlib(id) || is_base_pkg(id), julia_pkg_memo, id)
# `Base.is_stdlib` reads the file system, so the answers are kept.
const julia_pkg_memo = Dict{PkgId,Bool}()
const julia_pkg_lock = ReentrantLock()

# Whether `id` identifies `Base` or the compiler, which Revise tracks only after `Revise.track`.
is_base_pkg(id::PkgId) = isnothing(id.uuid) && id.name in ("Base", "Core.Compiler")

# Order `selected`, which is sorted by position, so that each statement follows the selected
# statements whose writes it reads. A statement that reads a binding without mutating it keeps
# its position relative to the statements that mutate the binding. Among independent
# statements, and within a cycle, the order of `selected` is kept.
function order_dependents(selected::Vector{DependentStmt})
    n = length(selected)
    readers = Dict{Tuple{Module,Symbol},Vector{Int}}()
    readsall = Int[]
    for (i, d) in enumerate(selected)
        if d.deps.readsall
            push!(readsall, i)
        else
            foreach(b -> push!(get!(Vector{Int}, readers, b), i), d.deps.reads)
        end
    end
    # `succs[j]` lists the statements that must follow `j`, `npreds[i]` how many unplaced
    # statements `i` waits for.
    succs = [Int[] for _ in 1:n]
    npreds = zeros(Int, n)
    seen = zeros(Int, n)   # `seen[i] == j` once the edge from `j` to `i` is recorded
    function edge!(j, i)
        seen[i] == j && return nothing
        seen[i] = j
        push!(succs[j], i)
        npreds[i] += 1
        return nothing
    end
    nobody = Int[]
    for (j, d) in enumerate(selected)
        isempty(d.deps.writes) && isempty(d.deps.mutates) && continue
        seen[j] = j
        for b in d.deps.writes, i in get(readers, b, nobody)
            edge!(j, i)
        end
        for b in d.deps.mutates, i in get(readers, b, nobody)
            b in selected[i].deps.mutates && continue
            if j < i
                edge!(j, i)
            else   # `seen` tracks the edges from `j` only
                push!(succs[i], j)
                npreds[j] += 1
            end
        end
        foreach(i -> edge!(j, i), readsall)
    end
    unplaced = BitSet(1:n)
    ready = BitSet(i for i in 1:n if npreds[i] == 0)
    ordered = DependentStmt[]
    while !isempty(unplaced)
        i = first(isempty(ready) ? unplaced : ready)
        delete!(ready, i)
        delete!(unplaced, i)
        push!(ordered, selected[i])
        for k in succs[i]
            npreds[k] -= 1
            npreds[k] == 0 && k in unplaced && push!(ready, k)
        end
    end
    return ordered
end

# Delete the methods with the signatures in `old` that are not in `new`, so a statement whose
# signatures changed when it was reevaluated leaves none of its old methods behind. A method
# whose signature did not change was replaced, so it is never missing.
function delete_stale_methods!(old, new)
    old === nothing && return nothing
    keep = Set{MethodInfoKey}(MethodInfoKey(e) for e in something(new, ()) if isa(e, SigInfo))
    world = Base.get_world_counter()
    for exinfo in old
        isa(exinfo, SigInfo) && !(MethodInfoKey(exinfo) in keep) || continue
        mt, sig = exinfo
        ret = Base._methods_by_ftype(sig, mt, -1, world)
        isempty(ret) && continue
        m = ret[end].method
        sig <: m.sig && m.sig <: sig || continue
        @debug "ReevalDeleteMethod" _group="Action" time=time() deltainfo=(sig, MethodSummary(m))
        Base.delete_method(m)
    end
    return nothing
end
