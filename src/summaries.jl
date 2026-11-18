# Summaries: what a called method may do to memory that existed before the call. They let the
# analysis of a top-level statement see mutations and reads inside the functions it calls.

# Positive ids number owner-resolved bindings, negative ones `NamedAccess`es.
const GlobalId = Int32

# The global that a module and a name select, as in `getglobal(m, s)`, when one of them is not
# known. Each is the value if known, the position of the method's parameter that holds it, or
# `nothing` if unknown.
struct NamedAccess
    mod::Union{Nothing,Module,Int}
    name::Union{Nothing,Symbol,Int}
end

# Owner-resolved global bindings and named accesses, numbered so that sets of them are small
# sorted vectors.
struct GlobalTable
    bindings::Vector{Tuple{Module,Symbol}}
    ids::Dict{Tuple{Module,Symbol},GlobalId}
    raw::Dict{Tuple{Module,Symbol},GlobalId}   # by the module of the reference, valid in `raw_world`
    raw_world::Base.RefValue{UInt}
    named::Vector{NamedAccess}
    namedids::Dict{NamedAccess,GlobalId}
end

const global_table = GlobalTable(Tuple{Module,Symbol}[], Dict{Tuple{Module,Symbol},GlobalId}(),
                                 Dict{Tuple{Module,Symbol},GlobalId}(), Ref(typemax(UInt)),
                                 NamedAccess[], Dict{NamedAccess,GlobalId}())
# Guards `global_table` and `summary_cache`.
const summary_lock = ReentrantLock()

# The number of the binding `m.s` refers to, keyed by the module that owns it.
function global_id(m::Module, s::Symbol)
    world = Base.get_world_counter()
    @lock summary_lock begin
        if world != global_table.raw_world[]
            empty!(global_table.raw)   # binding owners may differ in the new world
            global_table.raw_world[] = world
        end
        id = get(global_table.raw, (m, s), GlobalId(0))
        id == 0 || return id
        b = (lookup_owner(m, s), s)
        id = get!(global_table.ids, b) do
            push!(global_table.bindings, b)
            GlobalId(length(global_table.bindings))
        end
        global_table.raw[(m, s)] = id
        return id
    end
end

global_binding(id::GlobalId) = @lock summary_lock global_table.bindings[id]

"""
    Revise.named_id(m, s) -> GlobalId

Return the negative id of the access of the global that the module `m` and the name `s` select, when one of them is not known.

Each of `m` and `s` is a value, the position of a parameter of the method that holds it, or
`nothing` if unknown. `Revise.named_access` returns the access of an id.

# Examples

```jldoctest; setup = :(using Revise)
julia> id = Revise.named_id(Main, nothing); id < 0, id == Revise.named_id(Main, nothing)
(true, true)

julia> Revise.named_access(Revise.named_id(2, 3))
Revise.NamedAccess(2, 3)

julia> Revise.named_id(nothing, :A) == id
false
```
"""
function named_id(@nospecialize(m), @nospecialize(s))
    na = NamedAccess(m, s)
    @lock summary_lock get!(global_table.namedids, na) do
        push!(global_table.named, na)
        -GlobalId(length(global_table.named))
    end
end

named_access(id::GlobalId) = @lock summary_lock global_table.named[-id]

"""
    Origins

The memory that existed before a call and that a value may share: the method's parameters
(`args`, bit `k` for parameter `k`, the function object being parameter 1) and globals
(`globals`, sorted ids of owner-resolved bindings and of globals selected by a module and a
name that are not both known, see [`Revise.named_id`](@ref)).

Memory allocated during the call has no origins, so mutating it is invisible to the caller.
Bit 64 stands for parameter 64 and every later one.
"""
struct Origins
    args::UInt64
    globals::Vector{GlobalId}
end

const no_globals = GlobalId[]
const no_origins = Origins(0, no_globals)

argbit(k::Int) = UInt64(1) << (min(k, 64) - 1)

# The union of two sorted id vectors, without copying if one already contains the other.
function merge_sorted(a::Vector{GlobalId}, b::Vector{GlobalId})
    all(g -> insorted(g, a), b) && return a
    all(g -> insorted(g, b), a) && return b
    return sort!(unique!(vcat(a, b)))
end

Base.union(a::Origins, b::Origins) = Origins(a.args | b.args, merge_sorted(a.globals, b.globals))
Base.issubset(a::Origins, b::Origins) = a.args & ~b.args == 0 && all(g -> insorted(g, b.globals), a.globals)

# The parameter positions in `o`.
argpositions(o::Origins) = [k for k in 1:64 if o.args >> (k - 1) & 1 == 1]

"""
    Precision

How complete a [`Revise.Summary`](@ref) is. `Exact`: it covers everything the call can do.
`Partial`: the call reaches code that cannot be analyzed, or calls itself, so it may mutate
globals the summary does not list. `Cut`: the walk reached its safety limit, so the call may
also read any global. It depends on the walk and is not cached.
"""
@enum Precision Exact Partial Cut

# A method lookup that an analysis relied on: the methods a call with signature `sig` reaches,
# and the inference result of each. `sentinel` stays valid while the lookup is unchanged (see
# `lookup_sentinel`). Mutable so that `IdDict` hashes it by address, not by `sig`.
mutable struct CallCheck
    const sig::Type
    const methods::Vector{Method}
    const cis::Vector{Union{Nothing,Core.CodeInstance}}
    const sentinel::Union{Nothing,Core.CodeInstance}
end
CallCheck(@nospecialize(sig::Type), ms::Vector{Method}, cis::Vector{Union{Nothing,Core.CodeInstance}}) =
    CallCheck(sig, ms, cis, lookup_sentinel(sig, ms))

# The method of the sentinels: Julia invalidates only code instances of methods.
sentinel_owner() = nothing

# Valid sentinels by signature, with the methods of their lookup.
const sentinel_cache = IdDict{Any,Tuple{Core.CodeInstance,Vector{Method}}}()   # guarded by `sentinel_lock`
const sentinel_lock = ReentrantLock()
const max_sentinels = 50_000

same_methods(a::Vector{Method}, b::Vector{Method}) = length(a) == length(b) && all(m -> any(x -> x === m, b), a)

"""
    Revise.lookup_sentinel(sig, ms::Vector{Method}) -> Union{Nothing,Core.CodeInstance}

Return a code instance that Julia invalidates when the methods that a call with signature `sig` reaches change, provided that they are `ms` now.

A method change that affects the lookup invalidates the code instance through its backedges,
which `is_valid` checks. Return `nothing` if the lookup differs from `ms`, if the world changes
meanwhile, before Julia 1.12, and while generating output. Equal lookups share one code instance.

# Examples

```jldoctest; setup = :(using Revise)
julia> module SentinelDoc
           g(x::Integer) = 1
       end;

julia> sig = Tuple{typeof(SentinelDoc.g), Int}; s = Revise.lookup_sentinel(sig, [which(SentinelDoc.g, (Int,))]);

julia> Revise.is_valid(s), Revise.lookup_sentinel(sig, Method[])
(true, nothing)

julia> Core.eval(SentinelDoc, :(g(x::Int) = 2)); Revise.is_valid(s)
false
```
"""
function lookup_sentinel(@nospecialize(sig::Type), ms::Vector{Method})
    dependents_supported && ccall(:jl_generating_output, Cint, ()) == 0 || return nothing
    @lock sentinel_lock begin
        cached = get(sentinel_cache, sig, nothing)
        if !isnothing(cached) && is_valid(cached[1])
            return same_methods(cached[2], ms) ? cached[1] : nothing
        end
        world = Base.get_world_counter()
        lo, hi = Ref(typemin(UInt)), Ref(typemax(UInt))
        matches = Base._methods_by_ftype(sig, nothing, -1, world, false, lo, hi, Ptr{Int32}(C_NULL))
        isa(matches, Vector) && same_methods(Method[(x::Core.MethodMatch).method for x in matches], ms) || return nothing
        edges = Any[sig, Core.methodtable, -length(matches), sig]
        for x in matches
            push!(edges, Core.Compiler.specialize_method(x::Core.MethodMatch))
        end
        sv = Core.svec(edges...)
        owner = Core.Compiler.specialize_method(which(sentinel_owner, ()), Tuple{typeof(sentinel_owner)}, Core.svec())
        ci = Core.CodeInstance(owner, :ReviseLookup, Nothing, Union{}, nothing, nothing, Int32(0), lo[], world,
                               UInt32(0), nothing, nothing, sv)
        Core.Compiler.store_backedges(ci, sv)
        # Valid from now on only if no method changed since the lookup, as for inferred code.
        ccall(:jl_promote_ci_to_current, Cvoid, (Any, UInt), ci, world)
        is_valid(ci) || return nothing
        length(sentinel_cache) >= max_sentinels && empty!(sentinel_cache)
        sentinel_cache[sig] = (ci, ms)
        return ci
    end
end

"""
    Summary

What a call of a method instance may do to memory that existed before the call: what it may
mutate (`mutated`), what its result may share (`returned`), what it may store where other
memory can reach it (`escaped`), and which globals it reads (`reads`) and assigns (`assigned`).
A global that the arguments select has a negative id (see [`Revise.named_id`](@ref)). `checks`
lists the method lookups and inference results of the output methods it reaches (see
[`Revise.output_methods`](@ref)), which inference does not record.

`nargs` and `isva` describe the method's parameters. See [`Revise.Precision`](@ref) for
`precision`.
"""
struct Summary
    mutated::Origins
    returned::Origins
    escaped::Origins
    reads::Vector{GlobalId}
    assigned::Vector{GlobalId}
    checks::Vector{CallCheck}
    nargs::Int
    isva::Bool
    precision::Precision
end

const no_checks = CallCheck[]

function conservative_summary(nargs::Int, isva::Bool, p::Precision)
    o = Origins(nargs >= 64 ? typemax(UInt64) : (UInt64(1) << nargs) - UInt64(1), no_globals)
    return Summary(o, o, o, no_globals, no_globals, no_checks, nargs, isva, p)
end
empty_summary(nargs::Int, isva::Bool) = Summary(no_origins, no_origins, no_origins, no_globals, no_globals, no_checks, nargs, isva, Exact)

