Base.Experimental.@optlevel 1

using FileWatching, REPL, UUIDs
using LibGit2: LibGit2
using CRC32c: crc32c
using Base: PkgId, IdSet
using Base.Meta: isexpr
using Core: CodeInfo, MethodTable

if !isdefined(Core, :isdefinedglobal)
    isdefinedglobal(m::Module, s::Symbol) = isdefined(m, s)
end

export revise, includet, @includet, entr, MethodSummary

## BEGIN abstract Distributed API

# Abstract type to represent a single worker
abstract type AbstractWorker end

# Wrapper struct to indicate a worker belonging to the Distributed stdlib. Other
# libraries should make their own type that subtypes AbstractWorker for Revise
# to dispatch on.
struct DistributedWorker <: AbstractWorker
    id::Int
end

# This is a list of functions that will retrieve a list of workers
const workers_functions = Base.Callable[]

# A distributed worker library wanting to use Revise should register their
# workers() function with this.
function register_workers_function(f::Base.Callable)
    push!(workers_functions, f)
    nothing
end

# The library should implement this method such that it behaves like
# Distributed.remotecall().
function remotecall_impl end

# The library should implement two methods for this function:
# - is_master_worker(::typeof(my_workers_function)): check if the current
#   process is the master.
# - is_master_worker(w::MyWorkerType): check if `w` is the master.
function is_master_worker end

# Ordered record of the revision actions applied on the master this session, each
# stored as `(mod, expr)` meaning "evaluate `expr` in `mod`". Revisions are
# normally pushed to the workers that exist at revision time, but a worker added
# *later* loads the package fresh from disk and would otherwise miss them; in
# particular it would lack the freshly-gensym'd closures that `@distributed`
# bodies serialize, giving an `UndefVarError` on deserialization (issue #637).
# `init_worker` replays this log to bring such a worker up to date. Reads and
# writes both go through `revise_lock` (see `record_worker_replay!` and
# `init_worker`). Only populated while a Distributed-like library is loaded and
# this process is the master, so non-distributed sessions pay nothing.
const worker_replay_log = Tuple{Module,Any}[]

# Record `(mod, expr)` for later replay onto workers added after this revision,
# but only when this process is the master for some registered worker library.
# Takes `revise_lock` directly: on the normal `revise` path the caller already
# holds it (a reentrant re-acquire is cheap), and this also covers the side paths
# (`revise_file_now`, `eval_revised`) that reach here without holding it.
function record_worker_replay!(mod::Module, expr)
    @lock revise_lock for get_workers in workers_functions
        if @invokelatest is_master_worker(get_workers)
            push!(worker_replay_log, (mod, expr))
            break
        end
    end
    return nothing
end

# Evaluate `expr` in `mod` on worker `p`, ignoring failures (e.g. `mod` not yet
# loaded there, or a type the expression references being absent).
function apply_worker_action(p, mod::Module, expr)
    try
        @invokelatest remotecall_impl(Core.eval, p, mod, expr)
    catch
    end
    return nothing
end

## END abstract Distributed API

"""
    Revise.active[]

If `false`, Revise will stop updating code.
"""
const active = Ref(true)

"""
    Revise.watching_files[]

Returns `true` if we watch files rather than their containing directory.
FreeBSD and NFS-mounted systems should watch files, otherwise we prefer to watch
directories.
"""
const watching_files = Ref(Sys.KERNEL === :FreeBSD)

"""
    Revise.polling_files[]

Returns `true` if we should poll the filesystem for changes to the files that define
loaded code. It is preferable to avoid polling, instead relying on operating system
notifications via `FileWatching.watch_file`. However, NFS-mounted
filesystems (and perhaps others) do not support file-watching, so for code stored
on such filesystems you should turn polling on.

See the documentation for the `JULIA_REVISE_POLL` environment variable.
"""
const polling_files = Ref(false)

# Some filesystems accept `watch_file`/`watch_dir` calls but never deliver a
# notification, so the watch silently blocks forever. The motivating case is the
# Windows filesystem mounted into WSL under `/mnt/...` (a `drvfs`/`9p` mount):
# inotify is broken there but `stat`-based polling works (issue #514). On such
# paths Revise must poll regardless of the global `polling_files[]` setting.

const _is_wsl = Ref{Union{Nothing,Bool}}(nothing)
# Are we running under the Windows Subsystem for Linux? Cached after the first call.
function is_wsl()
    cached = _is_wsl[]
    cached === nothing || return cached
    wsl = false
    if Sys.islinux()
        try
            wsl = occursin(r"microsoft|WSL"i, read("/proc/sys/kernel/osrelease", String))
        catch
            wsl = false
        end
    end
    return _is_wsl[] = wsl
end

# `/proc/mounts` encodes spaces, tabs, etc. in mount points as octal escapes.
function unescape_mount(s::AbstractString)
    occursin('\\', s) || return s
    return replace(s, r"\\([0-7]{3})" => m -> string(Char(parse(UInt8, m[2:end]; base=8))))
end

# Is `prefix` a path-component prefix of `path`? (`/mnt` is a prefix of `/mnt/c`
# but not of `/mnts`.)
function is_path_prefix(prefix::AbstractString, path::AbstractString)
    prefix == path && return true
    prefix == "/" && return startswith(path, "/")
    return startswith(path, prefix * "/")
end

# Filesystem type for the most specific mount point containing `path`, given the
# lines of a `/proc/mounts`-format table. Returns "" if none matches.
function fstype_for_path(path::AbstractString, mount_lines)
    apath = abspath(path)
    best_mount = best_fstype = ""
    for line in mount_lines
        fields = split(line)
        length(fields) >= 3 || continue
        mountpoint = unescape_mount(fields[2])
        if is_path_prefix(mountpoint, apath) && length(mountpoint) >= length(best_mount)
            best_mount, best_fstype = mountpoint, fields[3]
        end
    end
    return best_fstype
end

mount_fstype(path::AbstractString) =
    fstype_for_path(path, try eachline("/proc/mounts") catch; () end)

# Does `path` live on a filesystem that accepts file-watching calls but never
# delivers change notifications, so that Revise must poll instead? The motivating
# case is the Windows filesystem mounted into WSL (a `drvfs`/`9p` mount); see issue
# #514. Only Linux's `/proc/mounts` is consulted, so the result is `false` on every
# other platform.
function nonnotifying_path(path::AbstractString)
    is_wsl() || return false
    fstype = mount_fstype(path)
    return fstype == "9p" || fstype == "drvfs"
end

function wait_changed(file)
    poll = polling_files[] || nonnotifying_path(file)
    try
        poll ? poll_file(file) : watch_file(file)
    catch err
        if Sys.islinux() && err isa Base.IOError && err.code == -28  # ENOSPC; issue #1010
            @warn """Revise was unable to watch files for changes via inotify (ENOSPC).
            This can happen because:
            - the filesystem does not support inotify (e.g., a WSL `/mnt/...` drive or
              some network mounts);
            - a per-user-namespace limit is in effect (common inside containers,
              snaps, or Flatpaks), in which case `cat /proc/sys/fs/inotify/max_user_watches`
              may report a large value that is not the limit actually enforced;
            - the per-user `max_user_watches` limit is genuinely exhausted.
            As a workaround, set the environment variable `JULIA_REVISE_POLL=1` before
            `using Revise` to poll the filesystem instead of using inotify.
            If `max_user_watches` is genuinely the cause, raise it with, e.g.,
            `echo 65536 | sudo tee /proc/sys/fs/inotify/max_user_watches` (administrative
            privileges required).
            See https://github.com/timholy/Revise.jl/issues/26 for more information.""" maxlog=1
        end
        rethrow(err)
    end
    return nothing
end

"""
    Revise.tracking_Main_includes[]

Returns `true` if files directly included from the REPL should be tracked.
The default is `false`. See the documentation regarding the `JULIA_REVISE_INCLUDE`
environment variable to customize it.
"""
const tracking_Main_includes = Ref(false)

include("relocatable_exprs.jl")
include("types.jl")
include("utils.jl")
include("parsing.jl")
include("lowered.jl")
include("loading.jl")
include("visit.jl")
include("pkgs.jl")
include("stale_load.jl")
include("git.jl")
include("recipes.jl")
include("logging.jl")
include("callbacks.jl")

### Globals to keep track of state

# All of Revise's mutable global state (the dictionaries, sets, and vectors
# defined below) is protected by a single coarse lock. A coarse lock is used
# because these structures are interdependent and are touched from several
# threads: the REPL/interactive thread (via `revise`), the package-load callback
# (`watch_package`, which since Julia 1.12 can run on a background thread when
# `require` finishes there), and the file/manifest-watcher tasks. Earlier
# per-structure locks did not compose, so a reader on one thread could observe a
# dictionary mid-rehash while a writer on another thread mutated it, which
# segfaults.
#
# The lock is a `ReentrantLock`, so nested acquisitions on the same task are
# fine. It is held only around state access, with one deliberate exception:
# `revise` holds it across evaluation of revised code to serialize concurrent
# revisions, as it always has (see issues #837 and #845). It must NOT be held
# across a blocking `wait`/`sleep`; the watcher tasks therefore acquire it only
# to enqueue work, never while waiting for filesystem events.
#
# Guards: `watched_files`, `watched_manifests`, `revision_queue`, `queue_errors`,
# `pkgdatas`, `included_files`, `cache_file_key`, `src_file_key`,
# `dont_watch_pkgs`, `silence_pkgs`, `worker_replay_log`, the `user_callbacks_*`
# collections, and the `@require` bookkeeping. (`types_cache` in visit.jl has its
# own independent lock, on a separate code path.)
const revise_lock = ReentrantLock()

"""
    Revise.watched_files

Global variable, `watched_files[dirname]` returns the collection of files in `dirname`
that we're monitoring for changes. The returned value has type [`Revise.WatchList`](@ref).

This variable allows us to watch directories rather than files, reducing the burden on
the OS.
"""
const watched_files = Dict{String,WatchList}()

"""
    Revise.watched_manifests

Global variable, a set of `Manifest.toml` files from the active projects used during this session.
"""
const watched_manifests = Set{String}()

"""
    Revise.revision_queue

Global variable, `revision_queue` holds `(pkgdata,filename)` pairs that we need to revise, meaning
that these files have changed since we last processed a revision.
This list gets populated by callbacks that watch directories for updates.
"""
const revision_queue = Set{Tuple{PkgData,String}}()

"""
    Revise.queue_errors

Global variable, maps `(pkgdata, filename)` pairs that errored upon last revision to
`(exception, backtrace)`.
"""
const queue_errors = Dict{Tuple{PkgData,String},Tuple{Exception, Any}}() # locking is covered by revise_lock

"""
    Revise.duplicated_signatures

Global variable, maps each method signature currently defined in more than one place
within a precompilable package to the list of `LineNumberNode`s where it is defined.
Such duplicates evaluate successfully in the running session but cause the next
precompilation to fail with "Method overwriting is not permitted during Module
precompilation". See [`Revise.duplicate_methods`](@ref). Locking is covered by `revise_lock`.
"""
const duplicated_signatures = Dict{MethodInfoKey,Vector{LineNumberNode}}()

"""
    Revise.missing_file_grace

A tracked file can be missing transiently: code generators often delete a whole
directory of sources and rewrite it over several seconds, and an editor's
atomic-rename save passes through a deleted state. Deleting the file's methods
at the first `revise()` that lands in such a window would be destructive, so a
missing file is instead kept on [`Revise.revision_queue`](@ref) and revisited:
only if it is still missing `missing_file_grace[]` seconds (default: 5.0) after
first being noticed does `revise` delete its methods. Set this to `Inf` if
sources are regenerated by a slow external process, or to `0.0` to delete
methods immediately.

Locking is covered by `revise_lock`.
"""
const missing_file_grace = Ref(5.0)

# When a queued file is missing at revision time, records when `revise` first
# noticed the absence; the entry is removed when the file reappears. Locking is
# covered by `revise_lock`.
const missing_file_times = Dict{Tuple{PkgData,String},Float64}()

# Can we revise types? This is assigned in __init__() based on the Julia version
# and preference.
const __bpart__ = Ref(false)

"""
    Revise.NOPACKAGE

Global variable; default `PkgId` used for files which do not belong to any
package, but still have to be watched because user callbacks have been
registered for them.
"""
const NOPACKAGE = PkgId(nothing, "")

