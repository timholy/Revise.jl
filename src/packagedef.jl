Base.Experimental.@optlevel 1

using FileWatching, REPL, UUIDs
using LibGit2: LibGit2
using Base: PkgId
using Base.Meta: isexpr
using Core: CodeInfo, MethodTable

export revise, includet, entr, MethodSummary

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
function wait_changed(file)
    try
        polling_files[] ? poll_file(file) : watch_file(file)
    catch err
        if Sys.islinux() && err isa Base.IOError && err.code == -28  # ENOSPC
            @warn """Your operating system has run out of inotify capacity.
            Check the current value with `cat /proc/sys/fs/inotify/max_user_watches`.
            Set it to a higher level with, e.g., `echo 65536 | sudo tee -a /proc/sys/fs/inotify/max_user_watches`.
            This requires having administrative privileges on your machine (or talk to your sysadmin).
            See https://github.com/timholy/Revise.jl/issues/26 for more information."""
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
include("pkgs.jl")
include("git.jl")
include("recipes.jl")
include("logging.jl")
include("callbacks.jl")

### Globals to keep track of state

"""
    Revise.watched_files

Global variable, `watched_files[dirname]` returns the collection of files in `dirname`
that we're monitoring for changes. The returned value has type [`Revise.WatchList`](@ref).

This variable allows us to watch directories rather than files, reducing the burden on
the OS.
"""
const watched_files = Dict{String,WatchList}()
const watched_files_lock = ReentrantLock()

"""
    Revise.watched_manifests

Global variable, a set of `Manifest.toml` files from the active projects used during this session.
"""
const watched_manifests = Set{String}()
const watched_manifests_lock = ReentrantLock()

"""
    Revise.revision_queue

Global variable, `revision_queue` holds `(pkgdata,filename)` pairs that we need to revise, meaning
that these files have changed since we last processed a revision.
This list gets populated by callbacks that watch directories for updates.
"""
const revision_queue = Set{Tuple{PkgData,String}}()
const revision_queue_lock = ReentrantLock() # see issues #837 and #845

"""
    Revise.queue_errors

Global variable, maps `(pkgdata, filename)` pairs that errored upon last revision to
`(exception, backtrace)`.
"""
const queue_errors = Dict{Tuple{PkgData,String},Tuple{Exception, Any}}() # locking is covered by revision_queue_lock

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
const pkgdatas_lock = ReentrantLock()

"""
    Revise.included_files

Global variable, `included_files` gets populated by callbacks we register with `include`.
It's used to track non-precompiled packages and, optionally, user scripts (see docs on
`JULIA_REVISE_INCLUDE`).
"""
const included_files = Tuple{Module,String}[]  # (module, filename)
const included_files_lock = ReentrantLock()    # issue #947

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
const basebuilddir = begin
    sysimg = filter(x->endswith(x[2], "sysimg.jl"), Base._included_files)[1][2]
    dirname(dirname(sysimg))
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

Global variable, use `push!(Revise.dont_watch_pkgs, :MyPackage)` to prevent Revise
from tracking changes to `MyPackage`. You can do this from the REPL or from your
`.julia/config/startup.jl` file.