# Inference's default limit on the methods it considers at one call site. Inference records
# no dependency on the method table for a call with more matching methods.
const max_methods = 3

# The cached inference result of `mi` in `world`, or `nothing` if inference fails. Julia
# invalidates it when a method it relies on changes, a method is added that a call in it may
# reach, or a `const` global it relies on is redefined.
function code_instance(mi::Core.MethodInstance, world::UInt)
    # In the compiler's world: loading REPL invalidates the compiler's code in the latest world.
    ci = Base.invoke_in_typeinf_world(Core.Compiler.typeinf_ext, Core.Compiler.NativeInterpreter(world), mi,
                                      Core.Compiler.SOURCE_MODE_NOT_REQUIRED)
    return isa(ci, Core.CodeInstance) ? ci : nothing
end

is_valid(ci::Core.CodeInstance) = ci.max_world == typemax(UInt)

# The first world in which `c` no longer holds, or `typemax(UInt)` if it still does. A lookup
# that lost a method counts as changed in the latest world.
function invalid_since(c::CallCheck)
    since = typemax(UInt)
    for ci in c.cis
        ci === nothing || is_valid(ci) || (since = min(since, ci.max_world + 1))
    end
    s = c.sentinel
    !isnothing(s) && is_valid(s) && return since
    world = Base.get_world_counter()
    ms = Base._methods_by_ftype(c.sig, -1, world)::Vector
    length(ms) == length(c.methods) && all(i -> ms[i].method === c.methods[i], eachindex(ms)) && return since
    for m in ms
        m.method in c.methods || (since = min(since, m.method.primary_world::UInt))
    end
    return all(m -> any(x -> x.method === m, ms), c.methods) ? since : min(since, world)
end

# A check of the method lookup for `sig` alone, in the latest world.
function method_check(sig::Type)
    ms = Base._methods_by_ftype(sig, -1, Base.get_world_counter())::Vector
    return CallCheck(sig, Method[m.method for m in ms], fill!(Vector{Union{Nothing,Core.CodeInstance}}(undef, length(ms)), nothing))
end

# What a call of a function of type `ft` with arguments of the types in `argtypes` may do,
# from the inference results of the methods it reaches: the return type, whether the effects
# allow side effects, and the method instances. `check` holds the lookup this relies on.
struct CallInfo
    rettype::Type
    mutates::Bool
    mis::Vector{Core.MethodInstance}
    check::CallCheck
end

# The `CallInfo` of calls with signature `sig` in `world`, or `nothing` if more than
# `max_methods` methods match.
function call_info(sig::Type, world::UInt)
    ms = Base._methods_by_ftype(sig, max_methods, world)
    ms === nothing && return nothing
    rettype = Union{}
    mutates = false
    mis = Core.MethodInstance[]
    cis = Union{Nothing,Core.CodeInstance}[]
    for m in ms
        mi = Core.Compiler.specialize_method(m::Core.MethodMatch)
        ci = code_instance(mi, world)
        push!(mis, mi)
        push!(cis, ci)
        if ci === nothing
            rettype, mutates = Any, true
        else
            rettype = Union{rettype, ci.rettype}
            mutates |= !Core.Compiler.is_effect_free(Core.Compiler.decode_effects(ci.ipo_purity_bits))
        end
    end
    return CallInfo(rettype, mutates, mis, CallCheck(sig, Method[m.method for m in ms], cis))
end

# Each summary with the code instance it was computed from, and valid as long as that is. A
# summary without one does not depend on code that can change.
const summary_cache = Dict{Core.MethodInstance,Tuple{Summary,Union{Nothing,Core.CodeInstance}}}()

# Statements of lowered code a walk may analyze, a safety limit far above the walks of real
# packages. Counting them is independent of load and CPU, and predicts the cost of inference.
const summary_budget = 200_000
# Nested methods a walk may analyze at once; deeper ones would overflow the stack.
const max_depth = 40
# Summaries kept at most, against unbounded memory growth. The cache starts over when full.
const max_summaries = 5000
# After this many specializations of one method reached by dynamic dispatch, the method is
# summarized for its declared signature, as inference widens.
const max_specializations = 4
const specializations = Dict{Method,Vector{Core.MethodInstance}}()   # guarded by `summary_lock`

# The state of one walk through the methods a top-level statement may call. `inprogress` maps
# the methods being analyzed to their depth, and `floor` is the lowest depth of one of them
# that a call reached again since the innermost started. `checks` collects the method lookups
# and inference results the analysis of the statement relies on. `tracked` holds the modules
# whose code and globals a revision can change. `incomplete` maps each method whose summary
# relied on one in progress to that summary, the method of that depth, and the depth. `piracy`
# holds `tracked_piracy` once known.
mutable struct Walk
    world::UInt
    inprogress::Dict{Core.MethodInstance,Int}
    floor::Int
    lowered::Int
    checks::Vector{CallCheck}
    tracked::Set{Module}
    incomplete::Dict{Core.MethodInstance,Tuple{Summary,Core.MethodInstance,Int}}
    piracy::Union{Nothing,Bool}
end
Walk() = Walk(Base.get_world_counter(), Dict{Core.MethodInstance,Int}(), typemax(Int), 0, CallCheck[], tracked_modules(),
              Dict{Core.MethodInstance,Tuple{Summary,Core.MethodInstance,Int}}(), nothing)

# The modules of the tracked packages and `Main`. Summaries leave out the globals of other
# modules, so they are dropped when this set changes.
function tracked_modules()
    mods = Set{Module}([Main])
    for id in keys(pkgdatas)
        id.name == "Core.Compiler" && isnothing(id.uuid) && (push!(mods, Core.Compiler); continue)
        m = get(Base.loaded_modules, id, nothing)
        isnothing(m) || push!(mods, m)
    end
    @lock summary_lock begin
        if mods != tracked_snapshot
            empty!(summary_cache)
            empty!(tracked_snapshot)
            union!(tracked_snapshot, mods)
        end
    end
    return mods
end
const tracked_snapshot = Set{Module}()   # guarded by `summary_lock`

# Whether `m` or a module enclosing it is in `tracked`. A root module, such as `Base`, belongs
# to no other.
function in_tracked(m::Module, tracked::Set{Module})
    while true
        m in tracked && return true
        Base.is_root_module(m) && return false
        p = parentmodule(m)
        p === m && return false
        m = p
    end
end

# Whether the binding numbered `id` belongs to a tracked module. Named accesses are only
# numbered if they may.
tracked_global(walk::Walk, id::GlobalId) = id < 0 || in_tracked(global_binding(id)[1], walk.tracked)

function cached_summary(mi::Core.MethodInstance)
    @lock summary_lock begin
        entry = get(summary_cache, mi, nothing)
        entry === nothing && return nothing
        s, ci = entry
        # Inference does not invalidate `ci` for the output methods a summary reaches.
        (ci === nothing || is_valid(ci)) && all(c -> invalid_since(c) == typemax(UInt), s.checks) && return s
        delete!(summary_cache, mi)
        return nothing
    end
end

function cache_summary!(mi::Core.MethodInstance, s::Summary, ci::Union{Nothing,Core.CodeInstance})
    s.precision === Cut && return s
    @lock summary_lock begin
        length(summary_cache) >= max_summaries && empty!(summary_cache)
        summary_cache[mi] = (s, ci)
    end
    return s
end

# --- Assumptions about functions whose effects come from outside the analyzed code.

# C functions: which arguments they may write (`writes`) and whose referenced contents they
# copy into memory of other arguments (`flows`); other arguments are only read. Julia copies
# references only through write-barrier-aware functions such as `jl_genericmemory_copyto`.
# `CFresh` returns new memory, `CUnknown` may run arbitrary Julia code.
@enum CKind CWrites CFresh CUnknown
struct CEffect
    kind::CKind
    writes::Vector{Int}
    flows::Vector{Int}
end
cwrites(writes::Int...; flows=Int[]) = CEffect(CWrites, collect(Int, writes), flows)
const cfresh = CEffect(CFresh, Int[], Int[])
const cunknown = CEffect(CUnknown, Int[], Int[])
const ctable = Dict{Symbol,CEffect}(
    :memmove => cwrites(1), :memcpy => cwrites(1), :memset => cwrites(1), :memcmp => cwrites(), :strlen => cwrites(),
    :jl_alloc_genericmemory => cfresh, :jl_alloc_string => cfresh, :jl_string_to_genericmemory => cfresh,
    :jl_genericmemory_to_string => cfresh, :jl_pchar_to_string => cfresh, :jl_array_to_string => cfresh,
    :jl_genericmemory_copyto => cwrites(1, 2; flows=[3, 4]), :jl_genericmemory_slice => cwrites(),
    :jl_uv_write => cwrites(1), :ios_write => cwrites(1), :jl_uv_puts => cwrites(1), :jl_uv_putc => cwrites(1),
    :jl_object_id => cwrites(), :jl_object_id_ => cwrites(), :jl_type_hash => cwrites(), :memhash_seed => cwrites(),
    :jl_string_ptr => cwrites(), :jl_value_ptr => cwrites(), :jl_symbol_name => cwrites(), :jl_module_parent => cwrites(),
    :jl_rethrow => cwrites(), :jl_rethrow_other => cwrites(), :jl_type_unionall => cfresh, :jl_gc_safepoint => cwrites(),
    :jl_get_world_counter => cwrites(), :jl_get_current_task => cwrites(), :jl_gc_disable_finalizers_internal => cwrites(),
    :jl_gc_enable_finalizers_internal => cwrites(), :jl_get_ptls_states => cwrites(), :jl_cpu_threads => cwrites(),
    :jl_threadid => cwrites(),
    # Code that runs in other tasks or finalizers runs anyway, so the statement does not cause it.
    :jl_gc_run_pending_finalizers => cwrites(), :jl_get_task_tid => cwrites(), :jl_gc_is_in_finalizer => cwrites(),
    :jl_wakeup_thread => cwrites(), :jl_set_task_tid => cwrites(),
    :jl_toplevel_eval_in => cunknown, :jl_toplevel_eval => cunknown, :jl_eval_string => cunknown,
    :jl_call => cunknown, :jl_load => cunknown, :jl_load_ => cunknown,
    :jl_types_equal => cwrites(), :utf8proc_category => cwrites(), :jl_get_tls_world_age => cwrites(),
    :jl_uncompress_ir => cfresh, :jl_gf_invoke_lookup_worlds => cwrites(4, 5), :jl_matching_methods => cwrites(6, 7, 8),
    :jl_symbol_n => cfresh, :jl_symbol => cfresh, :jl_cstr_to_string => cfresh, :jl_intrinsic_name => cwrites(),
    :jl_get_backtrace => cfresh, :jl_gf_invoke_lookup => cwrites(), :jl_generating_output => cwrites(),
    :jl_hrtime => cwrites(),
)