"""
    Revise.pkgdatas

`pkgdatas` is the core information that tracks the relationship between source code
and julia objects, and allows re-evaluation of code in the proper module scope.
It is a dictionary indexed by PkgId:
`pkgdatas[id]` returns a value of type [`Revise.PkgData`](@ref).
"""
const pkgdatas = Dict{PkgId,PkgData}(NOPACKAGE => PkgData(NOPACKAGE))

# Accessors that take `revise_lock` for the duration of a single `pkgdatas`
# operation. Use these (rather than touching `pkgdatas` directly) anywhere that
# might run concurrently with package loading, so a read never observes the
# dictionary mid-rehash. They release the lock before returning, so the result
# may be stale by the time it is used; any authoritative read-modify-write must
# happen inside its own `@lock revise_lock` block.
getpkgdata(id::PkgId) = @lock revise_lock get(pkgdatas, id, nothing)
haspkgdata(id::PkgId) = @lock revise_lock haskey(pkgdatas, id)
allpkgdatas() = @lock revise_lock collect(values(pkgdatas))

"""
    Revise.included_files

Global variable, `included_files` gets populated by callbacks we register with `include`.
It's used to track non-precompiled packages and, optionally, user scripts (see docs on
`JULIA_REVISE_INCLUDE`).
"""
const included_files = Tuple{Module,String}[]  # (module, filename); see issue #947

"""
    expected_juliadir()

This is the path where we ordinarily expect to find a copy of the julia source files,
as well as the source cache. For `juliadir` we additionally search some fallback
locations to handle various corrupt and incomplete installations.
"""
expected_juliadir() = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")

"""
    Revise.basesrccache

Full path to the running Julia's cache of source code defining `Base`.
"""
global basesrccache::String

"""
    Revise.basebuilddir

Julia's top-level directory when Julia was built, as recorded by the entries in
`Base._included_files`.
"""
global basebuilddir::String

# issue #835: compute at run time so this reflects the running Julia, not the Julia
# that precompiled Revise (the two can differ for relocated/cache-compatible installs)
function find_basebuilddir()
    # issue #1045: non-incremental PackageCompiler sysimages have no sysimg.jl entry
    idx = findfirst(x -> endswith(x[2], "sysimg.jl"), Base._included_files)
    idx === nothing ? expected_juliadir() : dirname(dirname(Base._included_files[idx][2]))
end

function fallback_juliadir(candidate = expected_juliadir())
    if !isdir(joinpath(candidate, "base"))
        while true
            trydir = joinpath(candidate, "base")
            isdir(trydir) && break
            trydir = joinpath(candidate, "share", "julia", "base")
            if isdir(trydir)
                candidate = joinpath(candidate, "share", "julia")
                break
            end
            next_candidate = dirname(candidate)
            next_candidate == candidate && break
            candidate = next_candidate
        end
    end
    normpath(candidate)
end

# issue #717: point users at their actual depot. Stale caches are written to
# the first depot entry, which honors a custom DEPOT_PATH rather than ~/.julia.
function revise_cache_dir()
    major, minor = Base.VERSION.major, Base.VERSION.minor
    depot = isempty(DEPOT_PATH) ? joinpath(homedir(), ".julia") : first(DEPOT_PATH)
    return joinpath(depot, "compiled", "v$major.$minor", "Revise")
end

function find_juliadir()
    candidate = expected_juliadir()
    isdir(candidate) && return normpath(candidate)
    # Couldn't find julia dir in the expected place.
    # Let's look in the source build also - it's possible that the Makefile didn't
    # set up the symlinks.
    # N.B.: We need to make sure here that the julia we're running is actually
    # the one being built. It's very common on buildbots that the original build
    # dir exists, but is a different julia that is currently being built.
    if Sys.BINDIR == joinpath(basebuilddir, "usr", "bin")
        return normpath(basebuilddir)
    end

    @warn "Unable to find julia source directory in the expected places.\n
           Looking in fallback locations. If this happens on a non-development build, please file an issue."
    return fallback_juliadir(candidate)
end

"""
    Revise.juliadir

Constant specifying full path to julia top-level source directory.
This should be reliable even for local builds, cross-builds, and binary installs.
"""
global juliadir::String

const cache_file_key = Dict{String,String}() # corrected=>uncorrected filenames
const src_file_key   = Dict{String,String}() # uncorrected=>corrected filenames

"""
    Revise.dont_watch_pkgs

Global variable containing the set of packages that Revise will not track.

!!! warning "Deprecated as of Revise 3.13"
    Direct modification of `dont_watch_pkgs` (e.g., `push!(Revise.dont_watch_pkgs, :PkgName)`)
    is deprecated and may be removed in a future release.
    Use [`Revise.dont_watch`](@ref) and [`Revise.allow_watch`](@ref) instead,
    which also persist your settings across Julia sessions via Preferences.jl.

See also [`Revise.silence`](@ref).
"""
const dont_watch_pkgs = Set{Symbol}()
const silence_pkgs = Set{String}()

# Revise pins its OWN method dispatch to the world age captured at `__init__` (`worldage[]`),
# so that revising a method Revise itself calls (e.g. via `track(Base)`) cannot invalidate
# Revise's machinery mid-operation (issue #552). User code is still evaluated at the latest
# world: JuliaInterpreter threads the latest world through each `Frame`. `worldage[]` is
# `nothing` until `__init__` runs, in which case `frozen` degrades to a plain call.
const worldage = Ref{Union{Nothing,UInt}}(nothing)

@inline function frozen(f, args...; kwargs...)
    w = worldage[]
    return w === nothing ? f(args...; kwargs...) : Base.invoke_in_world(w, f, args...; kwargs...)
end

"""
    Revise.advance_world!()

Re-pin Revise's own method dispatch to the current world age. Revise calls this once during
`__init__`; thereafter it stays fixed, so in ordinary use Revise runs at the world it froze at
initialization and is unaffected by later (re)definitions. Call this manually only after
deliberately revising Revise itself or one of its dependencies (CodeTracking, JuliaInterpreter,
LoweredCodeUtils, OrderedCollections), to make those changes take effect in Revise's machinery.
"""
advance_world!() = (worldage[] = Base.get_world_counter(); nothing)

function collect_mis(sigs)
    mis = Core.MethodInstance[]
    world = Base.get_world_counter()
    for tt in sigs
        matches = Base._methods_by_ftype(tt, 10, world)::Vector
        for mm in matches
            m = mm.method
            for mi in Base.specializations(m)
                if mi.specTypes <: tt
                    push!(mis, mi)
                end
            end
        end
    end
    return mis
end

##
## The inputs are sets of expressions found in each file.
## Some of those expressions will generate methods which are identified via their signatures.
## From "old" expressions we know their corresponding signatures, but from "new"
## expressions we have not yet computed them. This makes old and new asymmetric.
##
## Strategy:
## - For every old expr not found in the new ones,
##     + delete the corresponding methods (using the signatures we've previously computed)
##     + remove the sig entries from CodeTracking.method_info
##   Best to do all the deletion first (across all files and modules) in case a method is
##   simply being moved from one file to another.
## - For every new expr found among the old ones,
##     + update the location info in CodeTracking.method_info
## - For every new expr not found in the old ones,
##     + eval the expr
##     + extract signatures
##     + add to the ModuleExprsInfos
##     + add to CodeTracking.method_info
##
## Interestingly, the ex=>mt_sigs link may not be the same as the mt_sigs=>ex link.
## Consider a conditional block,
##     if Sys.islinux()
##         f() = 1
##         g() = 2
##     else
##         g() = 3
##     end
## From the standpoint of Revise's diff-and-patch functionality, we should look for
## diffs in this entire block. (Really good backedge support---or a variant of `lower` that
## links back to the specific expression---might change this, but for
## now this is the right strategy.) From the standpoint of CodeTracking, we should
## link the signature to the actual method-defining expression (either :(f() = 1) or :(g() = 2)).

# TODO
# - Correct evaluation order (type & method rewrite at the same time)
# - Simplify type matching algorithm

function delete_missing!(
        exs_infos_old::ExprsInfos, exs_infos_new::ExprsInfos,
        reeval_list::IdSet{Union{Method,Type}}, handled_types::IdSet{Type}, world::UInt,
        predictions::TypePredictions = TypePredictions(),
    )
    with_logger(_debug_logger) do
        for (rex, exinfos) in exs_infos_old
            haskey(exs_infos_new, rex) && continue
            # ex was deleted
            exinfos === nothing && continue
            for exinfo in exinfos
                if exinfo isa SigInfo
                    # Method deletions are never skipped on the strength of a
                    # prediction: a textually identical signature may dispatch on a
                    # type that is itself being redefined, in which case the new
                    # method is distinct from the old one and the old one must go.
                    handle_method_deletion!(exinfo, rex, world)
                elseif __bpart__[]
                    typeinfo = exinfo::TypeInfo
                    oldtype = prediction_preserves_type(predictions, typeinfo, world)
                    if oldtype !== nothing
                        # The new source redefines this type equivalently, so
                        # evaluation will keep the existing binding and the
                        # subtype-tree walk is unnecessary (issue #1022). The
                        # prediction is re-checked after evaluation; see `revise`.
                        push!(predictions.skipped, (typeinfo, oldtype))
                        continue
                    end
                    handle_type_deletion!(typeinfo, reeval_list, handled_types, world)
                end
            end
        end
    end
    return exs_infos_old
end

# Return the existing type when `predictions` says the new code redefines
# `typeinfo`'s type equivalently (so its deletion walk can be skipped), else `nothing`.
function prediction_preserves_type(predictions::TypePredictions, typeinfo::TypeInfo, world::UInt)
    tn = typeinfo.typname
    get(predictions.preserved, (tn.module, tn.name), false) || return nothing
    Base.invoke_in_world(world, isdefinedglobal, tn.module, tn.name) || return nothing
    existing = Base.invoke_in_world(world, getglobal, tn.module, tn.name)
    existing isa Type || return nothing
    return existing
end

const empty_exs_infos = ExprsInfos()
function delete_missing!(
        mod_exs_infos_old::ModuleExprsInfos, mod_exs_infos_new::ModuleExprsInfos,
        reeval_list::IdSet{Union{Method,Type}}, handled_types::IdSet{Type}, world::UInt,
        predictions::TypePredictions = TypePredictions(),
    )
    for (mod, exs_infos_old) in mod_exs_infos_old
        exs_infos_new = get(mod_exs_infos_new, mod, empty_exs_infos)
        delete_missing!(exs_infos_old, exs_infos_new, reeval_list, handled_types, world, predictions)
    end
    return mod_exs_infos_old
end

# `true` if diffing old against new will delete at least one expression that defined
# a type. This gates the prediction pass: when no type deletion is pending, there is
# nothing for a prediction to save.
function has_pending_type_deletion(mod_exs_infos_new::ModuleExprsInfos, mod_exs_infos_old::ModuleExprsInfos)
    for (mod, exs_infos_old) in mod_exs_infos_old
        exs_infos_new = get(mod_exs_infos_new, mod, empty_exs_infos)
        for (rex, exinfos) in exs_infos_old
            haskey(exs_infos_new, rex) && continue
            exinfos === nothing && continue
            any(exinfo -> exinfo isa TypeInfo, exinfos) && return true
        end
    end
    return false
end
has_pending_type_deletion(@nospecialize(mod_exs_infos_new), mod_exs_infos_old::ModuleExprsInfos) = false

# Run the type-preservation prediction over every expression the evaluation phase
# will (re)evaluate, i.e., the new rexes. Best-effort: any error leaves the affected
# types unpredicted, keeping the pessimistic deletion path in force.
function predict_changes!(
        predictions::TypePredictions,
        mod_exs_infos_new::ModuleExprsInfos, mod_exs_infos_old::ModuleExprsInfos,
    )
    for (mod, exs_infos_new) in mod_exs_infos_new
        exs_infos_old = get(mod_exs_infos_old, mod, empty_exs_infos)
        for rex in keys(exs_infos_new)
            haskey(exs_infos_old, rex) && continue
            ex = rex.ex
            try
                predict_typebodies!(predictions, mod, ex)
            catch err
                isa(err, InterruptException) && rethrow(err)
                @debug "PredictFailed" _group="Action" time=time() deltainfo=(mod, ex, err)
            end
        end
    end
    return predictions
end