See also [`Revise.silence`](@ref).
"""
const dont_watch_pkgs = Set{Symbol}()
const silence_pkgs = Set{String}()

##
## The inputs are sets of expressions found in each file.
## Some of those expressions will generate methods which are identified via their signatures.
## From "old" expressions we know their corresponding signatures, but from "new"
## expressions we have not yet computed them. This makes old and new asymmetric.
##
## Strategy:
## - For every old expr not found in the new ones,
##     + delete the corresponding methods (using the signatures we've previously computed)
##     + remove the sig entries from CodeTracking.method_info  (")
##   Best to do all the deletion first (across all files and modules) in case a method is
##   simply being moved from one file to another.
## - For every new expr found among the old ones,
##     + update the location info in CodeTracking.method_info
## - For every new expr not found in the old ones,
##     + eval the expr
##     + extract signatures
##     + add to the ModuleExprsSigs
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

function delete_missing!(exs_sigs_old::ExprsSigs, exs_sigs_new::ExprsSigs)
    with_logger(_debug_logger) do
        for (ex, siginfos) in exs_sigs_old
            haskey(exs_sigs_new, ex) && continue
            # ex was deleted
            siginfos === nothing && continue
            for siginfo in siginfos
                mt, sig = siginfo
                ret = Base._methods_by_ftype(sig, mt, -1, Base.get_world_counter())
                success = false
                if !isempty(ret)
                    m = ret[end].method  # the last method returned is the least-specific that matches, and thus most likely to be type-equal
                    methsig = m.sig
                    if sig <: methsig && methsig <: sig
                        locdefs = get(CodeTracking.method_info, MethodInfoKey(siginfo), nothing)
                        if isa(locdefs, Vector{Tuple{LineNumberNode,Expr}})
                            if length(locdefs) > 1
                                # Just delete this reference but keep the method
                                line = firstline(ex)
                                ld = map(pr->linediff(line, pr[1]), locdefs)
                                idx = argmin(ld)
                                @assert ld[idx] < typemax(eltype(ld))
                                deleteat!(locdefs, idx)
                                continue
                            else
                                @assert length(locdefs) == 1
                            end
                        end
                        @debug "DeleteMethod" _group="Action" time=time() deltainfo=(sig, MethodSummary(m))
                        # Delete the corresponding methods
                        for get_workers in workers_functions
                            for p in @invokelatest get_workers()
                                try  # guard against serialization errors if the type isn't defined on the worker
                                    @invokelatest remotecall_impl(Core.eval, p, Main, :(delete_method_by_sig($mt, $sig)))
                                catch
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
                        success = true
                    end
                end
                if !success
                    @debug "FailedDeletion" _group="Action" time=time() deltainfo=(sig,)
                end
            end
        end
    end
    return exs_sigs_old
end

const empty_exs_sigs = ExprsSigs()
function delete_missing!(mod_exs_sigs_old::ModuleExprsSigs, mod_exs_sigs_new::ModuleExprsSigs)
    for (mod, exs_sigs_old) in mod_exs_sigs_old
        exs_sigs_new = get(mod_exs_sigs_new, mod, empty_exs_sigs)
        delete_missing!(exs_sigs_old, exs_sigs_new)
    end
    return mod_exs_sigs_old
end

function eval_rex(rex_new::RelocatableExpr, exs_sigs_old::ExprsSigs, mod::Module; mode::Symbol=:eval)
    return with_logger(_debug_logger) do
        siginfos, includes = nothing, nothing
        rex_old = getkey(exs_sigs_old, rex_new, nothing)
        # extract the signatures and update the line info
        if rex_old === nothing
            ex = rex_new.ex
            # ex is not present in old
            @debug titlecase(String(mode)) _group="Action" time=time() deltainfo=(mod, ex, mode)
            siginfos, includes, thunk = eval_with_signatures(mod, ex; mode)  # All signatures defined by `ex`
            if !isexpr(thunk, :thunk)
                thunk = ex
            end
            for get_workers in workers_functions
                if @invokelatest is_master_worker(get_workers)
                    for p in @invokelatest get_workers()
                        @invokelatest(is_master_worker(p)) && continue
                        try   # don't error if `mod` isn't defined on the worker
                            @invokelatest remotecall_impl(Core.eval, p, mod, thunk)
                        catch
                        end
                    end
                end
            end
        else
            siginfos = exs_sigs_old[rex_old]
            # Update location info
            ln, lno = firstline(unwrap(rex_new)), firstline(unwrap(rex_old))
            if siginfos !== nothing && !isempty(siginfos) && ln != lno
                ln, lno = ln::LineNumberNode, lno::LineNumberNode
                @debug "LineOffset" _group="Action" time=time() deltainfo=(siginfos, lno=>ln)
                for siginfo in siginfos
                    locdefs = CodeTracking.method_info[MethodInfoKey(siginfo)]::AbstractVector
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
        return siginfos, includes
    end
end

# These are typically bypassed in favor of expression-by-expression evaluation to
# allow handling of new `include` statements.
function eval_new!(exs_sigs_new::ExprsSigs, exs_sigs_old::ExprsSigs, mod::Module; mode::Symbol=:eval)
    includes = Vector{Pair{Module,String}}()
    for rex in keys(exs_sigs_new)
        siginfos, _includes = eval_rex(rex, exs_sigs_old, mod; mode)
        if siginfos !== nothing
            exs_sigs_new[rex] = siginfos
        end
        if _includes !== nothing
            append!(includes, _includes)
        end
    end
    return exs_sigs_new, includes
end

function eval_new!(mod_exs_sigs_new::ModuleExprsSigs, mod_exs_sigs_old::ModuleExprsSigs; mode::Symbol=:eval)
    includes = Vector{Pair{Module,String}}()
    for (mod, exs_sigs_new) in mod_exs_sigs_new
        # Allow packages to override the supplied mode
        if isdefined(mod, :__revise_mode__)
            mode = getfield(mod, :__revise_mode__)::Symbol
        end
        exs_sigs_old = get(mod_exs_sigs_old, mod, empty_exs_sigs)
        _, _includes = eval_new!(exs_sigs_new, exs_sigs_old, mod; mode)
        append!(includes, _includes)
    end
    return mod_exs_sigs_new, includes
end

"""
    CodeTrackingMethodInfo(ex::Expr)