const mutating_builtins = Set{Symbol}([:setfield!, :modifyfield!, :replacefield!, :swapfield!, :setfieldonce!,
    :memoryrefset!, :memoryrefmodify!, :memoryrefreplace!, :memoryrefswap!, :memoryrefsetonce!,
    :pointerset, :atomic_pointerset, :atomic_pointerswap, :atomic_pointermodify, :atomic_pointerreplace])
const global_writers = Set{Symbol}([:setglobal!, :swapglobal!, :modifyglobal!, :replaceglobal!, :setglobalonce!,
                                    :declare_const])
# Builtins that call the function they get as an argument.
const modifying_builtins = Set{Symbol}([:modifyfield!, :memoryrefmodify!, :atomic_pointermodify, :modifyglobal!])
const calling_builtins = Set{Symbol}([:_apply_iterate, :_call_latest, :_call_in_world, :_call_in_world_total,
    :invoke, :invokelatest, :finalizer, :_compute_sparams, :invoke_in_world])
const loading_builtins = Set{Symbol}([:getfield, :memoryrefget, :memoryrefnew, :pointerref, :atomic_pointerref,
    :arrayref, :memoryref_isassigned, :typeassert, :compilerbarrier])

# Functions that evaluate code: their effects are those of arbitrary code.
const evaluating_functions = Set{DataType}(typeof.([Core.eval, Base.eval, Base.include, Core.include,
                                                    Base.include_string, Base.invokelatest]))
@static isdefined(Base, :IncludeInto) && push!(evaluating_functions, Base.IncludeInto)   # the `include` of a module
# Assumption: output functions change only their stream, the first argument, apart from what
# the methods that `output_methods` lists do.
const stream_functions = Set{DataType}(typeof.([print, println, show, write, showerror, Base.show_backtrace]))
# Assumption: these change no value a statement computes. `precompile` only compiles. Logging
# changes the logger. Locks return to their state, and code in other tasks runs anyway.
# Docstrings change only the documentation.
const noeffect_names = Set{Symbol}([:precompile, :lock, :unlock, :trylock, :slowlock, :_unlock, :wait,
    :wait_no_relock, :yield, :enq_work, :schedule, :notify, :current_logger_for_env, :handle_message_nothrow,
    :handle_message, :shouldlog, :logging_error, :doc!])

# The summary that an assumption above gives `m` with parameter types `params`, if any.
function assumed_summary(m::Method, params::Core.SimpleVector)
    nargs, isva = Int(m.nargs), m.isva
    ft = params[1]
    ft in evaluating_functions && return conservative_summary(nargs, isva, Partial)
    if m.module in (Base, Base.Threads, Base.CoreLogging, Base.Docs) && m.name in noeffect_names
        any(i -> isa(params[i], Type) && params[i] <: Base.Callable, 2:length(params)) && return nothing   # `lock(f, l)` calls `f`
        return empty_summary(nargs, isva)
    end
    return nothing
end

"""
    Revise.inert_call(m::Method, params::Core.SimpleVector, walk::Revise.Walk) -> Bool

Return whether the assumption holds that a call of `m` with parameter types `params` reads, assigns, and mutates nothing of the tracked modules of `walk`.

The assumption applies to a method of an untracked module whose parameter types, including the
function's, are inert (see [`Revise.inert_type`](@ref)), unless a tracked module adds a method
to a function of an untracked one for untracked types only (see [`Revise.tracked_piracy`](@ref)).

# Examples

```jldoctest; setup = :(using Revise)
julia> module InertDoc
           struct T end
       end;

julia> walk = Revise.Walk(); push!(walk.tracked, InertDoc);

julia> inert(f, types...) = Revise.inert_call(which(f, types), Core.svec(typeof(f), types...), walk);

julia> inert(joinpath, String, String), inert(push!, Vector{Int}, Int), inert(identity, InertDoc.T)
(true, false, false)
```
"""
function inert_call(m::Method, params::Core.SimpleVector, walk::Walk)
    in_tracked(m.module, walk.tracked) && return false
    all(T -> inert_type(T, walk.tracked), params) || return false
    return !tracked_piracy(walk)
end

"""
    Revise.inert_type(T, tracked::Set{Module}) -> Bool

Return whether no value of type `T` can reach mutable memory, a module, or a type of a module in `tracked`, other than through a type it names.

`T` must name no type of a module in `tracked`, and be a type of a type, as `Type{Int}`, or
hold no mutable memory (see [`Revise.may_hold_mutable`](@ref)) without being `Module` or a type
of types, as `DataType`.

# Examples

```jldoctest; setup = :(using Revise)
julia> tracked = Set([Main]); struct InertT end

julia> Revise.inert_type(Tuple{String,Base.UUID}, tracked), Revise.inert_type(Type{Float64}, tracked)
(true, true)

julia> Revise.inert_type(Vector{Int}, tracked), Revise.inert_type(Module, tracked), Revise.inert_type(DataType, tracked)
(false, false, false)

julia> Revise.inert_type(InertT, tracked), Revise.inert_type(Type{InertT}, tracked)
(false, false)
```
"""
function inert_type(@nospecialize(T), tracked::Set{Module})
    T = vararg_type(T)
    isa(T, Type) || return false
    if Base.isType(T) || is_typeeq(T)
        Base.has_free_typevars(T) && return false
    elseif T <: Union{Module,Type} || may_hold_mutable(T)
        return false
    end
    return isempty(type_names!(Set{Core.TypeName}(), T, tracked))
end

is_stream_call(params) = length(params) >= 2 && params[1] in stream_functions && params[2] isa Type && params[2] <: IO

# The summary of a call of an output function with parameter types `params`: it mutates the
# stream, and reads, assigns, and mutates the globals that the methods `output_methods` lists
# read, assign, and mutate. Not cached, since methods of tracked modules come and go.
function stream_summary(walk::Walk, params, nargs::Int, isva::Bool)
    reads, assigned, mutated, precision = no_globals, no_globals, no_globals, Exact
    checks = CallCheck[]
    for m in output_methods(walk, params)
        mi = generic_instance(m)
        push!(checks, instance_check(m, mi, walk.world))
        d = get(walk.inprogress, mi, 0)
        if d > 0   # its reads and mutations are those of the summary in progress
            walk.floor = min(walk.floor, d)
            continue
        end
        s = summarize(mi, walk)
        # The parameters of `m` that select a global need not be those of the output call.
        reads = merge_sorted(reads, unbound_ids(s.reads))
        assigned = merge_sorted(assigned, unbound_ids(s.assigned))
        mutated = merge_sorted(mutated, unbound_ids(s.mutated.globals))
        append!(checks, s.checks)
        precision = max(precision, s.precision)
    end
    return Summary(Origins(argbit(2), mutated), no_origins, no_origins, reads, assigned, checks, nargs, isva, precision)
end

# `ids` with each global that parameters of a method select replaced by one that unknown
# values select, for a call whose arguments are not those parameters.
function unbound_ids(ids::Vector{GlobalId})
    (isempty(ids) || first(ids) > 0) && return ids
    unbound(id) = id > 0 ? id : let na = named_access(id)
        named_id(isa(na.mod, Int) ? nothing : na.mod, isa(na.name, Int) ? nothing : na.name)
    end
    return sort!(unique!(map(unbound, ids)))
end

# A check of the method lookup for the signature of `m`, and of the inference result of its
# specialization `mi`. One object per `mi` and world, so that statements share it.
function instance_check(m::Method, mi::Core.MethodInstance, world::UInt)
    c = @lock inference_lock begin
        world == inference_world[] || reset_inference_caches!(world)
        get(instance_check_cache, mi, nothing)
    end
    isnothing(c) || return c
    ms = Method[(x::Core.MethodMatch).method for x in Base._methods_by_ftype(m.sig, -1, world)::Vector]
    cis = Union{Nothing,Core.CodeInstance}[x === m ? code_instance(mi, world) : nothing for x in ms]
    c = CallCheck(m.sig, ms, cis)
    @lock inference_lock inference_world[] == world && (instance_check_cache[mi] = c)
    return c
end

"""
    Revise.output_methods(walk::Revise.Walk, params) -> Vector{Method}

Return the methods of tracked modules that a call of an output function with parameter types `params` may reach.

These are the methods of output functions whose typed parameter after the stream accepts a
concrete part (see [`Revise.type_parts!`](@ref)) of a later argument, and the methods with a
parameter after the first whose type names a tracked type, or a supertype of one, that is a part
of any argument, as `getindex` of an array type.

# Examples

```jldoctest; setup = :(using Revise)
julia> module OutDoc
           struct V <: AbstractVector{Int} end
           Base.size(::V) = (1,)
           Base.getindex(::V, i::Int) = 1
       end;

julia> ms(T) = sort!([string(m.name) for m in Revise.output_methods(Revise.Walk(), Any[typeof(print), IOBuffer, T])]);

julia> ms(Vector{OutDoc.V})
2-element Vector{String}:
 "getindex"
 "size"

julia> ms(Int)
String[]
```
"""
function output_methods(walk::Walk, params)
    parts = Base.IdSet{Any}()
    for i in 3:length(params)
        type_parts!(parts, vararg_type(params[i]))
    end
    ms = Method[m for m in tracked_stream_methods(walk) if may_print(m, parts)]
    length(params) >= 2 && type_parts!(parts, params[2])
    names = Set{Core.TypeName}()
    for T in parts
        U = Base.unwrap_unionall(T)
        while isa(U, DataType) && U !== Any
            in_tracked(U.name.module, walk.tracked) && push!(names, U.name)
            U = supertype(U)
        end
    end
    isempty(names) && return ms
    seen = Base.IdSet{Method}(ms)
    index = methods_by_type(walk)
    for tn in names, m in get(index, tn, ())
        m in seen || (push!(seen, m); push!(ms, m))
    end
    return ms