function handle_method_deletion!(siginfo::SigInfo, rex::RelocatableExpr, world::UInt)
    mt, sig = siginfo
    ret = Base._methods_by_ftype(sig, mt, -1, world)
    isempty(ret) && return nothing
    m = ret[end].method  # the last method returned is the least-specific that matches, and thus most likely to be type-equal
    methsig = m.sig
    if sig <: methsig && methsig <: sig
        locdefs = get(CodeTracking.method_info, MethodInfoKey(siginfo), nothing)
        if isa(locdefs, Vector{Tuple{LineNumberNode,Expr}})
            if length(locdefs) > 1
                # Just delete this reference but keep the method
                line = firstline(rex)
                ld = map(pr->linediff(line, pr[1]), locdefs)
                idx = argmin(ld)
                if ld[idx] === typemax(eltype(ld))
                    # No `locdefs` entry shares a file with `rex`. This happens when the
                    # method's recorded location comes from a macro rather than the source
                    # file (e.g. `@views @timing function ... end`), so line matching can't
                    # identify the reference to drop. Drop the last one, matching `eval_rex`. (#668)
                    idx = length(locdefs)
                end
                deleteat!(locdefs, idx)
                return nothing
            else
                @assert length(locdefs) == 1
            end
        end
        @debug "DeleteMethod" _group="Action" time=time() deltainfo=(sig, MethodSummary(m))
        # Delete the corresponding methods
        let delexpr = :(delete_method_by_sig($mt, $sig))
            record_worker_replay!(Main, delexpr)
            for get_workers in workers_functions
                for p in @invokelatest get_workers()
                    apply_worker_action(p, Main, delexpr)  # guard against serialization errors if the type isn't defined on the worker
                end
            end
        end
        Base.delete_method(m)
        # Remove the entries from CodeTracking data
        delete!(CodeTracking.method_info, MethodInfoKey(siginfo))
        # Remove frame from JuliaInterpreter, if applicable. Otherwise debuggers
        # may erroneously work with outdated code (265-like problems)
        if haskey(JuliaInterpreter.framedict, m)
            delete!(JuliaInterpreter.framedict, m)
        end
        if isdefined(m, :generator)
            # defensively delete all generated functions
            empty!(JuliaInterpreter.genframedict)
        end
    else
        @debug "FailedSigDeletion" _group="Action" time=time() deltainfo=(siginfo,world)
    end
    nothing
end

function handle_type_deletion!(
        typeinfo::TypeInfo, reeval_list::IdSet{Union{Method,Type}}, handled_types::IdSet{Type}, world::UInt
    )
    oldtypename = typeinfo.typname
    with_logger(_debug_logger) do
        old_list = copy(reeval_list)
        oldtype = Base.invoke_in_world(world, getglobal, oldtypename.module, oldtypename.name)::Type
        alltypes = all_named_types(world) # snapshot the old type universe at the revision world
        record_invalidations_for_type_deletion!(oldtype, reeval_list, handled_types, alltypes)
        diff = setdiff(reeval_list, old_list)
        @debug "DeleteType" _group="Action" time=time() deltainfo=(oldtype,diff)
    end
    return reeval_list
end

function record_invalidations_for_type_deletion!(
        @nospecialize(oldtype::Type), reeval_list::IdSet{Union{Method,Type}}, handled_types::IdSet{Type},
        alltypes::Base.IdSet{Type}
    )
    push!(handled_types, oldtype)

    olddatatype = Base.unwrap_unionall(oldtype)::DataType
    oldtypename = olddatatype.name
    # `oldtype` must be the canonical binding for its TypeName: a non-parametric
    # DataType or the full `T where ...` UnionAll, never a concrete or partial
    # instantiation. The subtype filter below relies on this — `t <: oldtype`
    # then selects exactly what `subtypes(oldtype)` would. (For `P{Int}`,
    # `subtypes` keeps `PC{Int}` via `typeintersect` while `PC <: P{Int}` is
    # `false`, so the two would otherwise diverge.)
    @assert oldtypename.wrapper === oldtype "expected the canonical binding of $(oldtypename), got $(oldtype)"

    # Find all methods restricted to `oldtype`
    meths = old_methods_with(oldtypename)
    meths !== nothing && union!(reeval_list, meths)

    # Find all types using `oldtype`
    related_types = old_types_with(oldtypename, alltypes)
    related_types !== nothing && union!(reeval_list, related_types)

    # For any modules that have not yet been parsed and had their signatures extracted,
    # we need to do this now, before the binding changes to the new type
    meths !== nothing && maybe_extract_sigs_for_meths(meths)
    related_types !== nothing && maybe_extract_sigs_for_types(related_types)

    # If `oldtype` is an abstract type, traverse its subtypes and invalidate them.
    # By the canonical invariant asserted above, filtering the `alltypes` sweep by
    # `t <: oldtype` matches `subtypes(oldtype)` without re-scanning module names
    # at each recursion level.
    oldsubtypes = Base.IdSet{Type}(t for t in alltypes if t !== oldtype && t <: oldtype)
    maybe_extract_sigs_for_types(oldsubtypes)
    for oldsubtype in oldsubtypes
        oldsubtype in handled_types && continue
        push!(reeval_list, oldsubtype)
        record_invalidations_for_type_deletion!(oldsubtype, reeval_list, handled_types, alltypes)
    end

    # `related_types` will also be recursively redefined, so we need to invalidate methods/types related to them as well
    related_types !== nothing && for related_type in related_types
        related_type in handled_types && continue
        record_invalidations_for_type_deletion!(related_type, reeval_list, handled_types, alltypes)
    end
end

function eval_rex(rex_new::RelocatableExpr, exs_infos_old::ExprsInfos, mod::Module; mode::Symbol=:eval)
    return with_logger(_debug_logger) do
        exinfos, includes = nothing, nothing
        rex_old = getkey(exs_infos_old, rex_new, nothing)
        # extract the signatures and update the line info
        if rex_old === nothing
            ex = rex_new.ex
            # ex is not present in old
            @debug titlecase(String(mode)) _group="Action" time=time() deltainfo=(mod, ex, mode)
            exinfos, includes, thunk = eval_with_signatures(mod, ex; mode)  # All signatures defined by `ex`
            if !isexpr(thunk, :thunk)
                thunk = ex
            end
            record_worker_replay!(mod, thunk)
            for get_workers in workers_functions
                if @invokelatest is_master_worker(get_workers)
                    for p in @invokelatest get_workers()
                        @invokelatest(is_master_worker(p)) && continue
                        apply_worker_action(p, mod, thunk)  # don't error if `mod` isn't defined on the worker
                    end
                end
            end
        else
            exinfos = exs_infos_old[rex_old]
            # Update location info
            ln, lno = firstline(unwrap(rex_new)), firstline(unwrap(rex_old))
            if exinfos !== nothing && !isempty(exinfos) && ln != lno
                ln, lno = ln::LineNumberNode, lno::LineNumberNode
                @debug "LineOffset" _group="Action" time=time() deltainfo=(exinfos, lno=>ln)
                for exinfo in exinfos
                    if exinfo isa SigInfo
                        locdefs = CodeTracking.method_info[MethodInfoKey(exinfo)]::AbstractVector
                        ld = let lno=lno
                            map(pr->linediff(lno, pr[1]), locdefs)
                        end
                        idx = argmin(ld)
                        if ld[idx] === typemax(eltype(ld))
                            # println("Missing linediff for $lno and $(first.(locdefs)) with ", rex.ex)
                            idx = length(locdefs)
                        end
                        _, methdef = locdefs[idx]
                        locdefs[idx] = (fixpath(ln), methdef)
                    end
                end
            end
        end
        return exinfos, includes
    end
end

# These are typically bypassed in favor of expression-by-expression evaluation to
# allow handling of new `include` statements.
function eval_new!(exs_infos_new::ExprsInfos, exs_infos_old::ExprsInfos, mod::Module; mode::Symbol=:eval)
    includes = Vector{Pair{Module,String}}()
    for rex in keys(exs_infos_new)
        exinfos, includes′ = eval_rex(rex, exs_infos_old, mod; mode)
        if exinfos !== nothing
            exs_infos_new[rex] = exinfos
        end
        if includes′ !== nothing
            append!(includes, includes′)
        end
    end
    return exs_infos_new, includes
end

function eval_new!(mod_exs_infos_new::ModuleExprsInfos, mod_exs_infos_old::ModuleExprsInfos; mode::Symbol=:eval)
    includes = Vector{Pair{Module,String}}()
    for (mod, exs_infos_new) in mod_exs_infos_new
        # Allow packages to override the supplied mode
        if isdefined(mod, :__revise_mode__)
            mode = getfield(mod, :__revise_mode__)::Symbol
        end
        exs_infos_old = get(mod_exs_infos_old, mod, empty_exs_infos)
        _, _includes = eval_new!(exs_infos_new, exs_infos_old, mod; mode)
        append!(includes, _includes)
    end
    return mod_exs_infos_new, includes
end

# Eval and insert into CodeTracking data
function eval_with_signatures(mod::Module, ex::Expr; mode::Symbol=:eval, kwargs...)
    exinfo = ExInfo(ex)
    _, thk = methods_by_execution!(exinfo, mod, ex; mode, kwargs...)
    exinfos = Union{SigInfo,TypeInfo}[]
    append!(exinfos, exinfo.allsigs, exinfo.typeinfos)
    return exinfos, exinfo.includes, thk
end

function instantiate_sigs!(mod_exs_infos::ModuleExprsInfos; mode::Symbol=:sigs, kwargs...)
    for (mod, exs_infos) in mod_exs_infos
        for rex in keys(exs_infos)
            is_doc_expr(rex.ex) && continue
            exs_infos[rex], _, _ = eval_with_signatures(mod, rex.ex; mode, kwargs...)
        end
    end
    return mod_exs_infos
end

# This is intended for testing purposes, but not general use. The key problem is
# that it doesn't properly handle methods that move from one file to another; there is the
# risk you could end up deleting the method altogether depending on the order in which you
# process these.
# See `revise` for the proper approach.
function eval_revised(mod_exs_infos_new::ModuleExprsInfos, mod_exs_infos_old::ModuleExprsInfos)
    reeval_list = IdSet{Union{Method,Type}}()
    handled_types = IdSet{Type}()
    world = Base.get_world_counter()
    delete_missing!(mod_exs_infos_old, mod_exs_infos_new, reeval_list, handled_types, world)
    eval_new!(mod_exs_infos_new, mod_exs_infos_old)  # note: drops `includes`
    instantiate_sigs!(mod_exs_infos_new)
end

"""
    Revise.init_watching(files)
    Revise.init_watching(pkgdata::PkgData, files)

For every filename in `files`, monitor the filesystem for updates. When the file is
updated, either [`Revise.revise_dir_queued`](@ref) or [`Revise.revise_file_queued`](@ref) will
be called.

Use the `pkgdata` version if the files are supplied using relative paths.
"""
function init_watching(pkgdata::PkgData, files=srcfiles(pkgdata))
    udirs = Set{String}()
    for file in files
        file = String(file)::String
        dir, basename = splitdir(file)
        dirfull = joinpath(basedir(pkgdata), dir)
        # Hold the lock across the whole body: we both query/insert `watched_files`
        # and mutate the `WatchList` it stores, which the watcher tasks read.
        @lock revise_lock begin
            already_watching_dir = haskey(watched_files, dirfull)
            already_watching_dir || (watched_files[dirfull] = WatchList())
            watchlist = watched_files[dirfull]
            current_id = get(watchlist.trackedfiles, basename, nothing)
            new_id = pkgdata.info.id
            if new_id != NOPACKAGE || current_id === nothing
                # Allow the package id to be updated
                push!(watchlist, basename=>pkgdata)
                # Record the current ctime as baseline so only future changes are detected
                watchlist.file_ctimes[basename] = ctime(joinpath(dirfull, basename))
                # On filesystems that never deliver notifications (e.g. WSL drvfs,
                # issue #514) we must watch each file individually and poll it;
                # directory-polling cannot detect content changes within a file.
                if watching_files[] || nonnotifying_path(dirfull)
                    if !watching_files[]
                        @info """Revise: code under $dirfull is on a filesystem that does not deliver \
                                 file-change notifications (e.g. a WSL `/mnt/...` drive, issue #514). \
                                 Falling back to polling these files; revisions may take a few seconds \
                                 to register.""" maxlog=1
                    end
                    fwatcher = TaskThunk(revise_file_queued, (pkgdata, file))
                    schedule(Task(fwatcher))
                else
                    already_watching_dir || push!(udirs, dirfull)
                end
            end
        end
    end
    for dirfull in udirs
        if !watching_files[]
            # Register the buffered directory monitor now, before the watcher task
            # runs, so events are queued from the moment we start tracking and the
            # startup gap is closed. Skipped on polling/non-notifying filesystems,
            # which never deliver notifications.
            polling_files[] || nonnotifying_path(dirfull) || watch_folder(dirfull, 0)
            dwatcher = TaskThunk(revise_dir_queued, (dirfull,))
            schedule(Task(dwatcher))
        end
    end
    return nothing