Create a cache for storing information about method definitions.
Adding signatures to such an object inserts them into `CodeTracking.method_info`,
which maps signature Tuple-types to `(lnn::LineNumberNode, ex::Expr)` pairs.
Because method signatures are unique within a module, this is the foundation for
identifying methods in a manner independent of source-code location.

It also has the following fields:

- `exprstack`: used when descending into `@eval` statements (via `push_expr` and `pop_expr!`)
  `ex` (used in creating the `CodeTrackingMethodInfo` object) is the first entry in the stack.
- `allsigs`: a list of all method signatures defined by a given expression
- `includes`: a list of `module=>filename` for any `include` statements encountered while the
  expression was parsed.
"""
struct CodeTrackingMethodInfo
    exprstack::Vector{Expr}
    allsigs::Vector{SigInfo}
    includes::Vector{Pair{Module,String}}
end
CodeTrackingMethodInfo(ex::Expr) = CodeTrackingMethodInfo([ex], SigInfo[], Pair{Module,String}[])

function add_signature!(methodinfo::CodeTrackingMethodInfo, mt_sig::MethodInfoKey, ln::LineNumberNode)
    locdefs = CodeTracking.invoked_get!(Vector{Tuple{LineNumberNode,Expr}}, CodeTracking.method_info, mt_sig)
    newdef = unwrap(methodinfo.exprstack[end])
    if newdef !== nothing
        if !any(locdef->locdef[1] == ln && isequal(RelocatableExpr(locdef[2]), RelocatableExpr(newdef)), locdefs)
            push!(locdefs, (fixpath(ln), newdef))
        end
        push!(methodinfo.allsigs, SigInfo(mt_sig))
    end
    return methodinfo
end
push_expr!(methodinfo::CodeTrackingMethodInfo, ex::Expr) = (push!(methodinfo.exprstack, ex); methodinfo)
pop_expr!(methodinfo::CodeTrackingMethodInfo) = (pop!(methodinfo.exprstack); methodinfo)
function add_includes!(methodinfo::CodeTrackingMethodInfo, mod::Module, filename)
    push!(methodinfo.includes, mod=>filename)
    return methodinfo
end

# Eval and insert into CodeTracking data
function eval_with_signatures(mod::Module, ex::Expr; mode::Symbol=:eval, kwargs...)
    methodinfo = CodeTrackingMethodInfo(ex)
    _, thk = methods_by_execution!(methodinfo, mod, ex; mode, kwargs...)
    return methodinfo.allsigs, methodinfo.includes, thk
end

function instantiate_sigs!(mod_exs_sigs::ModuleExprsSigs; mode::Symbol=:sigs, kwargs...)
    for (mod, exsigs) in mod_exs_sigs
        for rex in keys(exsigs)
            is_doc_expr(rex.ex) && continue
            exsigs[rex], _ = eval_with_signatures(mod, rex.ex; mode, kwargs...)
        end
    end
    return mod_exs_sigs
end

# This is intended for testing purposes, but not general use. The key problem is
# that it doesn't properly handle methods that move from one file to another; there is the
# risk you could end up deleting the method altogether depending on the order in which you
# process these.
# See `revise` for the proper approach.
function eval_revised(mod_exs_sigs_new::ModuleExprsSigs, mod_exs_sigs_old::ModuleExprsSigs)
    delete_missing!(mod_exs_sigs_old, mod_exs_sigs_new)
    eval_new!(mod_exs_sigs_new, mod_exs_sigs_old)  # note: drops `includes`
    instantiate_sigs!(mod_exs_sigs_new)
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
        already_watching_dir = haskey(watched_files, dirfull)
        @lock watched_files_lock begin
            already_watching_dir || (watched_files[dirfull] = WatchList())
        end
        watchlist = watched_files[dirfull]
        current_id = get(watchlist.trackedfiles, basename, nothing)
        new_id = pkgdata.info.id
        if new_id != NOPACKAGE || current_id === nothing
            # Allow the package id to be updated
            push!(watchlist, basename=>pkgdata)
            if watching_files[]
                fwatcher = TaskThunk(revise_file_queued, (pkgdata, file))
                schedule(Task(fwatcher))
            else
                already_watching_dir || push!(udirs, dir)
            end
        end
    end
    for dir in udirs
        dirfull = joinpath(basedir(pkgdata), dir)
        @lock watched_files_lock updatetime!(watched_files[dirfull])
        if !watching_files[]
            dwatcher = TaskThunk(revise_dir_queued, (dirfull,))
            schedule(Task(dwatcher))
        end
    end
    return nothing
end
init_watching(files) = init_watching(pkgdatas[NOPACKAGE], files)

"""
    revise_dir_queued(dirname::AbstractString)