end

# The methods of output functions defined in tracked modules, by world and tracked modules.
const stream_methods = Ref{Tuple{UInt,Set{Module},Vector{Method}}}((typemax(UInt), Set{Module}(), Method[]))

function tracked_stream_methods(walk::Walk)
    @lock summary_lock begin
        world, tracked, ms = stream_methods[]
        world == walk.world && tracked == walk.tracked && return ms
    end
    ms = Method[]
    for ft in stream_functions
        for match in Base._methods_by_ftype(Tuple{ft, Vararg{Any}}, -1, walk.world)::Vector
            m = (match::Core.MethodMatch).method
            in_tracked(m.module, walk.tracked) && push!(ms, m)
        end
    end
    @lock summary_lock stream_methods[] = (walk.world, walk.tracked, ms)
    return ms
end

# The methods of tracked modules that dispatch can select, by the types of tracked modules
# that their parameter types after the first name, and whether one of them names no type of a
# tracked module at all, by world and tracked modules.
const typed_methods = Ref{Tuple{UInt,Set{Module},Dict{Core.TypeName,Vector{Method}},Bool}}(
    (typemax(UInt), Set{Module}(), Dict{Core.TypeName,Vector{Method}}(), false))

methods_by_type(walk::Walk) = typed_methods_entry(walk)[1]

"""
    Revise.tracked_piracy(walk::Revise.Walk) -> Bool

Return whether a tracked module of `walk` defines a method whose signature, the function included, names no type of a tracked module.

Code of untracked modules may then call it with arguments of untracked types, so
[`Revise.inert_call`](@ref) does not apply. Methods of Julia's standard libraries do not count,
since they are part of Julia.

# Examples

```jldoctest; setup = :(using Revise)
julia> module PiracyDoc
           struct T end
           Base.length(::T) = 0
       end;

julia> walk = Revise.Walk(); empty!(walk.tracked); push!(walk.tracked, PiracyDoc); Revise.tracked_piracy(walk)
false

julia> Core.eval(PiracyDoc, :(Base.length(::Base.UUID) = 0)); walk = Revise.Walk(); empty!(walk.tracked);

julia> push!(walk.tracked, PiracyDoc); Revise.tracked_piracy(walk)
true
```
"""
function tracked_piracy(walk::Walk)
    p = walk.piracy
    isnothing(p) || return p
    return walk.piracy = typed_methods_entry(walk)[2]
end

# One thread scans the method table while the others wait for its result.
const typed_methods_lock = ReentrantLock()

function typed_methods_entry(walk::Walk)
    @lock typed_methods_lock begin
        world, tracked, cached, piracy = typed_methods[]
        world == walk.world && tracked == walk.tracked && return cached, piracy
        index = Dict{Core.TypeName,Vector{Method}}()
        names = Set{Core.TypeName}()
        pirated = Ref(false)
        Base.visit(Core.methodtable) do m
            # A deleted or replaced method is no longer the latest for its signature.
            in_tracked(m.module, walk.tracked) && !iszero(m.dispatch_status & 0x01) || return nothing
            empty!(names)
            params = Base.unwrap_unionall(m.sig).parameters
            for j in 2:length(params)
                type_names!(names, params[j], walk.tracked)
            end
            for tn in names
                push!(get!(Vector{Method}, index, tn), m)
            end
            pirated[] |= isempty(names) && isempty(type_names!(names, params[1], walk.tracked)) &&
                         !is_julia_pkg(PkgId(Base.moduleroot(m.module)))
            return nothing
        end
        typed_methods[] = (walk.world, copy(walk.tracked), index, pirated[])
        return index, pirated[]
    end
end

# Add to `names` the names of the types of `tracked` modules that the type `T` names.
function type_names!(names::Set{Core.TypeName}, @nospecialize(T), tracked::Set{Module})
    T = vararg_type(T)
    if isa(T, TypeVar)
        type_names!(names, T.ub, tracked)
    elseif isa(T, UnionAll)
        type_names!(names, Base.unwrap_unionall(T), tracked)
    elseif isa(T, Union)
        type_names!(names, T.a, tracked)
        type_names!(names, T.b, tracked)
    elseif is_typeeq(T)
        type_names!(names, typeeq_parameter(T), tracked)
    elseif isa(T, DataType)
        in_tracked(T.name.module, tracked) && push!(names, T.name)
        for x in T.parameters
            type_names!(names, x, tracked)
        end
    end
    return names
end

# Whether the output method `m` may run for a call whose arguments after the stream have the
# parts `parts`: a typed parameter of `m` after the stream accepts a concrete part.
function may_print(m::Method, parts::Base.IdSet{Any})
    sig = Base.unwrap_unionall(m.sig).parameters
    for j in 3:length(sig)
        p = Base.rewrap_unionall(vararg_type(sig[j]), m.sig)
        p == Any && continue
        for T in parts
            isconcretetype(T) && typeintersect(p, T) !== Union{} && return true
        end
    end
    return false
end

vararg_type(@nospecialize(x)) = isa(x, Core.TypeofVararg) ? (isdefined(x, :T) ? x.T : Any) : x

"""
    Revise.type_parts!(parts::Base.IdSet{Any}, T) -> parts

Add the type `T` and the types it holds to `parts`: the parameters of each type and, for a concrete type, its field types, as the default `show` prints them.

# Examples

```jldoctest; setup = :(using Revise)
julia> parts(T) = sort!(String[string(x) for x in Revise.type_parts!(Base.IdSet{Any}(), T)]);

julia> parts(Some{Int8})
2-element Vector{String}:
 "Int8"
 "Some{Int8}"

julia> parts(Pair{Int8, Union{Int16, Nothing}})
5-element Vector{String}:
 "Int16"
 "Int8"
 "Nothing"
 "Pair{Int8, Union{Nothing, Int16}}"
 "Union{Nothing, Int16}"

julia> parts(3)
String[]
```
"""
function type_parts!(parts::Base.IdSet{Any}, @nospecialize(T))
    isa(T, Type) && !(T in parts) || return parts
    push!(parts, T)
    if isconcretetype(T)
        for i in 1:fieldcount(T)
            type_parts!(parts, fieldtype(T, i))
        end
    end
    U = Base.unwrap_unionall(T)
    if isa(U, Union)
        type_parts!(parts, U.a)
        type_parts!(parts, U.b)
    elseif is_typeeq(U)
        type_parts!(parts, typeeq_parameter(U))
    elseif isa(U, DataType)
        for x in U.parameters
            type_parts!(parts, x)
        end
    end
    return parts
end

"""
    summarize(mi::Core.MethodInstance, walk::Revise.Walk=Revise.Walk()) -> Summary
    summarize(sig::Type{<:Tuple}) -> Summary

Return what a call of `mi` may do to memory that existed before the call.

The method's optimized code is walked, together with the code of every method it may call,
within the budget of `walk`. Calls of C functions, of functions that evaluate code, and of
functions covered by assumptions (output, logging, locks) are not walked, except for the
methods of tracked modules that output may reach (see [`Revise.output_methods`](@ref)).
Globals of modules that are not tracked are left out, since no revision changes them.

# Examples

```jldoctest; setup = :(using Revise)
julia> s = Revise.summarize(Tuple{typeof(push!), Vector{Int}, Int});

julia> Revise.argpositions(s.mutated), Revise.argpositions(s.returned)
([2], [2])

julia> s = Revise.summarize(Tuple{typeof(copy), Vector{Int}});

julia> Revise.argpositions(s.mutated), Revise.argpositions(s.returned), s.precision
(Int64[], Int64[], Revise.Exact)
```
"""
function summarize(sig::Type{<:Tuple})
    m = only(Base._methods_by_ftype(sig, -1, Base.get_world_counter()))::Core.MethodMatch
    return summarize(Core.Compiler.specialize_method(m), Walk())
end

function summarize(mi::Core.MethodInstance, walk::Walk=Walk())
    s = cached_summary(mi)
    s === nothing || return s
    m = mi.def
    isa(m, Method) || return conservative_summary(length(Base.unwrap_unionall(mi.specTypes).parameters), false, Partial)
    nargs, isva = Int(m.nargs), m.isva
    params = Base.unwrap_unionall(mi.specTypes).parameters
    is_stream_call(params) && !in_tracked(m.module, walk.tracked) && return stream_summary(walk, params, nargs, isva)
    a = assumed_summary(m, params)
    a === nothing || return cache_summary!(mi, a, nothing)
    inert_call(m, params, walk) && return empty_summary(nargs, isva)
    # A method already being analyzed in this walk calls itself, maybe through others. Its own
    # summary covers what it does.
    d = get(walk.inprogress, mi, 0)
    if d > 0
        walk.floor = min(walk.floor, d)
        return conservative_summary(nargs, isva, Partial)
    end
    # An incomplete summary holds while the method it relied on is in progress, and analyzing
    # it again on each path through a cycle would cost exponential time.
    entry = get(walk.incomplete, mi, nothing)
    if !isnothing(entry)
        s, root, rootdepth = entry
        if get(walk.inprogress, root, 0) == rootdepth
            walk.floor = min(walk.floor, rootdepth)
            return s
        end
        delete!(walk.incomplete, mi)
    end
    length(walk.inprogress) >= max_depth && return conservative_summary(nargs, isva, Cut)
    lowered = lowered_code(m)
    lowered === nothing || !guarded_out(lowered) || return cache_summary!(mi, empty_summary(nargs, isva), nothing)
    n = lowered === nothing ? 0 : length(lowered.code)
    walk.lowered + n > summary_budget && return conservative_summary(nargs, isva, Cut)
    walk.lowered += n
    depth = length(walk.inprogress) + 1
    walk.inprogress[mi] = depth
    outer, walk.floor = walk.floor, typemax(Int)
    ci = code_instance(mi, walk.world)
    code = optimized_code(ci, mi, nargs, isva, walk.world)
    s = isa(code, CodeInfo) ? analyze(code, nargs, isva, walk) : conservative_summary(nargs, isva, Partial)
    delete!(walk.inprogress, mi)
    # A summary that relied on the summary of a caller still in progress lacks what that caller
    # does, so only the caller's summary, which includes this one, is complete.
    complete = walk.floor >= depth
    floor = walk.floor
    walk.floor = complete ? outer : min(outer, walk.floor)
    # A change of a method of the function is a change of what a caller reads.
    fid = global_id(m.module, m.name)
    reads = tracked_global(walk, fid) ? merge_sorted(s.reads, [fid]) : s.reads
    s = Summary(s.mutated, s.returned, s.escaped, reads, s.assigned, s.checks, nargs, isva, s.precision)
    if !complete
        root = findfirst(==(floor), walk.inprogress)
        isnothing(root) || (walk.incomplete[mi] = (s, root, floor))
    end
    return ci === nothing || !complete ? s : cache_summary!(mi, s, ci)