end
init_watching(files) = init_watching((@lock revise_lock pkgdatas[NOPACKAGE]), files)

# Maximum time (in seconds) a watched path may be absent before Revise concludes
# it was genuinely removed. A shorter absence is treated as transient: a
# `Pkg.build`, a git checkout, an environment switch, or an editor's
# atomic-rename save can briefly remove and recreate a directory or file, and in
# those cases the watch should resume silently rather than stop and warn (#523).
const watch_reappear_grace = Ref(5.0)

# Block while a watched path is missing. `exists(path)` reports whether it is
# currently present; `watchkey` is its entry in `watched_files`. Returns:
#   :reappeared — came back within the grace period (resume watching)
#   :removed    — no longer in the watch list, e.g. the package moved (stop quietly)
#   :gone       — stayed missing past the grace period (stop and warn)
function await_watched_path(exists, path::AbstractString, watchkey::AbstractString)
    waited = 0.0
    while !exists(path)
        @lock revise_lock haskey(watched_files, watchkey) || return :removed
        waited ≥ watch_reappear_grace[] && return :gone
        sleep(0.1)
        waited += 0.1
    end
    return :reappeared
end

"""
    revise_dir_queued(dirname::AbstractString)

Wait for one or more of the files registered in `Revise.watched_files[dirname]` to be
modified, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called via a [`Revise.TaskThunk`](@ref).
"""
@noinline function revise_dir_queued(dirname::AbstractString)
    @assert isabspath(dirname)
    stillwatching = true
    while stillwatching
        if !isdir(dirname)
            status = await_watched_path(isdir, dirname, dirname)
            if status !== :reappeared
                if status === :gone
                    with_logger(SimpleLogger(stderr)) do
                        @warn "$dirname is not an existing directory, Revise is not watching"
                    end
                    # Drop the watch registration as we stop. Otherwise, if `dirname`
                    # is recreated later (e.g. switching back to a branch that has it),
                    # `init_watching` would see the stale entry, assume a watcher is
                    # already running, and never start a replacement — so edits to the
                    # reappeared files would go unnoticed.
                    @lock revise_lock delete!(watched_files, dirname)
                end
                break
            end
            # Reappeared: the directory was removed and recreated, so the existing
            # monitor may be watching a stale inode. Drop it; the next
            # `wait_changed_dir` re-registers a fresh one.
            unwatch_folder(dirname)
        end

        latestfiles, stillwatching = watch_files_via_dir(dirname)  # will block here until file(s) change
        for (file, id) in latestfiles
            key = joinpath(dirname, file)
            @lock revise_lock begin
                if key in keys(user_callbacks_by_file)
                    union!(user_callbacks_queue, user_callbacks_by_file[key])
                    notify(revision_event)
                end
                if id != NOPACKAGE
                    pkgdata = pkgdatas[id]
                    if hasfile(pkgdata, key)  # issue #228
                        push!(revision_queue, (pkgdata, relpath(key, pkgdata)))
                        notify(revision_event)
                    end
                end
            end
        end
    end
    unwatch_folder(dirname)  # stop the OS watch now that we no longer watch this dir
    return
end

# See #66.
"""
    revise_file_queued(pkgdata::PkgData, filename)

Wait for modifications to `filename`, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called via a [`Revise.TaskThunk`](@ref).

This is used only on platforms (like BSD) which cannot use [`Revise.revise_dir_queued`](@ref).
"""
function revise_file_queued(pkgdata::PkgData, file)
    if !isabspath(file)
        file = joinpath(basedir(pkgdata), file)
    end

    dirfull, _ = splitdir(file)
    fileexists(f) = file_exists(f) || isdir(f)
    stillwatching = true
    while stillwatching
        if !fileexists(file)
            status = await_watched_path(fileexists, file, dirfull)
            if status !== :reappeared
                if status === :gone
                    let file=file
                        with_logger(SimpleLogger(stderr)) do
                            @warn "$file is not an existing file, Revise is not watching"
                        end
                    end
                end
                notify(revision_event)
                break
            end
        end
        try
            wait_changed(file)  # will block here until the file changes
        catch e
            # issue #459
            (isa(e, InterruptException) && throwto_repl(e)) || throw(e)
        end

        @lock revise_lock begin
            if file in keys(user_callbacks_by_file)
                union!(user_callbacks_queue, user_callbacks_by_file[file])
                notify(revision_event)
            end
            # Check to see if we're still watching this file
            stillwatching = haskey(watched_files, dirfull)
            if PkgId(pkgdata) != NOPACKAGE
                push!(revision_queue, (pkgdata, relpath(file, pkgdata)))
            end
        end
    end
    return
end

# Parse the file's current contents and look up the exprs Revise has on record for
# it. Returns `(mod_exs_infos_new, mod_exs_infos_old, fileok)`. Safe to call from a
# pre-deletion pass: any mutation of `pkgdata` is limited to lazily filling caches.
function parse_for_revision(pkgdata::PkgData, file::AbstractString, idx::Int)
    fi = fileinfo(pkgdata, idx)
    maybe_parse_from_cache!(pkgdata, file, fi)
    maybe_extract_sigs!(fi)
    mod_exs_infos_old = fi.mod_exs_infos
    filep = pkgdata.info.files[idx]
    if isa(filep, AbstractString)
        if file ≠ "."
            filep = normpath(basedir(pkgdata), file)
        else
            filep = normpath(basedir(pkgdata))
        end
    end
    topmod = first(keys(mod_exs_infos_old))
    fileok = file_exists(String(filep)::String)
    pr = fileok ? parse_and_maybe_eval_source(filep, topmod) : ParseResult(ModuleExprsInfos(topmod), true)
    return pr, mod_exs_infos_old, fileok
end

# Apply deletions for `(pkgdata, file)` from the results of `parse_for_revision`.
# Mutates `reeval_list`, `handled_types`, and `predictions.skipped`. A file that no
# longer exists has all its methods deleted but stays registered in `pkgdata` and
# the watch lists: if it is recreated later, the watcher queues it again and the
# next `revise` re-evaluates the new content. (The caller replaces the stored
# `FileInfo` with the parse result, which for a missing file is empty.)
function delete_for_revision(
        pkgdata::PkgData, file::AbstractString, idx::Int,
        @nospecialize(mod_exs_infos_new), mod_exs_infos_old::ModuleExprsInfos, fileok::Bool,
        reeval_list::IdSet{Union{Method,Type}}, handled_types::IdSet{Type}, world::UInt,
        predictions::TypePredictions,
    )
    if mod_exs_infos_new !== nothing
        delete_missing!(mod_exs_infos_old, mod_exs_infos_new::ModuleExprsInfos, reeval_list, handled_types, world, predictions)
    end
    if !fileok && any(!isempty, values(mod_exs_infos_old))
        filep = pkgdata.info.files[idx]
        if isa(filep, AbstractString)
            if file ≠ "."
                filep = normpath(basedir(pkgdata), file)
            else
                filep = normpath(basedir(pkgdata))
            end
        end
        @warn("$filep no longer exists, deleted all methods")
    end
    return nothing
end

# Because we delete first, we have to make sure we've parsed the file
function handle_deletions(
        pkgdata::PkgData, file::AbstractString, idx::Int,
        reeval_list::IdSet{Union{Method,Type}}, handled_types::IdSet{Type}, world::UInt,
        predictions::TypePredictions = TypePredictions(),
    )
    pr, mod_exs_infos_old, fileok = parse_for_revision(pkgdata, file, idx)
    mod_exs_infos_new = (pr.success && !pr.donotparse) ? pr.modexinfos : nothing
    delete_for_revision(pkgdata, file, idx, mod_exs_infos_new, mod_exs_infos_old, fileok,
                        reeval_list, handled_types, world, predictions)
    return mod_exs_infos_new, mod_exs_infos_old
end

struct ReevalInfo
    reeval::Union{Method,Type}
    mod::Module
    exs_infos::ExprsInfos
    rex::RelocatableExpr
    pkgdata::PkgData
    file::String
    ReevalInfo(
        @nospecialize(reeval::Union{Method,Type}), mod::Module, exs_infos::ExprsInfos, rex::RelocatableExpr,
        pkgdata::PkgData, file::String
    ) = new(reeval, mod, exs_infos, rex, pkgdata, file)
end

function redefine_bindings!(revision_errors::Vector{Tuple{PkgData,String}}, reeval_list::IdSet{Union{Method,Type}}, world::UInt)
    reeval_infos = ReevalInfo[]

    # N.B. This traverse could become expensive when Revise tracked code becomes large
    # We could optimize this part by preparing a `CodeTracking.ex_info` cache that incorporates
    # type information as well as index information to `pkgdatas` into the `CodeTracking.method_info` cache,
    # and updating `CodeTracking.ex_info` in sync with `pkgdatas` updates,
    # then performing lookups to `CodeTracking.ex_info` instead
    for (_, pkgdata) in pkgdatas
        for (file, fileinfo) in zip(srcfiles(pkgdata), pkgdata.fileinfos)
            for (mod, exs_infos) in fileinfo.mod_exs_infos
                for (rex, exinfos) in exs_infos
                    exinfos === nothing && continue
                    for exinfo in exinfos
                        if exinfo isa SigInfo
                            mt, sig = exinfo
                            ret = Base._methods_by_ftype(sig, mt, -1, world)
                            isempty(ret) && continue
                            for match in ret
                                if match.method in reeval_list
                                    push!(reeval_infos, ReevalInfo(match.method, mod, exs_infos, rex, pkgdata, file))
                                    break
                                end
                            end
                        else exinfo::TypeInfo
                            typeinfo = exinfo
                            if Base.invoke_in_world(world, isdefinedglobal, typeinfo.typname.module, typeinfo.typname.name)
                                typ = Base.invoke_in_world(world, getglobal, typeinfo.typname.module, typeinfo.typname.name)
                                if typ isa Type && typ in reeval_list
                                    push!(reeval_infos, ReevalInfo(typ, mod, exs_infos, rex, pkgdata, file))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    for (; reeval, mod, exs_infos, rex, pkgdata, file) in reeval_infos
        reeval isa Type || continue
        with_logger(_debug_logger) do
            @debug "ReevalType" _group="Action" time=time() deltainfo=(reeval,mod,rex)
            try
                newexinfos, _, _ = eval_with_signatures(mod, rex.ex; mode=:eval)
                exs_infos[rex] = newexinfos
            catch err
                # Re-evaluation failed, likely due to type incompatibility
                # Clear exs_infos cache for this `rex` so that we will retry evaluation when methods become compatible
                delete!(exs_infos, rex)
                @debug "ReevalTypeFailed" _group="Action" time=time() deltainfo=(reeval,mod,rex,err)
                push!(revision_errors, (pkgdata, file))
                queue_errors[(pkgdata, file)] = (err, catch_backtrace())
            end
        end
    end
    for (; reeval, mod, exs_infos, rex, pkgdata, file) in reeval_infos
        reeval isa Method || continue
        with_logger(_debug_logger) do
            @debug "ReevalDeleteMethod" _group="Action" time=time() deltainfo=(reeval.sig, MethodSummary(reeval))
            # ensure that "old data" doesn't get run with "old methods"
            try Base.delete_method(reeval) catch end
            @debug "ReevalMethod" _group="Action" time=time() deltainfo=(reeval, reeval.module, rex)
            try
                newexinfos, _, _ = eval_with_signatures(mod, rex.ex; mode=:eval)
                exs_infos[rex] = newexinfos
            catch err
                # Re-evaluation failed, likely due to type incompatibility
                # Clear exs_infos cache for this `rex` so that we will retry evaluation when methods become compatible
                delete!(exs_infos, rex)
                @debug "ReevalMethodFailed" _group="Action" time=time() deltainfo=(reeval,mod,rex,err)
                push!(revision_errors, (pkgdata, file))
                queue_errors[(pkgdata, file)] = (err, catch_backtrace())
            end
        end
    end
    return revision_errors