Wait for one or more of the files registered in `Revise.watched_files[dirname]` to be
modified, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called via a [`Revise.TaskThunk`](@ref).
"""
@noinline function revise_dir_queued(dirname::AbstractString)
    @assert isabspath(dirname)
    if !isdir(dirname)
        sleep(0.1)   # in case git has done a delete/replace cycle
    end
    stillwatching = true
    while stillwatching
        if !isdir(dirname)
            with_logger(SimpleLogger(stderr)) do
                @warn "$dirname is not an existing directory, Revise is not watching"
            end
            break
        end

        latestfiles, stillwatching = watch_files_via_dir(dirname)  # will block here until file(s) change
        for (file, id) in latestfiles
            key = joinpath(dirname, file)
            if key in keys(user_callbacks_by_file)
                union!(user_callbacks_queue, user_callbacks_by_file[key])
                notify(revision_event)
            end
            if id != NOPACKAGE
                pkgdata = pkgdatas[id]
                lock(revision_queue_lock) do
                    if hasfile(pkgdata, key)  # issue #228
                        push!(revision_queue, (pkgdata, relpath(key, pkgdata)))
                        notify(revision_event)
                    end
                end
            end
        end
    end
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
    if !file_exists(file)
        sleep(0.1)  # in case git has done a delete/replace cycle
    end

    dirfull, _ = splitdir(file)
    stillwatching = true
    while stillwatching
        if !file_exists(file) && !isdir(file)
            let file=file
                with_logger(SimpleLogger(stderr)) do
                    @warn "$file is not an existing file, Revise is not watching"
                end
            end
            notify(revision_event)
            break
        end
        try
            wait_changed(file)  # will block here until the file changes
        catch e
            # issue #459
            (isa(e, InterruptException) && throwto_repl(e)) || throw(e)
        end

        if file in keys(user_callbacks_by_file)
            union!(user_callbacks_queue, user_callbacks_by_file[file])
            notify(revision_event)
        end

        # Check to see if we're still watching this file
        stillwatching = haskey(watched_files, dirfull)
        if PkgId(pkgdata) != NOPACKAGE
            lock(revision_queue_lock) do
                push!(revision_queue, (pkgdata, relpath(file, pkgdata)))
            end
        end
    end
    return
end

# Because we delete first, we have to make sure we've parsed the file
function handle_deletions(pkgdata, file)
    fi = maybe_parse_from_cache!(pkgdata, file)
    maybe_extract_sigs!(fi)
    mod_exs_sigs_old = fi.modexsigs
    idx = fileindex(pkgdata, file)
    filep = pkgdata.info.files[idx]
    if isa(filep, AbstractString)
        if file ≠ "."
            filep = normpath(basedir(pkgdata), file)
        else
            filep = normpath(basedir(pkgdata))
        end
    end
    topmod = first(keys(mod_exs_sigs_old))
    fileok = file_exists(String(filep)::String)
    mod_exs_sigs_new = fileok ? parse_source(filep, topmod) : ModuleExprsSigs(topmod)
    if mod_exs_sigs_new !== nothing && mod_exs_sigs_new !== DoNotParse()
        delete_missing!(mod_exs_sigs_old, mod_exs_sigs_new)
    end
    if !fileok
        @warn("$filep no longer exists, deleted all methods")
        deleteat!(pkgdata.fileinfos, idx)
        deleteat!(pkgdata.info.files, idx)
        wl = get(watched_files, basedir(pkgdata), nothing)
        if isa(wl, WatchList)
            delete!(wl.trackedfiles, file)
        end
    end
    return mod_exs_sigs_new, mod_exs_sigs_old
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
    i = fileindex(pkgdata, file)
    if i === nothing
        println("Revise is currently tracking the following files in $(PkgId(pkgdata)): ", srcfiles(pkgdata))
        error(file, " is not currently being tracked.")
    end
    mexsnew, mexsold = handle_deletions(pkgdata, file)
    if mexsnew != nothing
        _, includes = eval_new!(mexsnew, mexsold)
        fi = fileinfo(pkgdata, i)
        pkgdata.fileinfos[i] = FileInfo(mexsnew, fi)
        maybe_add_includes_to_pkgdata!(pkgdata, file, includes; eval_now=true)
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
    lock(revision_queue_lock) do
        for k in keys(queue_errors)
            push!(revision_queue, k)
        end
    end
    revise()
end

"""
    revise(; throw=false)