end

# The lowered code of `m`, or `nothing`, e.g. for a generated function.
function lowered_code(m::Method)
    isdefined(m, :source) && m.source !== nothing || return nothing
    return Base.uncompressed_ir(m)
end

# The optimized code of `mi` in `world`: the code cached in `ci` if it has any, else the result
# of inference. Cached code lacks the types of the arguments, which come from `mi`.
function optimized_code(ci::Union{Nothing,Core.CodeInstance}, mi::Core.MethodInstance, nargs::Int, isva::Bool,
                        world::UInt)
    src = ci === nothing ? nothing : ci.inferred
    isa(src, Union{String,Vector{UInt8}}) && (src = Base._uncompressed_ir(ci, src))
    isa(src, CodeInfo) ||
        return Base.invoke_in_typeinf_world(Core.Compiler.typeinf_code, Core.Compiler.NativeInterpreter(world), mi,
                                            true)::Union{Nothing,CodeInfo}
    if src.slottypes === nothing
        params = Base.unwrap_unionall(mi.specTypes).parameters
        slottypes = Any[Any for _ in src.slotnames]
        for i in 1:min(nargs, length(params), length(slottypes))
            if isva && i == nargs
                rest = Any[]
                for j in i:length(params)
                    push!(rest, upper_bound(params[j]))
                end
                slottypes[i] = Tuple{rest...}
            else
                slottypes[i] = upper_bound(params[i])
            end
        end
        src.slottypes = slottypes
    end
    return src
end

upper_bound(@nospecialize(T)) = isa(T, TypeVar) ? T.ub : T

# --- The walk through one body.

holds(@nospecialize(T)) = may_hold_mutable(Core.Compiler.widenconst(T))

# Optimized code of newer Julia versions may hold a binding partition where older ones hold a
# `GlobalRef`.
@static if isdefined(Core, :BindingPartition) && isdefined(Base, :partition_owner)
    as_globalref(@nospecialize(x)) = isa(x, Core.BindingPartition) ? Base.partition_owner(x).globalref : x
else
    as_globalref(@nospecialize(x)) = x
end

# The builtins that take a binding partition, each with the builtin that takes the module and
# the name of the binding instead.
const partition_builtins = Dict{Symbol,Symbol}(:getglobal_partition => :getglobal,
    :setglobal_partition => :setglobal!, :swapglobal_partition => :swapglobal!,
    :modifyglobal_partition => :modifyglobal!, :replaceglobal_partition => :replaceglobal!,
    :setglobalonce_partition => :setglobalonce!, :isdefinedglobal_partition => :isdefinedglobal)

"""
    Revise.unpartitioned(src::CodeInfo, nm::Symbol, args::Vector{Any}) -> Tuple{Symbol,Vector{Any}}

Return the builtin named `nm` with its arguments `args` in `src`, with a builtin on a constant binding partition replaced by the builtin on its module and name.

Optimized code of newer Julia versions calls, for example, `setglobal_partition` where older
ones call `setglobal!`. A builtin on a partition that is not a constant is returned unchanged.

# Examples

```jldoctest; setup = :(using Revise)
julia> src = Meta.lower(Main, :(identity(1))).args[1];

julia> args = Any[QuoteNode(Main), QuoteNode(:A), 1]; Revise.unpartitioned(src, :setglobal!, args) == (:setglobal!, args)
true

julia> Revise.unpartitioned(src, :setglobal_partition, Any[Core.Argument(2), 1])[1]
:setglobal_partition
```
"""
function unpartitioned(src::CodeInfo, nm::Symbol, args::Vector{Any})
    base = get(partition_builtins, nm, nothing)
    (isnothing(base) || isempty(args)) && return nm, args
    p = ir_value(src, args[1])
    g = isnothing(p) ? nothing : as_globalref(something(p))
    isa(g, GlobalRef) || return nm, args
    return base, Any[QuoteNode(g.mod), QuoteNode(g.name), args[2:end]...]
end

# The state of the walk through one body: the optimized code of a method if `ctx` is `nothing`,
# else the lowered code of a top-level statement, with `ctx` its `LoweredStmt`. `slotdefs` and
# `globaldefs` hold the indices of the statements that assign each slot and global. For
# top-level code, `readsat` pairs each read with the index of the statement it comes from.
# `hidden` tells whether a read of a global whose module or name is not known comes from a
# called method or a C function, where running the frame does not show which global it is.
mutable struct SummaryFrame{C}
    src::CodeInfo
    walk::Walk
    ctx::C
    orig::Vector{Origins}
    slotdefs::Dict{Int,Vector{Int}}
    globaldefs::Dict{GlobalId,Vector{Int}}
    heap::Origins        # what values stored into memory reachable from elsewhere may share
    mutated::Origins
    reads::Vector{GlobalId}
    readsat::Set{Tuple{GlobalId,Int}}
    assigned::Vector{GlobalId}
    checks::Vector{CallCheck}
    precision::Precision
    hidden::Bool
end

function analyze(src::CodeInfo, nargs::Int, isva::Bool, walk::Walk)
    live, _ = reachable(src)
    fr = analyze_frame(src, walk, nothing, live)
    returned = no_origins
    returns_mutable = false
    for (i, stmt) in enumerate(src.code)
        live[i] && isa(stmt, Core.ReturnNode) && isdefined(stmt, :val) || continue
        returned = returned ∪ origins(fr, stmt.val)
        returns_mutable |= holds(frame_type(fr, stmt.val))
    end
    # A returned object, even a new one such as `[x]`, may reach any value stored into memory.
    returns_mutable && (returned = returned ∪ fr.heap)
    return Summary(fr.mutated, returned, fr.heap, sort!(unique!(fr.reads)), sort!(unique!(fr.assigned)), unique!(fr.checks),
                   nargs, isva, fr.precision)
end

"""
    Revise.analyze_frame(src::CodeInfo, walk::Revise.Walk, ctx=nothing, live=first(Revise.reachable(src))) -> Revise.SummaryFrame

Follow the value flow through `src` until the origins of its statements no longer change, and return the final state.

`ctx` is `nothing` for the optimized code of a method and the `LoweredStmt` of `src` for a
top-level statement. Only the statements marked in `live` are followed.

# Examples

```jldoctest; setup = :(using Revise)
julia> function frame(ex)
           src = Meta.lower(Main, ex).args[1]
           return Revise.analyze_frame(src, Revise.Walk(), Revise.LoweredStmt(src, Set{Tuple{Module,Symbol}}(), Dict{Tuple{Module,Symbol},Any}()))
       end;

julia> readsat(fr) = sort!([(Revise.global_binding(id)[2], i) for (id, i) in fr.readsat]);

julia> V = Int[]; readsat(frame(:(V = push!(V, 1))))
1-element Vector{Tuple{Symbol, Int64}}:
 (:V, 4)

julia> readsat(frame(:(V = Int[])))
Tuple{Symbol, Int64}[]
```
"""
function analyze_frame(src::CodeInfo, walk::Walk, ctx=nothing, live::BitVector=first(reachable(src)))
    n = length(src.code)
    fr = SummaryFrame(src, walk, ctx, fill(no_origins, n), Dict{Int,Vector{Int}}(), Dict{GlobalId,Vector{Int}}(),
                      no_origins, no_origins, GlobalId[], Set{Tuple{GlobalId,Int}}(), GlobalId[], CallCheck[], Exact, false)
    for (i, stmt) in enumerate(src.code)
        if isexpr(stmt, :(=), 2) && isa(stmt.args[1], Core.SlotNumber)
            push!(get!(Vector{Int}, fr.slotdefs, stmt.args[1].id), i)
        else
            id = assigned_global(src, stmt)
            isnothing(id) || push!(get!(Vector{Int}, fr.globaldefs, id), i)
        end
    end
    converged = false
    for _ in 1:20
        heap = fr.heap
        changed = false
        for i in 1:n
            live[i] || continue
            k = length(fr.reads)
            new = stmt_origins(fr, src.code[i])
            isnothing(ctx) || foreach(j -> push!(fr.readsat, (fr.reads[j], i)), k+1:length(fr.reads))
            new ⊆ fr.orig[i] && continue
            fr.orig[i] = fr.orig[i] ∪ new
            changed = true
        end
        # A load before a store in the code returns what the store added only in the next round.
        converged = !changed && fr.heap ⊆ heap
        converged && break
    end
    converged || (fr.precision = max(fr.precision, Partial))
    return fr
end