end

# Extract the singleton function instance from a method signature `Tuple{typeof(f), ...}`.
# Returns `nothing` for constructors (`Type{T}`) or callable objects with no singleton instance.
function sig_function(@nospecialize(sig))
    ft = Base.unwrap_unionall(sig)
    ft isa DataType && !isempty(ft.parameters) || return nothing
    F = Base.unwrap_unionall(ft.parameters[1])
    (F isa DataType && isdefined(F, :instance)) || return nothing
    return F.instance
end

# Collect the set of method signatures defined by the `SigInfo`s in `exs_infos`.
function sigset(exs_infos::ExprsInfos)
    sigs = Set{Any}()
    for (_, exinfos) in exs_infos
        exinfos === nothing && continue
        for exinfo in exinfos
            exinfo isa SigInfo || continue
            push!(sigs, exinfo.sig)
        end
    end
    return sigs
end

# Issue #239. An accidental definition such as
#     foo() = iterate(x)        # intends to call Base.iterate
#     iterate(x::Foo) = ...     # OOPS: defines a *new* `MyMod.iterate`, shadowing Base.iterate
# creates a module-local `iterate` that shadows the imported one, and `foo`
# binds to it. When the user corrects it to `Base.iterate(x::Foo) = ...`, Revise
# deletes the wrong method, but the now-methodless `MyMod.iterate` binding
# lingers; unqualified references keep resolving to it, so the package stays
# broken until the session is restarted.
#
# This shadowing can only happen for a name that was implicitly in scope; an
# explicit import errors when code like the above is encountered. Thus if an
# edit (a) *empties* a module-owned function binding and (b) adds a method to a
# *different* function of the same name that is implicitly in scope, we take a
# stab at guessing user-intent and make the change. Because this involves
# inference on Revise's part, we log this with an `@info`.
#
# Requires binding partitions (Julia 1.12+): earlier, function bindings are
# `const` and cannot be reassigned, and `delete_binding` does not exist.
# This 1.12+ feature is not hidden behind a check on `__bpart__`, as that
# focuses on type-redefinition.
function realias_orphaned_bindings!(mod_exs_infos_new::ModuleExprsInfos,
                                    mod_exs_infos_old::ModuleExprsInfos)
    Base.VERSION >= v"1.12.0-DEV.2047" || return nothing
    repaired = Tuple{Module,Symbol,Module}[]
    with_logger(_debug_logger) do
        for (mod, exs_infos_old) in mod_exs_infos_old
            oldsigs = sigset(exs_infos_old)
            newsigs = sigset(get(mod_exs_infos_new, mod, empty_exs_infos))
            # (b) functions that gained a method this revision, indexed by name
            added = Dict{Symbol,Any}()
            for s in newsigs
                s in oldsigs && continue
                f = sig_function(s)
                f === nothing && continue
                added[nameof(f)] = f
            end
            isempty(added) && continue
            # (a) functions that lost a method this revision and are now empty + module-owned
            for s in oldsigs
                s in newsigs && continue
                fdel = sig_function(s)
                fdel === nothing && continue
                isempty(methods(fdel)) || continue       # still has methods => not orphaned
                parentmodule(fdel) === mod || continue    # only repair bindings this module owns
                n = nameof(fdel)
                fadd = get(added, n, nothing)
                (fadd === nothing || fadd === fdel) && continue
                # Only repair when `fadd` was implicitly in scope (an export of a module `mod`
                # bare-`using`s, including Base/Core): that is the sole situation that can
                # produce this shadow, so re-importing reproduces the original implicit scope.
                src = implicit_import_source(mod, n, fadd)
                src === nothing && continue
                # `delete_binding` clears the orphan; `using src: n` re-establishes the import.
                # A bare `delete_binding` is not enough: implicit-import fallthrough after
                # deletion is not yet implemented, so `n` would resolve to `UndefVarError`.
                # TODO: replicate to distributed workers (cf. `delete_method_by_sig`).
                # See https://github.com/timholy/Revise.jl/pull/1056#discussion_r3338811301
                try
                    Base.delete_binding(mod, n)
                    usestmt = Expr(:using, Expr(:(:), Expr(:., fullname(src)...), Expr(:., n)))
                    Core.eval(mod, usestmt)
                    @debug "RealiasOrphan" _group="Action" time=time() deltainfo=(mod, n, src)
                    push!(repaired, (mod, n, src))
                catch err
                    @debug "RealiasOrphanFailed" _group="Action" time=time() deltainfo=(mod, n, err)
                end
            end
        end
    end
    # Surface the repair to the user. Unlike method deletion/redefinition (logged only at
    # `@debug`), this is a binding mutation Revise infers — it does not correspond 1:1 to a
    # source edit the user made — so it is worth an `@info`.
    for (mod, n, src) in repaired
        @info "Revise re-imported `$n` into `$mod` from `$src`, repairing an orphaned binding (issue #239)"
    end
    return nothing
end

# If `n` is implicitly in scope in `mod` — an export of a module `mod` brings in via a bare
# `using` (including the implicit `Base`/`Core`) — and that export is the function `f`, return
# the module supplying it; otherwise `nothing`. This is precisely the condition under which an
# unqualified `n(x::T) = ...` definition shadows `f` with a new module-local binding (#239).
function implicit_import_source(mod::Module, n::Symbol, @nospecialize(f))
    for used in ccall(:jl_module_usings, Any, (Any,), mod)::Vector{Any}
        used isa Module || continue
        Base.isexported(used, n) || continue
        isdefined(used, n) || continue
        getglobal(used, n) === f && return used
    end
    return nothing
end

"""
    Revise.revise_file_now(pkgdata::PkgData, file)

Process revisions to `file`. This parses `file` and computes an expression-level diff
between the current state of the file and its most recently evaluated state.
It then deletes any removed methods and re-evaluates any changed expressions.
Note that generally it is better to use [`revise`](@ref) as it properly handles methods
that move from one file to another.

`id` must be a key in [`Revise.pkgdatas`](@ref), and `file` a key in
`Revise.pkgdatas[id].fileinfos`.
"""
function revise_file_now(pkgdata::PkgData, file)
    # @assert !isabspath(file)
    indices = fileindices(pkgdata, file)
    if isempty(indices)
        println("Revise is currently tracking the following files in $(PkgId(pkgdata)): ", srcfiles(pkgdata))
        error(file, " is not currently being tracked.")
    end
    reeval_list = IdSet{Union{Method,Type}}()
    handled_types = IdSet{Type}()
    world = Base.get_world_counter()
    # A file `include`d into several modules has one `FileInfo` per inclusion; revise
    # them all (issue #730).
    for i in indices
        mod_exs_infos_new, mod_exs_infos_old = handle_deletions(pkgdata, file, i, reeval_list, handled_types, world)
        if mod_exs_infos_new != nothing
            _, includes = eval_new!(mod_exs_infos_new, mod_exs_infos_old)
            realias_orphaned_bindings!(mod_exs_infos_new, mod_exs_infos_old)   # issue #239
            fi = fileinfo(pkgdata, i)
            pkgdata.fileinfos[i] = FileInfo(mod_exs_infos_new, fi)
            maybe_add_includes_to_pkgdata!(pkgdata, file, includes; eval_now=true)
        end
    end
    nothing
end

"""
    Revise.errors()

Report the errors represented in [`Revise.queue_errors`](@ref).
Errors are automatically reported the first time they are encountered, but this function
can be used to report errors again.
"""
function errors(revision_errors=keys(queue_errors))
    printed = Set{eltype(revision_errors)}()
    for item in revision_errors
        item in printed && continue
        push!(printed, item)
        pkgdata, file = item
        (err, bt) = queue_errors[(pkgdata, file)]
        fullpath = joinpath(basedir(pkgdata), file)
        if err isa ReviseEvalException
            @error "Failed to revise $fullpath" exception=err
        else
            @error "Failed to revise $fullpath" exception=(err, trim_toplevel!(bt))
        end
    end
end

"""
    Revise.retry()

Attempt to perform previously-failed revisions. This can be useful in cases of order-dependent errors.
"""
function retry()
    @lock revise_lock begin
        for k in keys(queue_errors)
            push!(revision_queue, k)
        end
    end
    revise()
end

# Resolve the least-specific type-equal method for a tracked signature, or `nothing`
# if no matching method currently exists.
function resolve_signature_method(key::MethodInfoKey, world::UInt)
    mt, sig = key
    ret = Base._methods_by_ftype(sig, mt, -1, world)
    isempty(ret) && return nothing
    return ret[end].method
end

# A duplicate signature only matters when its package is actually precompiled: the
# "Method overwriting is not permitted during Module precompilation" failure cannot
# occur for `Main`/`includet` code (never precompiled) or for `__precompile__(false)`
# packages (no cache is ever written). `Base.isprecompiled` is unusable here because a
# package under active Revise development always has a stale cache; the mere existence
# of a cache file distinguishes a precompilable package from one that opts out.
function in_precompilable_package(m::Method)
    root = Base.moduleroot(m.module)
    root === Main && return false
    pkgid = Base.PkgId(root)
    pkgid.name == "Main" && return false
    return !isempty(Base.find_all_in_cache_path(pkgid))
end

# Recompute `duplicated_signatures` from the current tracking data and return the keys
# that are newly duplicated relative to the previous state.
function update_duplicated_signatures!(world::UInt)
    current = Dict{MethodInfoKey,Vector{LineNumberNode}}()
    for (key, locdefs) in CodeTracking.method_info
        isa(locdefs, Vector{Tuple{LineNumberNode,Expr}}) || continue
        length(locdefs) > 1 || continue
        m = resolve_signature_method(key, world)
        m === nothing && continue
        in_precompilable_package(m) || continue
        current[key] = LineNumberNode[ld[1] for ld in locdefs]
    end
    newly = MethodInfoKey[key for key in keys(current) if !haskey(duplicated_signatures, key)]
    empty!(duplicated_signatures)
    merge!(duplicated_signatures, current)
    return newly
end

# Append a human-readable description of one duplicated signature to `io`.
function report_duplicate_signature(io::IO, key::MethodInfoKey, lnns, world::UInt)
    m = resolve_signature_method(key, world)
    if m !== nothing
        try
            Base.show_tuple_as_call(io, m.name, m.sig)
        catch
            print(io, key.sig)
        end
    else
        print(io, key.sig)
    end
    println(io)
    for ln in lnns
        println(io, "    ", location_string((ln.file, ln.line)))
    end
    return io
end

function warn_duplicated_signatures(newly::Vector{MethodInfoKey}, world::UInt)
    isempty(newly) && return nothing
    io = IOBuffer()
    for key in newly
        print(io, "  ")
        report_duplicate_signature(io, key, duplicated_signatures[key], world)
    end
    @warn """The following method(s) are defined in more than one location. They work now, but \
the next precompilation will fail with "Method overwriting is not permitted during Module \
precompilation". Delete the redundant definition(s):
$(String(take!(io)))Use `Revise.duplicate_methods()` to report these again.
Your prompt color may be yellow until the duplicates are resolved."""
    return nothing
end

"""
    Revise.duplicate_methods()

Report the method signatures currently defined in more than one place within a
precompilable package (see [`Revise.duplicated_signatures`](@ref)). Such duplicates
evaluate successfully in the running session but cause the next precompilation to fail
with "Method overwriting is not permitted during Module precompilation". Delete the
redundant definition(s) to resolve. Duplicates are reported automatically the first time
they are detected; this function reports them again.
"""
function duplicate_methods()
    isempty(duplicated_signatures) && return nothing
    world = Base.get_world_counter()
    io = IOBuffer()
    for (key, lnns) in duplicated_signatures
        print(io, "  ")
        report_duplicate_signature(io, key, lnns, world)
    end
    @warn "The following method(s) are defined in more than one location and will fail precompilation:\n$(String(take!(io)))"
    return nothing
end

"""
    revise(; throw=false)

`eval` any changes in the revision queue. See [`Revise.revision_queue`](@ref).
If `throw` is `true`, throw any errors that occur during revision or callback;
otherwise these are only logged.
"""
revise(; throw::Bool=false) = frozen(_revise; throw)