`eval` any changes in the revision queue. See [`Revise.revision_queue`](@ref).
If `throw` is `true`, throw any errors that occur during revision or callback;
otherwise these are only logged.
"""
function revise(; throw::Bool=false)
    active[] || return nothing
    sleep(0.01)  # in case the file system isn't quite done writing out the new files
    lock(revision_queue_lock) do
        have_queue_errors = !isempty(queue_errors)

        # Do all the deletion first. This ensures that a method that moved from one file to another
        # won't get redefined first and deleted second.
        revision_errors = Tuple{PkgData,String}[]
        queue = sort!(collect(revision_queue); lt=pkgfileless)
        finished = eltype(revision_queue)[]
        mexsnews = ModuleExprsSigs[]
        interrupt = false
        for (pkgdata, file) in queue
            try
                mexsnew, _ = handle_deletions(pkgdata, file)
                mexsnew === DoNotParse() && continue
                push!(mexsnews, mexsnew)
                push!(finished, (pkgdata, file))
            catch err
                throw && Base.throw(err)
                interrupt |= isa(err, InterruptException)
                push!(revision_errors, (pkgdata, file))
                queue_errors[(pkgdata, file)] = (err, catch_backtrace())
            end
        end
        # Do the evaluation
        for ((pkgdata, file), mexsnew) in zip(finished, mexsnews)
            defaultmode = PkgId(pkgdata).name == "Main" ? :evalmeth : :eval
            i = fileindex(pkgdata, file)
            i === nothing && continue   # file was deleted by `handle_deletions`
            fi = fileinfo(pkgdata, i)
            modsremaining = Set(keys(mexsnew))
            changed, err = true, nothing
            while changed
                changed = false
                for (mod, exsnew) in mexsnew
                    mod ∈ modsremaining || continue
                    try
                        mode = defaultmode
                        # Allow packages to override the supplied mode
                        if isdefined(mod, :__revise_mode__)
                            mode = getfield(mod, :__revise_mode__)::Symbol
                        end
                        mode ∈ (:sigs, :eval, :evalmeth, :evalassign) || error("unsupported mode ", mode)
                        exsold = get(fi.modexsigs, mod, empty_exs_sigs)
                        for rex in keys(exsnew)
                            siginfos, includes = eval_rex(rex, exsold, mod; mode)
                            if siginfos !== nothing
                                exsnew[rex] = siginfos
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
                pkgdata.fileinfos[i] = FileInfo(mexsnew, fi)
            end
            if isempty(modsremaining)
                delete!(queue_errors, (pkgdata, file))
            else
                throw && Base.throw(err)
                interrupt |= isa(err, InterruptException)
                push!(revision_errors, (pkgdata, file))
                queue_errors[(pkgdata, file)] = (err, catch_backtrace())
            end
        end
        if interrupt
            for pkgfile in finished
                haskey(queue_errors, pkgfile) || delete!(revision_queue, pkgfile)
            end
        else
            empty!(revision_queue)
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
                maybe_set_prompt_color(:warn)
            end
        else
            maybe_set_prompt_color(:ok)
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
function revise(mod::Module; force::Bool=true)
    mod == Main && error("cannot revise(Main)")
    id = PkgId(mod)
    pkgdata = pkgdatas[id]
    for file in pkgdata.info.files
        push!(revision_queue, (pkgdata, file))
    end
    revise()
    force || return true
    for i = 1:length(srcfiles(pkgdata))
        fi = fileinfo(pkgdata, i)
        for (mod, exsigs) in fi.modexsigs
            for def in keys(exsigs)
                ex = def.ex
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
    return true  # fixme try/catch?
end

"""
    Revise.track(mod::Module, file::AbstractString)
    Revise.track(file::AbstractString)