# The number of the global binding that `stmt` assigns, directly or through a builtin such as
# `setglobal!` whose module and name are constants in `src`, or `nothing`.
function assigned_global(src::CodeInfo, @nospecialize(stmt))
    if isexpr(stmt, :(=), 2)
        lhs = as_globalref(stmt.args[1])
        return isa(lhs, GlobalRef) ? global_id(lhs.mod, lhs.name) : nothing
    end
    isexpr(stmt, :call) && length(stmt.args) >= 3 || return nothing
    f = ir_value(src, stmt.args[1])
    !isnothing(f) && isa(something(f), Core.Builtin) || return nothing
    nm, args = unpartitioned(src, nameof(something(f)), stmt.args[2:end])
    nm in global_writers && length(args) >= 3 || return nothing
    m, s = ir_value(src, args[1]), ir_value(src, args[2])
    !isnothing(m) && !isnothing(s) && isa(something(m), Module) && isa(something(s), Symbol) || return nothing
    return global_id(something(m), something(s))
end

function stmt_origins(fr::SummaryFrame, @nospecialize(stmt))
    stmt = as_globalref(stmt)
    isa(stmt, Union{Core.SSAValue,Core.Argument,Core.SlotNumber,GlobalRef}) && return origins(fr, stmt)
    isa(stmt, Core.PiNode) && return origins(fr, stmt.val)
    if isa(stmt, Core.PhiNode)
        o = no_origins
        for k in eachindex(stmt.values)
            isassigned(stmt.values, k) && (o = o ∪ origins(fr, stmt.values[k]))
        end
        return o
    end
    isa(stmt, Core.UpsilonNode) && return isdefined(stmt, :val) ? origins(fr, stmt.val) : no_origins
    isa(stmt, Core.PhiCNode) && return args_origins(fr, stmt.values)
    isa(stmt, Expr) && return transfer!(fr, stmt)
    return no_origins
end

function origins(fr::SummaryFrame, @nospecialize(x))
    x = as_globalref(x)
    isa(x, GlobalRef) && return global_origins(fr, x)
    isa(x, Union{Core.Argument,Core.SSAValue,Core.SlotNumber}) && holds(frame_type(fr, x)) || return no_origins
    isa(x, Core.Argument) && return Origins(argbit(x.n), no_globals)
    isa(x, Core.SSAValue) && return fr.orig[x.id]
    return assigned_origins(fr, get(fr.slotdefs, x.id, nothing))
end

# The origins of the global `x`: itself if tracked, and what the code assigns to it.
function global_origins(fr::SummaryFrame, x::GlobalRef)
    id = global_id(x.mod, x.name)
    o = assigned_origins(fr, get(fr.globaldefs, id, nothing))
    tracked_global(fr.walk, id) || return o
    push!(fr.reads, id)
    return holds(frame_type(fr, x)) ? o ∪ Origins(0, [id]) : o
end

assigned_origins(fr::SummaryFrame, defs) =
    isnothing(defs) ? no_origins : reduce(∪, (fr.orig[i] for i in defs); init=no_origins)

args_origins(fr::SummaryFrame, args) = reduce(∪, (origins(fr, a) for a in args); init=no_origins)

# The type of `x`, an argument in the code of `fr`.
frame_type(fr::SummaryFrame{Nothing}, @nospecialize(x)) = ir_type(fr.src, x)

mutate!(fr::SummaryFrame, o::Origins) = (fr.mutated = fr.mutated ∪ o; nothing)
escape!(fr::SummaryFrame, o::Origins) = (fr.heap = fr.heap ∪ o; nothing)

# Code the walk does not follow, called with `args`: it may mutate what any argument reaches,
# store it into other memory, and return it. Returns the origins of the arguments.
function unknown!(fr::SummaryFrame, args)
    fr.precision = max(fr.precision, Partial)
    o = args_origins(fr, args)
    mutate!(fr, o)
    escape!(fr, o)
    return o
end

# The type of `x`, an argument in the optimized code `src`.
function ir_type(src::CodeInfo, @nospecialize(x))
    x = as_globalref(x)
    isa(x, Core.SSAValue) && return Core.Compiler.widenconst(src.ssavaluetypes[x.id])
    isa(x, Core.Argument) && return Core.Compiler.widenconst(src.slottypes[x.n])
    if isa(x, GlobalRef)
        v = ir_value(src, x)
        return v === nothing ? Any : Core.Typeof(something(v))
    end
    isa(x, QuoteNode) && return Core.Typeof(x.value)
    isa(x, Expr) && return Any
    return Core.Typeof(x)
end

# The value of `x`, an argument in `src`, wrapped in `Some`, if it is a constant.
function ir_value(src::CodeInfo, @nospecialize(x))
    x = as_globalref(x)
    if isa(x, GlobalRef)
        @invokelatest(isdefinedglobal(x.mod, x.name)) && @invokelatest(isconst(x.mod, x.name)) || return nothing
        return Some{Any}(@invokelatest getglobal(x.mod, x.name))
    end
    isa(x, QuoteNode) && return Some{Any}(x.value)
    if isa(x, Core.SSAValue)
        src.ssavaluetypes isa Vector || return nothing   # lowered code has no types
        t = src.ssavaluetypes[x.id]
        isa(t, Core.Const) && return Some{Any}(t.val)
        T = Core.Compiler.widenconst(t)
        isa(T, DataType) && isdefined(T, :instance) && return Some{Any}(T.instance)
        return nothing
    end
    isa(x, Union{Core.Argument,Core.SlotNumber,Expr}) && return nothing
    return Some{Any}(x)
end

known_type(@nospecialize(T)) = isconcretetype(T) || (Base.isType(T) && !Base.has_free_typevars(T))
function known_signature(@nospecialize(sig))
    params = Base.unwrap_unionall(sig).parameters
    for i in 1:length(params)
        known_type(params[i]) || return false
    end
    return true
end

function transfer!(fr::SummaryFrame, stmt::Expr)
    head = stmt.head
    if head === :new || head === :splatnew
        return args_origins(fr, @view stmt.args[2:end])
    elseif head === :(=)
        o = stmt_origins(fr, stmt.args[2])
        lhs = as_globalref(stmt.args[1])
        if isa(lhs, GlobalRef)
            escape!(fr, o)
            binding_access!(fr, lhs.mod, lhs.name, true)
        end
        return o
    elseif head === :foreigncall
        return foreigncall!(fr, stmt)
    elseif head === :cfunction
        fr.precision = max(fr.precision, Partial)
        return no_origins
    elseif head === :invoke
        ci = stmt.args[1]
        mi = isa(ci, Core.CodeInstance) ? ci.def : ci
        isa(mi, Core.MethodInstance) || (mi = mi.def)
        return call!(fr, summarize(mi::Core.MethodInstance, fr.walk), stmt.args[2:end])
    elseif head === :invoke_modify
        return call_origins!(fr, Expr(:call, stmt.args[2:end]...))
    elseif head === :call
        return call_origins!(fr, stmt)
    end
    return no_origins
end

function call_origins!(fr::SummaryFrame{Nothing}, stmt::Expr)
    f = ir_value(fr.src, stmt.args[1])
    fv = f === nothing ? nothing : something(f)
    isa(fv, Core.Builtin) && return builtin!(fr, unpartitioned(fr.src, nameof(fv), stmt.args[2:end])...)
    return dynamic_call!(fr, stmt.args)
end

# A call resolved at run time: the union over all methods it may reach.
function dynamic_call!(fr::SummaryFrame, args::Vector{Any})
    src = fr.src
    ft = ir_type(src, args[1])
    known_type(ft) || return unknown!(fr, args)
    if ft in stream_functions && length(args) >= 2 && ir_type(src, args[2]) <: IO
        params = Any[ir_type(src, a) for a in args]
        return call!(fr, stream_summary(fr.walk, params, length(args), false), args)
    end
    sig = Tuple{ft, Any[ir_type(src, a) for a in args[2:end]]...}
    ms = known_signature(sig) ? Base._methods_by_ftype(sig, max_methods, fr.walk.world) : nothing
    ms === nothing && return unknown!(fr, args)
    o = no_origins
    for m in ms
        o = o ∪ call!(fr, summarize(dispatch_instance(m::Core.MethodMatch), fr.walk), args)
    end
    return o
end

# The method instance a dynamic call reaches through `match`: the specialization for the call,
# or, once the method has `max_specializations` others, the one for its declared signature.
function dispatch_instance(match::Core.MethodMatch)
    m = match.method
    mi = Core.Compiler.specialize_method(match)
    @lock summary_lock begin
        seen = get!(Vector{Core.MethodInstance}, specializations, m)
        any(x -> x === mi, seen) && return mi
        length(seen) < max_specializations && (push!(seen, mi); return mi)
    end
    return generic_instance(m)
end

# The method instance of `m` for its declared signature.
function generic_instance(m::Method)
    tvars = Any[]
    t = m.sig
    while isa(t, UnionAll)
        push!(tvars, t.var)
        t = t.body
    end
    return Core.Compiler.specialize_method(m, m.sig, Core.svec(tvars...))
end

# The indices of the arguments of a call with `n` arguments that the positions `mask` of `s`
# stand for.
function call_arg_indices(mask::UInt64, s::Summary, n::Int)
    idxs = Int[]
    for k in 1:64
        mask >> (k - 1) & 1 == 1 || continue
        if k == 64 || (s.isva && k == s.nargs)
            append!(idxs, k:n)
        elseif k <= n
            push!(idxs, k)
        end
    end
    return idxs
end

# Apply the summary `s` of a callee to a call with arguments `args`; return the origins of
# the result.
function call!(fr::SummaryFrame, s::Summary, args::Vector{Any})
    for i in call_arg_indices(s.mutated.args, s, length(args))
        mutate!(fr, origins(fr, args[i]))
    end
    mutate!(fr, Origins(0, bound_ids(fr, s, args, s.mutated.globals)))
    for i in call_arg_indices(s.escaped.args, s, length(args))
        escape!(fr, origins(fr, args[i]))
    end
    escape!(fr, Origins(0, bound_ids(fr, s, args, s.escaped.globals)))
    reads = bound_ids(fr, s, args, s.reads)
    append!(fr.reads, reads)
    any(<(0), reads) && (fr.hidden = true)
    append!(fr.assigned, bound_ids(fr, s, args, s.assigned))
    if !isempty(s.checks)
        append!(fr.checks, s.checks)
        append!(fr.walk.checks, s.checks)
    end
    fr.precision = max(fr.precision, s.precision)
    o = Origins(0, bound_ids(fr, s, args, s.returned.globals))
    idxs = call_arg_indices(s.returned.args, s, length(args))
    for i in idxs
        o = o ∪ origins(fr, args[i])
    end
    # A value the callee loads from an argument may be one stored there earlier.
    isempty(idxs) || (o = o ∪ fr.heap)
    return o