function _revise(; throw::Bool=false)
    active[] || return nothing

    @lock revise_lock begin
        have_queue_errors = !isempty(queue_errors)

        # Julia 1.12+: when bindings switch to a new type, we need to re-evaluate method
        # definitions using the new binding resolution.
        reeval_list = IdSet{Union{Method,Type}}()
        handled_types = IdSet{Type}()
        world = Base.get_world_counter()

        # Do all the deletion first. This ensures that a method that moved from one file to another
        # won't get redefined first and deleted second.
        revision_errors = Tuple{PkgData,String}[]
        queue = sort!(collect(revision_queue); lt=pkgfileless)
        # A watcher task can queue a `PkgData` that has since been replaced in
        # `pkgdatas` (e.g., by `Revise.track` of a package whose record had been
        # dropped, as for packages baked into a sysimage — issue #685). If both the
        # stale and the current record are queued for the same file, keep only the
        # current one: each holds its own copy of the file's old signatures, and
        # processing both would delete the same methods twice.
        keep = trues(length(queue))
        for (i, (pkgdata, file)) in enumerate(queue)
            current = get(pkgdatas, PkgId(pkgdata), nothing)
            (current === nothing || current === pkgdata) && continue
            if any(((qpkgdata, qfile),) -> qpkgdata === current && qfile == file, queue)
                keep[i] = false
            end
        end
        queue = queue[keep]
        finished = eltype(revision_queue)[]
        finished_idx = Int[]
        mod_exs_infos = ModuleExprsInfos[]
        interrupt = false

        # Parse every queued file, then predict which already-defined types the new
        # code re-creates unchanged (e.g., a `@kwdef` struct whose only edit is a
        # default value — issue #1022). The prediction must precede `delete_missing!`,
        # which consults it to skip the expensive subtype-tree walk, and it must span
        # all queued files so a type moved between files is still recognized. It runs
        # only when a type deletion is actually pending, and only under `__bpart__[]`
        # (the consumer of the walk it can skip).
        predictions = TypePredictions()
        # A file `include`d into several modules has one `FileInfo` per inclusion,
        # all sharing the queued filename; each is parsed and revised independently,
        # so `idx` identifies which `FileInfo` a parse result belongs to (issue #730).
        parsed = Tuple{PkgData,String,Int,Any,ModuleExprsInfos,Bool}[]
        pending_type_deletion = false
        deferred_missing = Tuple{PkgData,String}[]
        for (pkgdata, file) in queue
            for idx in fileindices(pkgdata, file)
                try
                    pr, mod_exs_infos_old, fileok = parse_for_revision(pkgdata, file, idx)
                    pr.donotparse && continue
                    mod_exs_infos_new = pr.success ? pr.modexinfos : nothing
                    if fileok
                        delete!(missing_file_times, (pkgdata, file))
                    else
                        # The file may be missing only transiently (e.g., mid-rewrite by a
                        # code generator). Within the grace period, leave it queued and
                        # untouched; see `missing_file_grace`.
                        tfirst = get!(missing_file_times, (pkgdata, file), time())
                        if time() - tfirst < missing_file_grace[]
                            push!(deferred_missing, (pkgdata, file))
                            continue
                        end
                    end
                    pending_type_deletion |= __bpart__[] && has_pending_type_deletion(mod_exs_infos_new, mod_exs_infos_old)
                    push!(parsed, (pkgdata, file, idx, mod_exs_infos_new, mod_exs_infos_old, fileok))
                catch err
                    throw && Base.throw(err)
                    interrupt |= isa(err, InterruptException)
                    push!(revision_errors, (pkgdata, file))
                    queue_errors[(pkgdata, file)] = (err, catch_backtrace())
                end
            end
        end
        if pending_type_deletion
            with_logger(_debug_logger) do
                for (pkgdata, file, idx, mod_exs_infos_new, mod_exs_infos_old, fileok) in parsed
                    mod_exs_infos_new isa ModuleExprsInfos || continue
                    predict_changes!(predictions, mod_exs_infos_new, mod_exs_infos_old)
                end
            end
        end

        # Apply the deletions
        for (pkgdata, file, idx, mod_exs_infos_new, mod_exs_infos_old, fileok) in parsed
            try
                delete_for_revision(pkgdata, file, idx, mod_exs_infos_new, mod_exs_infos_old, fileok,
                                    reeval_list, handled_types, world, predictions)
                if mod_exs_infos_new !== nothing
                    push!(mod_exs_infos, mod_exs_infos_new)
                    push!(finished, (pkgdata, file))
                    push!(finished_idx, idx)
                end
            catch err
                throw && Base.throw(err)
                interrupt |= isa(err, InterruptException)
                push!(revision_errors, (pkgdata, file))
                queue_errors[(pkgdata, file)] = (err, catch_backtrace())
            end
        end

        # Do the evaluation
        for ((pkgdata, file), i, mod_exs_infos_new) in zip(finished, finished_idx, mod_exs_infos)
            defaultmode = PkgId(pkgdata).name == "Main" ? :evalmeth : :eval
            fi = fileinfo(pkgdata, i)
            modsremaining = Set(keys(mod_exs_infos_new))
            changed, err = true, nothing
            while changed
                changed = false
                for (mod, exs_infos_new) in mod_exs_infos_new
                    mod ∈ modsremaining || continue
                    try
                        mode = defaultmode
                        # Allow packages to override the supplied mode
                        if isdefinedglobal(mod, :__revise_mode__)
                            mode = getglobal(mod, :__revise_mode__)::Symbol
                        end
                        mode ∈ (:sigs, :eval, :evalmeth, :evalassign) || error("unsupported mode ", mode)
                        exs_infos_old = get(fi.mod_exs_infos, mod, empty_exs_infos)
                        for rex in keys(exs_infos_new)
                            exinfos, includes = eval_rex(rex, exs_infos_old, mod; mode)
                            if exinfos !== nothing
                                exs_infos_new[rex] = exinfos
                            end
                            if includes !== nothing
                                maybe_add_includes_to_pkgdata!(pkgdata, file, includes; eval_now=true)
                            end
                        end
                        delete!(modsremaining, mod)
                        changed = true
                    catch e
                        err = e
                    end
                end
            end
            if isempty(modsremaining) || isa(err, LoweringException)   # fix #877
                pkgdata.fileinfos[i] = FileInfo(mod_exs_infos_new, fi)
            end
            if isempty(modsremaining)
                realias_orphaned_bindings!(mod_exs_infos_new, fi.mod_exs_infos)  # issue #239
                delete!(queue_errors, (pkgdata, file))
            else
                throw && Base.throw(err)
                interrupt |= isa(err, InterruptException)
                push!(revision_errors, (pkgdata, file))
                queue_errors[(pkgdata, file)] = (err, catch_backtrace())
            end
        end

        # Keep `Base.pkgorigins` version in sync with revised source (issue #684)
        for pkgdata in unique!(first.(finished))
            update_pkgversion!(PkgId(pkgdata))
        end

        # Do binding redefinitions
        if __bpart__[]
            # Verify the predictions that suppressed deletion walks: they were made
            # before any queued change was applied, so a same-revision change to a
            # binding the type's structure depends on (a field-type alias, a
            # supertype, a parameter bound) can falsify them. If the binding moved
            # anyway, run the walk now — `world` still resolves the old type. Relative
            # to a pre-evaluation walk, signature extraction for files that have not
            # yet been parsed sees the new binding, so methods in such files may
            # escape re-evaluation.
            for (typeinfo, oldtype) in predictions.skipped
                tn = typeinfo.typname
                current = @invokelatest(isdefinedglobal(tn.module, tn.name)) ?
                          @invokelatest(getglobal(tn.module, tn.name)) : nothing
                current === oldtype && continue
                handle_type_deletion!(typeinfo, reeval_list, handled_types, world)
            end
            redefine_bindings!(revision_errors, reeval_list, world)
        end

        # Error handling
        if interrupt
            for pkgfile in finished
                haskey(queue_errors, pkgfile) || delete!(revision_queue, pkgfile)
            end
        else
            empty!(revision_queue)
            # Files missing within the grace period stay queued so the next
            # `revise` revisits them (and `revise_first` keeps firing).
            for pkgfile in deferred_missing
                push!(revision_queue, pkgfile)
            end
        end
        errors(revision_errors)
        if !isempty(queue_errors)
            if !have_queue_errors    # only print on the first time errors occur
                io = IOBuffer()
                println(io, "\n") # better here than in the triple-quoted literal, see https://github.com/JuliaLang/julia/issues/34105
                for (pkgdata, file) in keys(queue_errors)
                    println(io, "  ", joinpath(basedir(pkgdata), file))
                end
                str = String(take!(io))
                @warn """The running code does not match the saved version for the following files:$str
                If the error was due to evaluation order, it can sometimes be resolved by calling `Revise.retry()`.
                Use Revise.errors() to report errors again. Only the first error in each file is shown.
                Your prompt color may be yellow until the errors are resolved."""
            end
        end
        # Surface signatures now defined in more than one place within a precompilable
        # package. They evaluate successfully here, but the next precompilation fails with
        # "Method overwriting is not permitted during Module precompilation" (issue #889).
        dupworld = Base.get_world_counter()
        warn_duplicated_signatures(update_duplicated_signatures!(dupworld), dupworld)
        if isempty(queue_errors) && isempty(duplicated_signatures)
            maybe_set_prompt_color(:ok)
        else
            maybe_set_prompt_color(:warn)
        end
        tracking_Main_includes[] && queue_includes(Main)

        process_user_callbacks!(; throw)
    end

    nothing
end
revise(::REPL.REPLBackend) = revise()

"""
    revise(mod::Module; force::Bool=true)

Revise all files that define `mod`.

If `force=true`, reevaluate every definition in `mod`, whether it was changed or not. This is useful
to propagate an updated macro definition, or to force recompiling generated functions.
Be warned, however, that this invalidates all the compiled code in your session that depends on `mod`,
and can lead to long recompilation times.
"""
revise(mod::Module; force::Bool=true) = frozen(_revise, mod; force)

function _revise(mod::Module; force::Bool=true)
    mod == Main && error("cannot revise(Main)")
    id = PkgId(mod)
    pkgdata = @lock revise_lock pkgdatas[id]
    @lock revise_lock for file in pkgdata.info.files
        push!(revision_queue, (pkgdata, file))
    end
    _revise()
    force || return true
    # The force re-evaluation runs user code and logs through the user's ambient logger;
    # escape Revise's frozen world so both dispatch at the latest world (issue #552).
    Base.invokelatest(force_reeval!, pkgdata)
    return true  # fixme try/catch?
end

function force_reeval!(pkgdata::PkgData)
    # issue #975: re-evaluating every definition rewrites each docstring, and
    # `Base.Docs` warns on every rewrite; suppress that expected noise.
    with_logger(SuppressReplacingDocsLogger(current_logger())) do
        for i = 1:length(srcfiles(pkgdata))
            fi = fileinfo(pkgdata, i)
            for (mod, exs_infos) in fi.mod_exs_infos
                for def_rex in keys(exs_infos)
                    ex = def_rex.ex
                    exuw = unwrap(ex)
                    isexpr(exuw, :call) && is_some_include(exuw.args[1]) && continue
                    try
                        Core.eval(mod, ex)
                    catch err
                        @show mod
                        display(ex)
                        rethrow(err)
                    end
                end
            end
        end
    end
    return nothing
end

"""
    Revise.track(mod::Module, file::AbstractString)
    Revise.track(file::AbstractString)

Watch `file` for updates and [`revise`](@ref) loaded code with any
changes. `mod` is the module into which `file` is evaluated; if omitted,
it defaults to `Main`.

If this produces many errors, check that you specified `mod` correctly.
"""
track(mod::Module, file::AbstractString; mode=:sigs, kwargs...) =
    frozen(_track, mod, file; mode, kwargs...)