Watch `file` for updates and [`revise`](@ref) loaded code with any
changes. `mod` is the module into which `file` is evaluated; if omitted,
it defaults to `Main`.

If this produces many errors, check that you specified `mod` correctly.
"""
function track(mod::Module, file::AbstractString; mode=:sigs, kwargs...)
    isfile(file) || error(file, " is not a file")
    # Determine whether we're already tracking this file
    id = Base.moduleroot(mod) == Main ? PkgId(mod, string(mod)) : PkgId(mod)  # see #689 for `Main`
    if haskey(pkgdatas, id)
        pkgdata = pkgdatas[id]
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
    mod_exs_sigs = parse_source(file, mod; mode)
    if mod_exs_sigs !== nothing
        if mode === :includet
            mode = :sigs   # we already handled evaluation in `parse_source`
        end
        instantiate_sigs!(mod_exs_sigs; mode, kwargs...)
        if !haskey(pkgdatas, id)
            # Wait a bit to see if `mod` gets initialized
            sleep(0.1)
        end
        pkgdata = get(pkgdatas, id, nothing)
        if pkgdata === nothing
            pkgdata = PkgData(id, pathof(mod))
        end
        if !haskey(CodeTracking._pkgfiles, id)
            CodeTracking._pkgfiles[id] = pkgdata.info
        end
        @lock pkgdatas_lock begin
            push!(pkgdata, relpath(file, pkgdata)=>FileInfo(mod_exs_sigs))
            init_watching(pkgdata, (String(file)::String,))
            pkgdatas[id] = pkgdata
        end
    end
    return nothing
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
    try
        track(mod, file; mode=:includet, skip_include=true)
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
    return nothing
end
includet(file::AbstractString) = includet(Main, file)

"""
    Revise.silence(pkg)

Silence warnings about not tracking changes to package `pkg`.