end

"""
    Revise.builtin!(fr::Revise.SummaryFrame, nm::Symbol, args::Vector{Any}) -> Revise.Origins

Record in `fr` the effects of a call of the builtin named `nm` with arguments `args`, and return the origins of its result.

A builtin that stores into memory mutates what its first argument reaches, and its result may
share memory with any argument and any value stored earlier. The function that `modifyfield!`
and its relatives call is not followed, which makes the summary `Partial`.

# Examples

```jldoctest; setup = :(using Revise)
julia> f(r, v) = (r[] = v);

julia> src = first(only(code_typed(f, (Base.RefValue{Vector{Int}}, Vector{Int}))));

julia> fr = Revise.analyze_frame(src, Revise.Walk()); args = Any[Core.Argument(2), QuoteNode(:x), Core.Argument(3)];

julia> Revise.argpositions(Revise.builtin!(fr, :setfield!, args)), Revise.argpositions(fr.mutated), fr.precision
([2, 3], [2], Revise.Exact)

julia> Revise.builtin!(fr, :modifyfield!, Any[args[1:2]; GlobalRef(Base, :+); args[3:3]]); fr.precision
Partial::Precision = 1
```
"""
function builtin!(fr::SummaryFrame, nm::Symbol, args::Vector{Any})
    nm in modifying_builtins && unknown!(fr, args)
    if nm in mutating_builtins
        mutate!(fr, origins(fr, args[1]))
        for a in args[2:end]
            escape!(fr, origins(fr, a))
        end
        return args_origins(fr, args) ∪ fr.heap
    elseif nm in global_writers
        m, s = binding_operand(fr, args[1]), binding_operand(fr, args[2])
        o = args_origins(fr, @view args[3:end])
        escape!(fr, o)
        binding_access!(fr, m, s, true)
        # `setglobal!` returns the value it assigns, the others the old value as well.
        if isa(m, Module) && isa(s, Symbol) && nm !== :setglobal! && nm !== :declare_const
            o = o ∪ global_origins(fr, GlobalRef(m, s))
        end
        return o
    elseif nm === :getglobal || nm === :getfield && frame_type(fr, args[1]) <: Module
        m, s = binding_operand(fr, args[1]), binding_operand(fr, args[2])
        isa(m, Module) && isa(s, Symbol) && return global_origins(fr, GlobalRef(m, s))
        id = binding_access!(fr, m, s, false)
        return isnothing(id) ? no_origins : Origins(0, [id])
    elseif (nm === :isdefinedglobal || nm === :isdefined) && length(args) >= 2 && frame_type(fr, args[1]) <: Module
        # Whether the global exists changes once a statement assigns it.
        binding_access!(fr, binding_operand(fr, args[1]), binding_operand(fr, args[2]), false)
        return no_origins
    elseif nm in calling_builtins
        return unknown!(fr, args)
    elseif nm in loading_builtins
        o = origins(fr, args[1])
        return nm === :memoryrefnew ? o : o ∪ fr.heap   # a load may return a value stored earlier
    end
    return args_origins(fr, args)
end

"""
    Revise.binding_access!(fr::Revise.SummaryFrame, m, s, write::Bool) -> Union{Nothing,Revise.GlobalId}

Record in `fr` that the code reads the global that the module `m` and the name `s` select, or assigns it if `write`, and return its id.

`m` and `s` are as for [`Revise.named_id`](@ref), which gives the id of a global that they do
not both know. Only globals of tracked modules count, else `nothing` is returned. Assigning a
global of an unknown module or name makes the summary `Partial`.

# Examples

```jldoctest; setup = :(using Revise)
julia> src = Meta.lower(Main, :(identity(1))).args[1];

julia> fr = Revise.analyze_frame(src, Revise.Walk(), Revise.LoweredStmt(src, Set{Tuple{Module,Symbol}}(), Dict{Tuple{Module,Symbol},Any}()));

julia> Revise.global_binding(Revise.binding_access!(fr, Main, :A, false))
(Main, :A)

julia> Revise.named_access(Revise.binding_access!(fr, 2, 3, false))
Revise.NamedAccess(2, 3)

julia> Revise.binding_access!(fr, nothing, :A, true); fr.precision === Revise.Partial
true
```
"""
function binding_access!(fr::SummaryFrame, @nospecialize(m), @nospecialize(s), write::Bool)
    id = access_id(fr, m, s)
    isnothing(id) && return nothing
    write && (isnothing(m) || isnothing(s)) && (fr.precision = max(fr.precision, Partial))
    push!(write ? fr.assigned : fr.reads, id)
    return id
end

# The id of the global that `m` and `s` select in the code of `fr`, or `nothing` if no tracked
# module owns it.
function access_id(fr::SummaryFrame, @nospecialize(m), @nospecialize(s))
    if isa(m, Module) && isa(s, Symbol)
        id = global_id(m, s)
        return tracked_global(fr.walk, id) ? id : nothing
    end
    isa(m, Module) && !in_tracked(m, fr.walk.tracked) && return nothing
    return named_id(m, s)
end

# The ids of the globals `ids` of the summary `s` of a callee, for a call with arguments `args`:
# a global that parameters select becomes the one the arguments select.
function bound_ids(fr::SummaryFrame, s::Summary, args::Vector{Any}, ids::Vector{GlobalId})
    (isempty(ids) || first(ids) > 0) && return ids
    out = GlobalId[]
    for id in ids
        if id > 0
            push!(out, id)
            continue
        end
        na = named_access(id)
        b = access_id(fr, call_operand(fr, s, args, na.mod), call_operand(fr, s, args, na.name))
        isnothing(b) || push!(out, b)
    end
    return sort!(unique!(out))
end

# The module or name that `x`, an argument in the optimized code of `fr`, holds: its value if
# constant, the position of the parameter if `x` is one, else `nothing`.
function binding_operand(fr::SummaryFrame{Nothing}, @nospecialize(x))
    v = ir_value(fr.src, x)
    isnothing(v) || return isa(something(v), Union{Module,Symbol}) ? something(v) : nothing
    return isa(x, Core.Argument) ? x.n : nothing
end

# The module or name that the parameter position or value `x` in the summary `s` of a callee
# stands for in a call with arguments `args`.
function call_operand(fr::SummaryFrame, s::Summary, args::Vector{Any}, @nospecialize(x))
    isa(x, Int) || return x
    s.isva && x >= s.nargs || x > length(args) ? nothing : binding_operand(fr, args[x])
end

# C functions that read the global a module and a name select, with the positions of these
# arguments. Position 0 stands for every name of the module.
const binding_ccalls = Dict{Symbol,Tuple{Int,Int}}(:jl_is_const => (1, 2), :jl_module_exports_p => (1, 2),
    :jl_module_public_p => (1, 2), :jl_is_binding_deprecated => (1, 2), :jl_get_module_of_binding => (1, 2),
    :jl_get_module_binding => (1, 2), :jl_module_names => (1, 0))

function foreigncall!(fr::SummaryFrame, stmt::Expr)
    name = ccall_name(stmt)
    cargs = stmt.args[6:end]
    query = isa(name, Symbol) ? get(binding_ccalls, name, nothing) : nothing
    if !isnothing(query)
        i, j = query
        m = i <= length(cargs) ? binding_operand(fr, cargs[i]) : nothing
        s = 0 < j <= length(cargs) ? binding_operand(fr, cargs[j]) : nothing
        id = binding_access!(fr, m, s, false)
        isnothing(id) || id > 0 || (fr.hidden = true)
        return no_origins
    elseif name === :jl_globalref_is_const && length(cargs) == 1
        g = ir_value(fr.src, cargs[1])
        gv = isnothing(g) ? nothing : something(g)
        isa(gv, GlobalRef) ? binding_access!(fr, gv.mod, gv.name, false) :
            (binding_access!(fr, nothing, nothing, false); fr.hidden = true)
        return no_origins
    end
    entry = isa(name, Symbol) ? get(ctable, name, nothing) : nothing
    if entry === nothing && isa(name, Symbol) && startswith(String(name), "llvm.") &&
            !any(a -> frame_type(fr, a) <: Ptr, cargs)
        entry = cwrites()   # an LLVM intrinsic without pointer arguments computes on values only
    end
    (isnothing(entry) || entry.kind === CUnknown) && return unknown!(fr, cargs)
    if entry.kind === CWrites
        for k in entry.writes
            k <= length(cargs) && mutate!(fr, origins(fr, cargs[k]))
        end
        for k in entry.flows
            k <= length(cargs) && escape!(fr, origins(fr, cargs[k]))
        end
        # The result may point into an argument, as for `jl_value_ptr`.
        return args_origins(fr, cargs)
    end
    return no_origins
end

function ccall_name(stmt::Expr)
    name = stmt.args[1]
    isa(name, QuoteNode) && (name = name.value)
    isexpr(name, :tuple) && (name = name.args[1])
    isa(name, QuoteNode) && (name = name.value)
    isa(name, Tuple) && (name = name[1])
    return name
end

# --- Code that cannot run in a Revise session.

# The value of `x` in `src` wrapped in `Some`, using the constants found so far. `consts` maps
# SSA ids to values, and the negated ids of local variables to their constant values.
function folded(src::CodeInfo, consts::Dict{Int,Any}, @nospecialize(x))
    if isa(x, Core.SSAValue)
        haskey(consts, x.id) && return Some{Any}(consts[x.id])
        st = as_globalref(src.code[x.id])
        isa(st, Union{GlobalRef,QuoteNode}) && return ir_value(src, st)
        isa(st, Core.SlotNumber) && return folded(src, consts, st)
    end
    isa(x, Core.SlotNumber) && return haskey(consts, -x.id) ? Some{Any}(consts[-x.id]) : nothing
    return ir_value(src, x)
end