function _track(mod::Module, file::AbstractString; mode=:sigs, kwargs...)
    isfile(file) || error(file, " is not a file")
    # Determine whether we're already tracking this file
    id = Base.moduleroot(mod) == Main ? PkgId(mod, string(mod)) : PkgId(mod)  # see #689 for `Main`
    pkgdata = getpkgdata(id)
    if pkgdata !== nothing
        relfile = relpath(abspath_no_normalize(file), pkgdata)
        hasfile(pkgdata, relfile) && return nothing
        # Use any "fixes" provided by relpath
        file = joinpath(basedir(pkgdata), relfile)
    else
        # Check whether `track` was called via a @require. Ref issue #403 & #431.
        st = stacktrace(backtrace())
        if any(sf->sf.func === :listenpkg && endswith(String(sf.file), "require.jl"), st)
            nameof(mod) === :Plots || Base.depwarn("Revise@2.4 or higher automatically handles `include` statements in `@require` expressions.\nPlease do not call `Revise.track` from such blocks.", :track)
            return nothing
        end
        file = abspath_no_normalize(file)
    end
    # Set up tracking
    pr = parse_and_maybe_eval_source(file, mod; mode)
    if pr.success
        mod_exs_infos = pr.modexinfos
        if mode === :includet
            mode = :sigs   # we already handled evaluation in `parse_and_maybe_eval_source`
        end
        frozen(instantiate_sigs!, mod_exs_infos; mode, kwargs...)
        if !haspkgdata(id)
            # Wait a bit to see if `mod` gets initialized
            sleep(0.1)
        end
        pkgdata = getpkgdata(id)
        if pkgdata === nothing
            pkgdata = PkgData(id, pathof(mod))
        end
        if !haskey(CodeTracking._pkgfiles, id)
            CodeTracking._pkgfiles[id] = pkgdata.info
        end
        @lock revise_lock begin
            push!(pkgdata, relpath(file, pkgdata)=>FileInfo(mod_exs_infos))
            init_watching(pkgdata, (String(file)::String,))
            pkgdatas[id] = pkgdata
        end
    end
    # issue #783: in `:includet` mode, return the value of the last evaluated expression
    return isdefined(pr, :ret) ? pr.ret : nothing
end

function track(file::AbstractString; kwargs...)
    startswith(file, juliadir) && error("use Revise.track(Base) or Revise.track(<stdlib module>)")
    track(Main, file; kwargs...)
end

"""
    includet(filename::AbstractString)

Load `filename` and track future changes. `includet` is intended for quick "user scripts"; larger or more
established projects are encouraged to put the code in one or more packages loaded with `using`
or `import` instead of using `includet`. See https://timholy.github.io/Revise.jl/stable/cookbook/
for tips about setting up the package workflow.

Like `include`, `includet` returns the value of the last evaluated expression in `filename`.

Unlike `include`, `includet` evaluates `filename` into `Main` rather than into the module from
which it is called. To evaluate into the caller's module instead, use [`@includet`](@ref) or pass
the module explicitly with `includet(mod, filename)`.

By default, `includet` only tracks modifications to *methods*, not *data*. See the extended help for details.
Note that this differs from packages, which evaluate all changes by default.
This default behavior can be overridden; see [Configuring the revise mode](@ref).

# Extended help

## Behavior and justification for the default revision mode (`:evalmeth`)

`includet` uses a default `__revise_mode__ = :evalmeth`. The consequence is that if you change

```
a = [1]
f() = 1
```
to
```
a = [2]
f() = 2
```
then Revise will update `f` but not `a`.

This is the default choice for `includet` because such files typically mix method definitions and data-handling.
Data often has many untracked dependencies; later in the same file you might `push!(a, 22)`, but Revise cannot
determine whether you wish it to re-run that line after redefining `a`.
Consequently, the safest default choice is to leave the user in charge of data.

## Workflow tips

If you have a series of computations that you want to run when you redefine your methods, consider separating
your method definitions from your computations:

- method definitions go in a package, or a file that you `includet` *once*
- the computations go in a separate file, that you re-`include` (no "t" at the end) each time you want to rerun
  your computations.

This can be automated using [`entr`](@ref).

## Internals

`includet` is essentially shorthand for

    Revise.track(Main, filename; mode=:includet, skip_include=true)

Do *not* use `includet` for packages, as those should be handled by `using` or `import`.
If `using` and `import` aren't working, you may have packages in a non-standard location;
try fixing it with something like `push!(LOAD_PATH, "/path/to/my/private/repos")`.
(If you're working with code in Base or one of Julia's standard libraries, use
`Revise.track(mod)` instead, where `mod` is the module.)

`includet` is deliberately non-recursive, so if `filename` loads any other files,
they will not be automatically tracked.
(Call [`Revise.track`](@ref) manually on each file, if you've already `included`d all the code you need.)
Multi-file code that needs all of its files tracked is better organized as a package loaded with
`using`/`import`, which Revise tracks recursively and which gives you a proper module namespace.
"""
function includet(mod::Module, file::AbstractString)
    prev = Base.source_path(nothing)
    file = if prev === nothing
        abspath(file)
    else
        normpath(joinpath(dirname(prev), file))
    end
    tls = task_local_storage()
    tls[:SOURCE_PATH] = file
    result = nothing
    try
        result = track(mod, file; mode=:includet, skip_include=true)
        if prev === nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    catch err
        if prev === nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
        if isa(err, ReviseEvalException)
            printstyled(stderr, "ERROR: "; color=Base.error_color());
            invokelatest(showerror, stderr, err; blame_revise=false)
            println(stderr, "\nin expression starting at ", err.loc)
        else
            rethrow()
        end
    end
    return result
end
includet(file::AbstractString) = includet(Main, file)

"""
    @includet "file.jl"

Load `file` and track future changes, evaluating its code into the module in which the macro
is expanded. This is the only difference from [`includet`](@ref): the function form always
evaluates into `Main` (or an explicitly-passed module), whereas `@includet` uses the caller's
module, just as `include` does.

Use `@includet` when calling from inside a module other than `Main`; at the REPL the two forms
are equivalent. The expansion is simply

    Revise.includet(@__MODULE__, file)
"""
macro includet(file)
    return :(includet($__module__, $(esc(file))))
end

"""
    Revise.silence(pkg)

Silence warnings about not tracking changes to package `pkg`.

The list of silenced packages is stored persistently using Preferences.jl.
See also [`Revise.unsilence`](@ref).
"""
silence(pkg::Symbol) = silence(String(pkg))
function silence(pkg::AbstractString)
    @lock revise_lock push!(silence_pkgs, pkg)
    Preferences.@set_preferences!("silenced_packages" => collect(silence_pkgs))
    nothing
end

"""
    Revise.unsilence(pkg)

Remove `pkg` from the list of silenced packages, re-enabling warnings about
not tracking changes to that package.

See also [`Revise.silence`](@ref).
"""
unsilence(pkg::Symbol) = unsilence(String(pkg))
function unsilence(pkg::AbstractString)
    @lock revise_lock delete!(silence_pkgs, pkg)
    Preferences.@set_preferences!("silenced_packages" => collect(silence_pkgs))
    nothing
end

"""
    Revise.dont_watch(pkg)

Prevent Revise from tracking changes to package `pkg`.

The list of excluded packages is stored persistently using Preferences.jl.
See also [`Revise.allow_watch`](@ref) and [`Revise.silence`](@ref).
"""
function dont_watch(pkg::Symbol)
    @lock revise_lock push!(dont_watch_pkgs, pkg)
    Preferences.@set_preferences!("dont_watch_packages" => String[string(p) for p in dont_watch_pkgs])
    nothing
end
dont_watch(pkg::AbstractString) = dont_watch(Symbol(pkg))

"""
    Revise.allow_watch(pkg)

Remove `pkg` from the list of excluded packages, allowing Revise to track
changes to that package again.

See also [`Revise.dont_watch`](@ref).
"""
function allow_watch(pkg::Symbol)
    @lock revise_lock delete!(dont_watch_pkgs, pkg)
    Preferences.@set_preferences!("dont_watch_packages" => String[string(p) for p in dont_watch_pkgs])
    nothing
end
allow_watch(pkg::AbstractString) = allow_watch(Symbol(pkg))

## Utilities

"""
    success = get_def(method::Method)

As needed, load the source file necessary for extracting the code defining `method`.
The source-file defining `method` must be tracked.
If it is in Base, this will execute `track(Base)` if necessary.

This is a callback function used by `CodeTracking.jl`'s `definition`.
"""
function get_def(method::Method; modified_files=revision_queue)
    yield()   # magic bug fix for the OSX test failures. TODO: figure out why this works (prob. Julia bug)
    if method.file === :none && String(method.name)[1] == '#'
        # This is likely to be a kwarg method, try to find something with location info
        method = bodymethod(method)
    end
    filename = fixpath(String(method.file))
    if startswith(filename, "REPL[")
        isdefined(Base, :active_repl) || return false
        fi = add_definitions_from_repl(filename)
        hassig = false
        for (_, exs_infos) in fi.mod_exs_infos
            for exinfos in values(exs_infos)
                hassig |= !isempty(exinfos)
            end
        end
        return hassig
    end
    id = get_tracked_id(method.module; modified_files=modified_files)
    id === nothing && return false
    pkgdata = @lock revise_lock pkgdatas[id]
    filename = relpath(filename, pkgdata)
    if hasfile(pkgdata, filename)
        def = get_def(method, pkgdata, filename)
        def !== nothing && return true
    end
    # Lookup can fail for macro-defined methods, see https://github.com/JuliaLang/julia/issues/31197
    # We need to find the right file.
    if method.module == Base || method.module == Core || method.module == Core.Compiler
        @warn "skipping $method to avoid parsing too much code" maxlog=1 _id=method
        CodeTracking.invoked_setindex!(CodeTracking.method_info, missing, MethodInfoKey(method))
        return false
    end
    parentfile, included_files = modulefiles(method.module)
    if parentfile !== nothing
        def = get_def(method, pkgdata, relpath(parentfile, pkgdata))
        def !== nothing && return true
        for modulefile in included_files
            def = get_def(method, pkgdata, relpath(modulefile, pkgdata))
            def !== nothing && return true
        end
    end
    # As a last resort, try every file in the package
    for file in srcfiles(pkgdata)
        def = get_def(method, pkgdata, file)
        def !== nothing && return true
    end
    @warn "$(method.sig)$(isdefined(method, :external_mt) ? " (overlayed)" : "") was not found"
    # So that we don't call it again, store missingness info in CodeTracking
    CodeTracking.invoked_setindex!(CodeTracking.method_info, missing, MethodInfoKey(method))
    return false
end

function get_def(method, pkgdata, filename)
    maybe_extract_sigs!(maybe_parse_from_cache!(pkgdata, filename))
    return get(CodeTracking.method_info, MethodInfoKey(method), nothing)
end

function get_tracked_id(id::PkgId; modified_files=revision_queue)
    # Methods from Base or the stdlibs may require that we start tracking
    if !haspkgdata(id)
        recipe = id.name === "Compiler" ? :Compiler : Symbol(id.name)
        recipe === :Core && return nothing
        _track(id, recipe; modified_files=modified_files)
        @info "tracking $recipe"
        if !haspkgdata(id)
            @warn "despite tracking $recipe, $id was not found"
            return nothing
        end
    end
    return id
end
get_tracked_id(mod::Module; modified_files=revision_queue) =
    get_tracked_id(PkgId(mod); modified_files=modified_files)

function get_expressions(id::PkgId, filename)
    get_tracked_id(id)
    pkgdata = @lock revise_lock pkgdatas[id]
    fi = maybe_parse_from_cache!(pkgdata, filename)
    maybe_extract_sigs!(fi)
    return fi.mod_exs_infos
end

function add_definitions_from_repl(filename::String)
    hist_idx = parse(Int, filename[6:end-1])
    hp = (Base.active_repl::REPL.LineEditREPL).interface.modes[1].hist::REPL.REPLHistoryProvider
    entry = hp.history[hp.start_idx+hist_idx]
    src = entry isa AbstractString ? entry : entry.content
    id = PkgId(nothing, "@REPL")
    pkgdata = @lock revise_lock pkgdatas[id]
    mod_exs_infos = ModuleExprsInfos(Main::Module)
    parse_and_maybe_eval_source!(mod_exs_infos, src, filename, Main::Module)
    instantiate_sigs!(mod_exs_infos)
    fi = FileInfo(mod_exs_infos)
    push!(pkgdata, filename=>fi)
    return fi
end
add_definitions_from_repl(filename::AbstractString) = add_definitions_from_repl(convert(String, filename)::String)