The list of silenced packages is stored persistently using Preferences.jl.
See also [`Revise.unsilence`](@ref).
"""
silence(pkg::Symbol) = silence(String(pkg))
function silence(pkg::AbstractString)
    push!(silence_pkgs, pkg)
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
    delete!(silence_pkgs, pkg)
    Preferences.@set_preferences!("silenced_packages" => collect(silence_pkgs))
    nothing
end

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
        for (_, exs) in fi.modexsigs
            for siginfos in values(exs)
                hassig |= !isempty(siginfos)
            end
        end
        return hassig
    end
    id = get_tracked_id(method.module; modified_files=modified_files)
    id === nothing && return false
    pkgdata = pkgdatas[id]
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
    if !haskey(pkgdatas, id)
        recipe = id.name === "Compiler" ? :Compiler : Symbol(id.name)
        recipe === :Core && return nothing
        _track(id, recipe; modified_files=modified_files)
        @info "tracking $recipe"
        if !haskey(pkgdatas, id)
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
    pkgdata = pkgdatas[id]
    fi = maybe_parse_from_cache!(pkgdata, filename)
    maybe_extract_sigs!(fi)
    return fi.modexsigs
end

function add_definitions_from_repl(filename::String)
    hist_idx = parse(Int, filename[6:end-1])
    hp = (Base.active_repl::REPL.LineEditREPL).interface.modes[1].hist::REPL.REPLHistoryProvider
    src = hp.history[hp.start_idx+hist_idx]
    id = PkgId(nothing, "@REPL")
    pkgdata = pkgdatas[id]
    mod_exs_sigs = ModuleExprsSigs(Main::Module)
    parse_source!(mod_exs_sigs, src, filename, Main::Module)
    instantiate_sigs!(mod_exs_sigs)
    fi = FileInfo(mod_exs_sigs)
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
    if isdefined(Base, :active_repl)
        repl = Base.active_repl
        if isa(repl, REPL.LineEditREPL)
            if color === :warn
                # First save the original setting
                if original_repl_prefix[] === nothing
                    original_repl_prefix[] = repl.mistate.current_mode.prompt_prefix
                end
                repl.mistate.current_mode.prompt_prefix = "\e[33m"  # yellow
            else
                color = original_repl_prefix[]
                color === nothing && return nothing
                repl.mistate.current_mode.prompt_prefix = color
                original_repl_prefix[] = nothing
            end
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

Define methods on worker `p` that Revise needs in order to perform revisions on `p`.
Revise itself does not need to be running on `p`.
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
end

init_worker(p::Int) = init_worker(DistributedWorker(p))

active_repl_backend_available() = isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing

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

    # Setting up the paths relative to package module location

    global juliadir = find_juliadir()
    global basesrccache = normpath(joinpath(expected_juliadir(), "base.cache"))

    # Check Julia paths (issue #601)
    if !isdir(juliadir)
        major, minor = Base.VERSION.major, Base.VERSION.minor
        @warn """Expected non-existent $juliadir to be your Julia directory.
                 Certain functionality will be disabled.
                 To fix this, try deleting Revise's cache files in ~/.julia/compiled/v$major.$minor/Revise, then restart Julia and load Revise.
                 If this doesn't fix the problem, please report an issue at https://github.com/timholy/Revise.jl/issues."""
    end
    silenced = Preferences.@load_preference("silenced_packages", String[])
    for pkg in silenced
        push!(silence_pkgs, pkg)
    end
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
    @lock pkgdatas_lock begin
        pkgdatas[id] = PkgData(id, nothing)
    end
    # Set the lookup callbacks
    CodeTracking.method_lookup_callback[] = get_def
    CodeTracking.expressions_callback[] = get_expressions

    # Watch the manifest file for changes
    mfile = manifest_file()
    if mfile !== nothing
        @lock watched_manifests_lock begin
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
            # wait for active_repl_backend to exist
            # #719: do this async in case Revise is being loaded from startup.jl
            t = @async begin
                iter = 0
                while !active_repl_backend_available() && iter < 20
                    sleep(0.05)
                    iter += 1
                end
                if active_repl_backend_available()
                    push!(Base.active_repl_backend.ast_transforms, revise_first)
                end
            end
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
    # actual `watch_package` method behind an `invokelatest`. This delays
    # compilation of everything that `watch_package` requires, leading to faster
    # perceived startup times.
    if id != REVISE_ID
        Base.invokelatest(watch_package, id)
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
    @lock pkgdatas_lock begin
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