function fold_call(src::CodeInfo, consts::Dict{Int,Any}, stmt::Expr)
    f = folded(src, consts, stmt.args[1])
    f === nothing && return nothing
    fv = something(f)
    @static if isdefined(Base, :generating_output)
        fv === Base.generating_output && length(stmt.args) == 1 && return Some{Any}(false)
    end
    pure = isa(fv, Core.IntrinsicFunction) || fv === (===) || fv === Core.isa
    pure || fv === (==) || fv === (!=) || fv === (!) || return nothing
    args = Any[]
    for a in stmt.args[2:end]
        v = folded(src, consts, a)
        v === nothing && return nothing
        push!(args, something(v))
    end
    pure || all(a -> isa(a, Number), args) || return nothing
    return try
        Some{Any}(fv(args...))
    catch err
        isa(err, Union{ErrorException,TypeError,MethodError}) || rethrow()
        nothing
    end
end

"""
    Revise.reachable(src::CodeInfo, assumed=nothing, checks=Revise.CallCheck[]; refs=true) -> Tuple{BitVector,Dict{Int,Any}}

Return which statements of `src` can run in a Revise session, and the constants found.

In a session, `jl_generating_output` returns 0, and a branch on a constant takes one side only.
With `assumed` (see [`Revise.assumed_value`](@ref)), a condition also folds on `const` globals,
on calls that only test `jl_generating_output` (see [`Revise.generating_output_value`](@ref)), on
the contents of a `Ref` in a `const` global unless `refs` is `false`, and on local variables that
every live assignment gives one constant. These values are recorded in `assumed` and the method
lookups in `checks`, so that a change triggers a new analysis.

# Examples

```jldoctest; setup = :(using Revise)
julia> const FLAG = Ref(false); gen() = ccall(:jl_generating_output, Cint, ()) == 1;

julia> src = Meta.lower(@__MODULE__, :(if gen() && FLAG[] || FLAG[]; push!(LOG, 1); end)).args[1];

julia> runs_push(live) = any(i -> live[i] && occursin("push!", string(src.code[i])), eachindex(src.code));

julia> assumed = Dict{Tuple{Module,Symbol},Any}(); runs_push(first(Revise.reachable(src, assumed)))
false

julia> assumed[(@__MODULE__, :FLAG)].value, runs_push(first(Revise.reachable(src)))
(false, true)

julia> runs_push(first(Revise.reachable(src, Dict{Tuple{Module,Symbol},Any}(); refs=false)))
true
```
"""
function reachable(src::CodeInfo, assumed::Union{Nothing,Dict{Tuple{Module,Symbol},Any}}=nothing,
                   checks::Vector{CallCheck}=CallCheck[]; refs::Bool=true)
    consts = Dict{Int,Any}()
    for (i, st) in enumerate(src.code)
        if isexpr(st, :foreigncall) && ccall_name(st) === :jl_generating_output
            consts[i] = Int32(0)
        elseif isexpr(st, :call)
            v = fold_call(src, consts, st)
            v === nothing || (consts[i] = something(v))
        end
    end
    live = live_statements(src, consts, assumed, checks, refs)
    isnothing(assumed) && return live, consts
    for _ in 1:3
        values, unknown = Dict{Int,Any}(), BitSet()
        for (i, st) in enumerate(src.code)
            live[i] && isexpr(st, :(=), 2) && isa(st.args[1], Core.SlotNumber) || continue
            id = (st.args[1]::Core.SlotNumber).id
            v = folded(src, consts, st.args[2])
            if v === nothing || haskey(values, id) && values[id] !== something(v)
                push!(unknown, id)
            else
                values[id] = something(v)
            end
        end
        changed = false
        for (id, v) in values
            id in unknown || haskey(consts, -id) || (consts[-id] = v; changed = true)
        end
        changed || break
        live = live_statements(src, consts, assumed, checks, refs)
    end
    return live, consts
end

function live_statements(src::CodeInfo, consts::Dict{Int,Any}, assumed, checks::Vector{CallCheck}, refs::Bool)
    n = length(src.code)
    live = falses(n)
    work = [1]
    while !isempty(work)
        i = pop!(work)
        1 <= i <= n && !live[i] || continue
        live[i] = true
        st = src.code[i]
        if isa(st, Core.GotoNode)
            push!(work, st.label)
        elseif isa(st, Core.GotoIfNot)
            c = isnothing(assumed) ? folded(src, consts, st.cond) : fold_condition!(src, consts, st.cond, assumed, checks; refs)
            (c === nothing || something(c) !== false) && push!(work, i + 1)
            (c === nothing || something(c) !== true) && push!(work, st.dest)
        elseif isa(st, Core.ReturnNode)
        elseif isa(st, Core.EnterNode)
            push!(work, i + 1)
            st.catch_dest == 0 || push!(work, st.catch_dest)
        else
            push!(work, i + 1)
        end
    end
    return live
end

"""
    Revise.fold_condition!(src::CodeInfo, consts, x, assumed, checks; refs=true) -> Union{Nothing,Some}

Return the value of `x`, an argument in the top-level code `src`, wrapped in `Some` if [`Revise.reachable`](@ref) can fold it with `assumed`, else `nothing`.

The value of an SSA value is stored in `consts`, the values relied on in `assumed`, and the
method lookups in `checks`. The contents of a `Ref` are used only if `refs` is `true`.

# Examples

```jldoctest; setup = :(using Revise)
julia> const FLAGS = Ref(true); src = Meta.lower(@__MODULE__, :(!FLAGS[])).args[1]; x = Core.SSAValue(length(src.code) - 1);

julia> fold(assumed; refs=true) = Revise.fold_condition!(src, Dict{Int,Any}(), x, assumed, Revise.CallCheck[]; refs);

julia> fold(Dict{Tuple{Module,Symbol},Any}()), fold(nothing), fold(Dict{Tuple{Module,Symbol},Any}(); refs=false)
(Some(false), nothing, nothing)
```
"""
function fold_condition!(src::CodeInfo, consts::Dict{Int,Any}, @nospecialize(x), assumed, checks::Vector{CallCheck};
                         refs::Bool=true)
    v = folded(src, consts, x)
    (v === nothing && !isnothing(assumed) && isa(x, Core.SSAValue)) || return v
    st = src.code[x.id]
    isexpr(st, :call) || return nothing
    b = resolve_binding(src, x)
    if !isnothing(b)
        v = const_value!(assumed, b)
    else
        f = fold_condition!(src, consts, st.args[1], assumed, checks; refs)
        f === nothing && return nothing
        fv = something(f)
        if length(st.args) == 1
            v = generating_output_value(fv, checks)
        elseif fv === getindex && length(st.args) == 2
            r = resolve_binding(src, st.args[2])
            v = isnothing(r) || !refs ? nothing : const_value!(assumed, r)
            if !isnothing(v) && isa(something(v), Base.RefValue)
                ref = something(v)::Base.RefValue
                assume!(assumed, (binding_owner(r...), r[2]), RefContents(ref, ref[]))
                v = Some{Any}(ref[])
            else
                v = nothing
            end
        else
            for a in @view st.args[2:end]
                fold_condition!(src, consts, a, assumed, checks; refs)
            end
            v = fold_call(src, consts, st)
        end
    end
    v === nothing || (consts[x.id] = something(v))
    return v
end

# The value of the `const` global `b` wrapped in `Some`, recorded in `assumed`, or `nothing`.
function const_value!(assumed::Dict{Tuple{Module,Symbol},Any}, b::Tuple{Module,Symbol})
    m, s = binding_owner(b...), b[2]
    @invokelatest(isdefinedglobal(m, s)) && @invokelatest(isconst(m, s)) || return nothing
    val = @invokelatest getglobal(m, s)
    assume!(assumed, (m, s), val)
    return Some{Any}(val)
end

"""
    Revise.generating_output_value(f, checks::Vector{Revise.CallCheck}) -> Union{Nothing,Some}

Return what a call of `f` without arguments returns in a Revise session, wrapped in `Some`, if its method computes it from `jl_generating_output` alone, else `nothing`.

A package may wrap the test whether it is being precompiled into such a function. The method
lookup is recorded in `checks` if the value is known.

# Examples

```jldoctest; setup = :(using Revise)
julia> precompiling() = ccall(:jl_generating_output, Cint, ()) == 1; other() = true;

julia> checks = Revise.CallCheck[]; Revise.generating_output_value(precompiling, checks), length(checks)
(Some(false), 1)

julia> Revise.generating_output_value(other, checks), Revise.generating_output_value(+, checks)
(nothing, nothing)
```
"""
function generating_output_value(@nospecialize(f), checks::Vector{CallCheck})
    isa(f, Function) && !isa(f, Core.Builtin) || return nothing
    c = method_check(Tuple{Core.Typeof(f)})
    length(c.methods) == 1 || return nothing
    src = lowered_code(only(c.methods))
    isnothing(src) && return nothing
    any(st -> isexpr(st, :foreigncall) && ccall_name(st) === :jl_generating_output, src.code) || return nothing
    live, consts = reachable(src)
    val = nothing
    for (i, st) in enumerate(src.code)
        live[i] && isa(st, Core.ReturnNode) && isdefined(st, :val) || continue
        v = folded(src, consts, st.val)
        (v === nothing || !isnothing(val) && something(val) !== something(v)) && return nothing
        val = v
    end
    isnothing(val) || push!(checks, c)
    return val
end

# Whether the lowered code `src` does nothing in a Revise session, because all its work is
# guarded by `jl_generating_output`.
function guarded_out(src::CodeInfo)
    any(st -> isexpr(st, :foreigncall) && ccall_name(st) === :jl_generating_output, src.code) || return false
    live, consts = reachable(src)
    for (i, st) in enumerate(src.code)
        (!live[i] || haskey(consts, i)) && continue
        isa(st, Union{Core.GotoNode,Core.GotoIfNot,Core.ReturnNode,Core.NewvarNode,LineNumberNode,GlobalRef,Nothing}) &&
            continue
        isexpr(st, :foreigncall) && ccall_name(st) === :jl_generating_output && continue
        isexpr(st, :meta) && continue
        return false
    end
    return true
end