function update_stacktrace_lineno!(trace)
    local nrep
    for i = 1:length(trace)
        t = trace[i]
        has_nrep = !isa(t, StackTraces.StackFrame)
        if has_nrep
            t, nrep = t
        end
        t = t::StackTraces.StackFrame
        linfo = t.linfo
        if linfo isa Core.CodeInstance
            linfo = linfo.def
            @static if isdefined(Core, :ABIOverride)
                if isa(linfo, Core.ABIOverride)
                    linfo = linfo.def
                end
            end
        end
        if linfo isa Core.MethodInstance
            m = linfo.def
            # Why not just call `whereis`? Because that forces tracking. This is being
            # clever by recognizing that these entries exist only if there have been updates.
            updated = get(CodeTracking.method_info, MethodInfoKey(m), nothing)
            if updated !== nothing
                lnn = updated[1][1]     # choose the first entry by default
                lineoffset = lnn.line - m.line
                t = StackTraces.StackFrame(t.func, lnn.file, t.line+lineoffset, t.linfo, t.from_c, t.inlined, t.pointer)
                if has_nrep
                    @assert @isdefined(nrep) "Assertion to tell the compiler about the definedness of this variable"
                    trace[i] = t, nrep
                else
                    trace[i] = t
                end
            end
        end
    end
    return trace
end

function method_location(method::Method)
    # Why not just call `whereis`? Because that forces tracking. This is being
    # clever by recognizing that these entries exist only if there have been updates.
    updated = get(CodeTracking.method_info, MethodInfoKey(method), nothing)
    if updated !== nothing
        lnn = updated[1][1]
        return lnn.file, lnn.line
    end
    return method.file, method.line
end

# Set the prompt color to indicate the presence of unhandled revision errors
const original_repl_prefix = Ref{Union{String,Function,Nothing}}(nothing)
function maybe_set_prompt_color(color)
    isdefined(Base, :active_repl) || return nothing
    return set_prompt_color!(color, Base.active_repl)
end

function set_prompt_color!(color, repl)
    if isa(repl, REPL.LineEditREPL) && isdefined(repl, :interface)
        # Always recolor the `julia>` prompt, never whatever mode happens to
        # be active, so a revision error raised while in shell/help/pkg mode
        # does not leak that mode's color onto `julia>` (issue #755).
        julia_prompt = repl.interface.modes[1]
        if color === :warn
            # First save the original setting
            if original_repl_prefix[] === nothing
                original_repl_prefix[] = julia_prompt.prompt_prefix
            end
            julia_prompt.prompt_prefix = "\e[33m"  # yellow
        else
            color = original_repl_prefix[]
            color === nothing && return nothing
            julia_prompt.prompt_prefix = color
            original_repl_prefix[] = nothing
        end
    end
    return nothing
end

# `revise_first` gets called by the REPL prior to executing the next command (by having been pushed
# onto the `ast_transform` list).
# This uses invokelatest not for reasons of world age but to ensure that the call is made at runtime.
# This allows `revise_first` to be compiled without compiling `revise` itself, and greatly
# reduces the overhead of using Revise.
function revise_first(ex)
    # Special-case `exit()` (issue #562)
    if isa(ex, Expr)
        exu = unwrap(ex)
        if isexpr(exu, :block, 2)
            arg1 = exu.args[1]
            if isexpr(arg1, :softscope)
                exu = exu.args[2]
            end
        end

        # Try to detect shell mode in the REPL. Might also falsely trigger for certain
        # `julia>` mode commands, but 🤷
        if isexpr(exu, :call, 3) && exu.args[1] == :(Base.repl_cmd)
            return ex
        end

        if isa(exu, Expr)
            exu.head === :call && length(exu.args) == 1 && exu.args[1] === :exit && return ex
            lhsrhs = LoweredCodeUtils.get_lhs_rhs(exu)
            if lhsrhs !== nothing
                lhs, _ = lhsrhs
                if isexpr(lhs, :ref) && length(lhs.args) == 1
                    arg1 = lhs.args[1]
                    isexpr(arg1, :(.), 2) && arg1.args[1] === :Revise && is_quotenode_egal(arg1.args[2], :active) && return ex
                end
            end
        end
    end
    # Check for queued revisions, and if so call `revise` first before executing the expression
    return Expr(:toplevel, :($isempty($revision_queue) || $(Base.invokelatest)($revise)), ex)
end

steal_repl_backend(_...) = @warn """
    `steal_repl_backend` has been removed from Revise, please update your `~/.julia/config/startup.jl`.
    See https://timholy.github.io/Revise.jl/stable/config/
    """
wait_steal_repl_backend() = steal_repl_backend()
async_steal_repl_backend() = steal_repl_backend()

"""
    Revise.init_worker(p)

Define methods on worker `p` that Revise needs in order to perform revisions on `p`,
and replay onto `p` any revisions already applied on the master this session.
Revise itself does not need to be running on `p`.

Call this after the relevant packages have been loaded on `p` (e.g. via
`@everywhere using MyPkg`); otherwise the replayed revisions, which evaluate into
those modules, are silently skipped and `p` stays at the on-disk state. Replaying
is what keeps closures serialized across workers (such as `@distributed` bodies)
in sync after a revision, including for workers added later (issue #637).
"""
function init_worker(p::AbstractWorker)
    @invokelatest remotecall_impl(Core.eval, p, Main, quote
        function whichtt(mt::Union{Nothing, Core.MethodTable}, @nospecialize sig)
            ret = Base._methods_by_ftype(sig, mt, -1, Base.get_world_counter())
            isempty(ret) && return nothing
            m = ret[end][3]::Method   # the last method returned is the least-specific that matches, and thus most likely to be type-equal
            methsig = m.sig
            (sig <: methsig && methsig <: sig) || return nothing
            return m
        end
        function delete_method_by_sig(mt::Union{Nothing, Core.MethodTable}, @nospecialize sig)
            m = whichtt(mt, sig)
            isa(m, Method) && Base.delete_method(m)
        end
    end)
    @invokelatest(is_master_worker(p)) && return nothing
    actions = lock(revise_lock) do
        copy(worker_replay_log)
    end
    # Unlike the best-effort propagation during `revise`, this is an explicit
    # synchronization point: wait for each action so the worker is fully caught up
    # before `init_worker` returns and the caller starts dispatching work to it.
    for (mod, expr) in actions
        try
            @invokelatest wait(remotecall_impl(Core.eval, p, mod, expr))
        catch  # e.g. `mod` not loaded on the worker yet
        end
    end
    return nothing
end

init_worker(p::Int) = init_worker(DistributedWorker(p))

active_repl_backend_available() = isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing

# Wait for the REPL backend to come up, then register `revise_first` on it.
# #719: this runs async in case Revise is loaded from startup.jl, before the
# backend exists. issue #900: keep this a named function (not an anonymous
# `@async` closure) so it has a stable, precompilable signature.
function wait_for_repl_backend()
    iter = 0
    while !active_repl_backend_available() && iter < 20
        sleep(0.05)
        iter += 1
    end
    if active_repl_backend_available()
        push!(Base.active_repl_backend.ast_transforms, revise_first)
    end
    return nothing
end

function __init__()
    ccall(:jl_generating_output, Cint, ()) == 1 && return nothing
    run_on_worker = get(ENV, "JULIA_REVISE_WORKER_ONLY", "0")

    # Find the Distributed module if it's been loaded
    distributed_pkgid = Base.PkgId(Base.UUID("8ba89e20-285c-5b6f-9357-94700520ee1b"), "Distributed")
    distributed_module = get(Base.loaded_modules, distributed_pkgid, nothing)

    # We do a little hack to figure out if this is the master worker without
    # loading Distributed. When a worker is added with Distributed.addprocs() it
    # calls julia with the `--worker` flag. This is processed very early during
    # startup before any user code (e.g. through `-E`) is executed, so if
    # Distributed is *not* loaded already then we can be sure that this is the
    # master worker. And if it is loaded then we can just check
    # Distributed.myid() directly.
    if !(isnothing(distributed_module) || distributed_module.myid() == 1 || run_on_worker == "1")
        return nothing
    end

    # Pin Revise's own dispatch to the world it sees now, after Revise and its dependencies
    # are fully loaded (issue #552). See `advance_world!`.
    advance_world!()

    # Setting up the paths relative to package module location

    global basebuilddir = find_basebuilddir()
    global juliadir = find_juliadir()
    global basesrccache = normpath(joinpath(expected_juliadir(), "base.cache"))

    # Check Julia paths (issue #601)
    if !isdir(juliadir)
        @warn """Expected non-existent $juliadir to be your Julia directory.
                 Certain functionality will be disabled.
                 To fix this, try deleting Revise's cache files in $(revise_cache_dir()), then restart Julia and load Revise.
                 If this doesn't fix the problem, please report an issue at https://github.com/timholy/Revise.jl/issues."""
    end
    excluded = Preferences.@load_preference("dont_watch_packages", String[])
    for pkg in excluded
        push!(dont_watch_pkgs, Symbol(pkg))
    end
    silenced = Preferences.@load_preference("silenced_packages", String[])
    for pkg in silenced
        push!(silence_pkgs, pkg)
    end
    __bpart__[] = Base.VERSION >= v"1.12.0-DEV.2047" && Preferences.@load_preference("revise_structs", false)
    polling = get(ENV, "JULIA_REVISE_POLL", "0")
    if polling == "1"
        polling_files[] = watching_files[] = true
    end
    tracking_Main_includes[] = Base.get_bool_env("JULIA_REVISE_INCLUDE", false)
    # Correct line numbers for code moving around
    Base.update_stackframes_callback[] = update_stacktrace_lineno!
    if isdefined(Base, :methodloc_callback)
        Base.methodloc_callback[] = method_location
    end
    # Add `includet` to the compiled_modules (fixes #302)
    for m in methods(includet)
        push!(JuliaInterpreter.compiled_methods, m)
    end
    # Set up a repository for methods defined at the REPL
    id = PkgId(nothing, "@REPL")
    @lock revise_lock begin
        pkgdatas[id] = PkgData(id, nothing)
    end
    # Set the lookup callbacks
    CodeTracking.method_lookup_callback[] = get_def
    CodeTracking.expressions_callback[] = get_expressions

    # Watch the manifest file for changes
    mfile = manifest_file()
    if mfile !== nothing
        @lock revise_lock begin
            push!(watched_manifests, mfile)
            wmthunk = TaskThunk(watch_manifest, (mfile,))
            schedule(Task(wmthunk))
        end
    end
    push!(Base.include_callbacks, watch_includes)
    push!(Base.package_callbacks, watch_package_callback)

    mode = get(ENV, "JULIA_REVISE", "auto")
    if mode == "auto"
        pushfirst!(REPL.repl_ast_transforms, revise_first)
        # #664: once a REPL is started, it no longer interacts with REPL.repl_ast_transforms
        if active_repl_backend_available()
            push!(Base.active_repl_backend.ast_transforms, revise_first)
        else
            # wait for active_repl_backend to exist. Schedule the named function
            # directly (rather than `@async`, which wraps it in an anonymous
            # closure) so the task body carries a stable, precompilable signature.
            t = Task(wait_for_repl_backend)
            schedule(t)
            isdefined(Base, :errormonitor) && Base.errormonitor(t)
        end

        if isdefined(Main, :Atom)
            Atom = getfield(Main, :Atom)
            if Atom isa Module && isdefined(Atom, :handlers)
                setup_atom(Atom)
            end
        end
    end

    return nothing
end

const REVISE_ID = Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")
function watch_package_callback(id::PkgId)
    # `Base.package_callbacks` fire immediately after module initialization, and
    # would fire on Revise itself. This is not necessary for most users, and has
    # the downside that the user doesn't get to the REPL prompt until
    # `watch_package` finishes compiling.  To prevent this, Revise hides the
    # actual `watch_package` method behind `frozen` (a world-pinned `invoke_in_world`),
    # whose runtime dispatch also delays compilation of everything `watch_package` requires,
    # leading to faster perceived startup times.
    if id != REVISE_ID
        frozen(watch_package, id)
    end
    return
end

function setup_atom(atommod::Module)::Nothing
    handlers = getfield(atommod, :handlers)
    for x in ["eval", "evalall", "evalshow", "evalrepl"]
        if haskey(handlers, x)
            old = handlers[x]
            Main.Atom.handle(x) do data
                revise()
                old(data)
            end
        end
    end
    return nothing
end

function add_revise_deps()
    # Populate CodeTracking data for dependencies and initialize watching on code that Revise depends on
    @lock revise_lock begin
        for mod in (CodeTracking, OrderedCollections, JuliaInterpreter, LoweredCodeUtils, Revise)
            id = PkgId(mod)
            pkgdata = parse_pkg_files(id)
            init_watching(pkgdata, srcfiles(pkgdata))
            pkgdatas[id] = pkgdata
        end
    end
    return nothing
end

include("precompile.jl")
_precompile_()
