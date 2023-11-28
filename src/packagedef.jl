@eval Base.Experimental.@optlevel 1

using FileWatching, REPL, Distributed, UUIDs, Pkg
import LibGit2
using Base: PkgId
using Base.Meta: isexpr
using Core: CodeInfo

export revise, includet, entr, MethodSummary

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
const queue_errors = Dict{Tuple{PkgData,String},Tuple{Exception, Any}}()

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

const moduledeps = Dict{Module,DepDict}()
function get_depdict(mod::Module)
    if !haskey(moduledeps, mod)
        moduledeps[mod] = DepDict()
    end
    return moduledeps[mod]
end

"""
    Revise.included_files

Global variable, `included_files` gets populated by callbacks we register with `include`.
It's used to track non-precompiled packages and, optionally, user scripts (see docs on
`JULIA_REVISE_INCLUDE`).
"""
const included_files = Tuple{Module,String}[]  # (module, filename)

"""
    Revise.basesrccache

Full path to the running Julia's cache of source code defining `Base`.
"""
const basesrccache = normpath(joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base.cache"))

"""
    Revise.basebuilddir

Julia's top-level directory when Julia was built, as recorded by the entries in
`Base._included_files`.
"""
const basebuilddir = begin
    sysimg = filter(x->endswith(x[2], "sysimg.jl"), Base._included_files)[1][2]
    dirname(dirname(sysimg))
end

function fallback_juliadir()
    candidate = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
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

"""
    Revise.juliadir

Constant specifying full path to julia top-level source directory.
This should be reliable even for local builds, cross-builds, and binary installs.
"""
const juliadir = normpath(
    if isdir(joinpath(basebuilddir, "base"))
        basebuilddir
    else
        fallback_juliadir()  # Binaries probably end up here. We fall back on Sys.BINDIR
    end
)

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
const silence_pkgs = Set{Symbol}()
const depsdir = joinpath(dirname(@__DIR__), "deps")
const silencefile = Ref(joinpath(depsdir, "silence.txt"))  # Ref so that tests don't clobber

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
## Interestingly, the ex=>sigs link may not be the same as the sigs=>ex link.
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

get_method_from_match(mm::Core.MethodMatch) = mm.method

function delete_missing!(exs_sigs_old::ExprsSigs, exs_sigs_new)
    with_logger(_debug_logger) do
        for (ex, sigs) in exs_sigs_old
            haskey(exs_sigs_new, ex) && continue
            # ex was deleted
            sigs === nothing && continue
            for sig in sigs
                @static if VERSION ≥ v"1.10.0-DEV.873"
                    ret = Base._methods_by_ftype(sig, -1, Base.get_world_counter())
                else
                    ret = Base._methods_by_ftype(sig, -1, typemax(UInt))
                end
                success = false
                if !isempty(ret)
                    m = get_method_from_match(ret[end])   # the last method returned is the least-specific that matches, and thus most likely to be type-equal
                    methsig = m.sig
                    if sig <: methsig && methsig <: sig
                        locdefs = get(CodeTracking.method_info, sig, nothing)
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
                        for p in workers()
                            try  # guard against serialization errors if the type isn't defined on the worker
                                remotecall(Core.eval, p, Main, :(delete_method_by_sig($sig)))
                            catch
                            end
                        end
                        Base.delete_method(m)
                        # Remove the entries from CodeTracking data
                        delete!(CodeTracking.method_info, sig)
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
function delete_missing!(mod_exs_sigs_old::ModuleExprsSigs, mod_exs_sigs_new)
    for (mod, exs_sigs_old) in mod_exs_sigs_old
        exs_sigs_new = get(mod_exs_sigs_new, mod, empty_exs_sigs)
        delete_missing!(exs_sigs_old, exs_sigs_new)
    end
    return mod_exs_sigs_old
end

function eval_rex(rex::RelocatableExpr, exs_sigs_old::ExprsSigs, mod::Module; mode::Symbol=:eval)
    return with_logger(_debug_logger) do
        sigs, includes = nothing, nothing
        rexo = getkey(exs_sigs_old, rex, nothing)
        # extract the signatures and update the line info
        if rexo === nothing
            ex = rex.ex
            # ex is not present in old
            @debug "Eval" _group="Action" time=time() deltainfo=(mod, ex)
            sigs, deps, includes, thunk = eval_with_signatures(mod, ex; mode=mode)  # All signatures defined by `ex`
            if !isexpr(thunk, :thunk)
                thunk = ex
            end
            if myid() == 1
                for p in workers()
                    p == myid() && continue
                    try   # don't error if `mod` isn't defined on the worker
                        remotecall(Core.eval, p, mod, thunk)
                    catch
                    end
                end
            end
            storedeps(deps, rex, mod)
        else
            sigs = exs_sigs_old[rexo]
            # Update location info
            ln, lno = firstline(unwrap(rex)), firstline(unwrap(rexo))
            if sigs !== nothing && !isempty(sigs) && ln != lno
                ln, lno = ln::LineNumberNode, lno::LineNumberNode
                @debug "LineOffset" _group="Action" time=time() deltainfo=(sigs, lno=>ln)
                for sig in sigs
                    locdefs = CodeTracking.method_info[sig]::AbstractVector
                    ld = map(pr->linediff(lno, pr[1]), locdefs)
                    idx = argmin(ld)
                    if ld[idx] === typemax(eltype(ld))
                        # println("Missing linediff for $lno and $(first.(locdefs)) with ", rex.ex)
                        idx = length(locdefs)
                    end
                    methloc, methdef = locdefs[idx]
                    locdefs[idx] = (newloc(methloc, ln, lno), methdef)
                end
            end
        end
        return sigs, includes
    end
end

# These are typically bypassed in favor of expression-by-expression evaluation to
# allow handling of new `include` statements.
function eval_new!(exs_sigs_new::ExprsSigs, exs_sigs_old, mod::Module; mode::Symbol=:eval)
    includes = Vector{Pair{Module,String}}()
    for rex in keys(exs_sigs_new)
        sigs, _includes = eval_rex(rex, exs_sigs_old, mod; mode=mode)
        if sigs !== nothing
            exs_sigs_new[rex] = sigs
        end
        if _includes !== nothing
            append!(includes, _includes)
        end
    end
    return exs_sigs_new, includes
end

function eval_new!(mod_exs_sigs_new::ModuleExprsSigs, mod_exs_sigs_old; mode::Symbol=:eval)
    includes = Vector{Pair{Module,String}}()
    for (mod, exs_sigs_new) in mod_exs_sigs_new
        # Allow packages to override the supplied mode
        if isdefined(mod, :__revise_mode__)
            mode = getfield(mod, :__revise_mode__)::Symbol
        end
        exs_sigs_old = get(mod_exs_sigs_old, mod, empty_exs_sigs)
        _, _includes = eval_new!(exs_sigs_new, exs_sigs_old, mod; mode=mode)
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
- `deps`: list of top-level named objects (`Symbol`s and `GlobalRef`s) that method definitions
  in this block depend on. For example, `if Sys.iswindows() f() = 1 else f() = 2 end` would
  store `Sys.iswindows` here.
- `includes`: a list of `module=>filename` for any `include` statements encountered while the
  expression was parsed.
"""
struct CodeTrackingMethodInfo
    exprstack::Vector{Expr}
    allsigs::Vector{Any}
    deps::Set{Union{GlobalRef,Symbol}}
    includes::Vector{Pair{Module,String}}
end
CodeTrackingMethodInfo(ex::Expr) = CodeTrackingMethodInfo([ex], Any[], Set{Union{GlobalRef,Symbol}}(), Pair{Module,String}[])

function add_signature!(methodinfo::CodeTrackingMethodInfo, @nospecialize(sig), ln)
    locdefs = CodeTracking.invoked_get!(Vector{Tuple{LineNumberNode,Expr}}, CodeTracking.method_info, sig)
    newdef = unwrap(methodinfo.exprstack[end])
    if newdef !== nothing
        if !any(locdef->locdef[1] == ln && isequal(RelocatableExpr(locdef[2]), RelocatableExpr(newdef)), locdefs)
            push!(locdefs, (fixpath(ln), newdef))
        end
        push!(methodinfo.allsigs, sig)
    end
    return methodinfo
end
push_expr!(methodinfo::CodeTrackingMethodInfo, mod::Module, ex::Expr) = (push!(methodinfo.exprstack, ex); methodinfo)
pop_expr!(methodinfo::CodeTrackingMethodInfo) = (pop!(methodinfo.exprstack); methodinfo)
function add_dependencies!(methodinfo::CodeTrackingMethodInfo, edges::CodeEdges, src, musteval)
    isempty(src.code) && return methodinfo
    stmt1 = first(src.code)
    if isa(stmt1, Core.GotoIfNot) && (dep = stmt1.cond; isa(dep, Union{GlobalRef,Symbol}))
        # This is basically a hack to look for symbols that control definition of methods via a conditional.
        # It is aimed at solving #249, but this will have to be generalized for anything real.
        for (stmt, me) in zip(src.code, musteval)
            me || continue
            if hastrackedexpr(stmt)[1]
                push!(methodinfo.deps, dep)
                break
            end
        end
    end
    # for (dep, lines) in be.byname
    #     for ln in lines
    #         stmt = src.code[ln]
    #         if isexpr(stmt, :(=)) && stmt.args[1] == dep
    #             continue
    #         else
    #             push!(methodinfo.deps, dep)
    #         end
    #     end
    # end
    return methodinfo
end
function add_includes!(methodinfo::CodeTrackingMethodInfo, mod::Module, filename)
    push!(methodinfo.includes, mod=>filename)
    return methodinfo
end

# Eval and insert into CodeTracking data
function eval_with_signatures(mod, ex::Expr; mode=:eval, kwargs...)
    methodinfo = CodeTrackingMethodInfo(ex)
    docexprs = DocExprs()
    frame = methods_by_execution!(finish_and_return!, methodinfo, docexprs, mod, ex; mode=mode, kwargs...)[2]
    return methodinfo.allsigs, methodinfo.deps, methodinfo.includes, frame
end

function instantiate_sigs!(modexsigs::ModuleExprsSigs; mode=:sigs, kwargs...)
    for (mod, exsigs) in modexsigs
        for rex in keys(exsigs)
            is_doc_expr(rex.ex) && continue
            sigs, deps, _ = eval_with_signatures(mod, rex.ex; mode=mode, kwargs...)
            exsigs[rex] = sigs
            storedeps(deps, rex, mod)
        end
    end
    return modexsigs
end

function storedeps(deps, rex, mod)
    for dep in deps
        if isa(dep, GlobalRef)
            haskey(moduledeps, dep.mod) || continue
            ddict, sym = get_depdict(dep.mod), dep.name
        else
            ddict, sym = get_depdict(mod), dep
        end
        if !haskey(ddict, sym)
            ddict[sym] = Set{DepDictVals}()
        end
        push!(ddict[sym], (mod, rex))
    end
    return rex
end

# This is intended for testing purposes, but not general use. The key problem is
# that it doesn't properly handle methods that move from one file to another; there is the
# risk you could end up deleting the method altogether depending on the order in which you
# process these.
# See `revise` for the proper approach.
function eval_revised(mod_exs_sigs_new, mod_exs_sigs_old)
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
        already_watching_dir || (watched_files[dirfull] = WatchList())
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
        updatetime!(watched_files[dirfull])
        if !watching_files[]
            dwatcher = TaskThunk(revise_dir_queued, (dirfull,))
            schedule(Task(dwatcher))
        end
    end
    return nothing
end
init_watching(files) = init_watching(pkgdatas[NOPACKAGE], files)

"""
    revise_dir_queued(dirname)

Wait for one or more of the files registered in `Revise.watched_files[dirname]` to be
modified, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called via a [`Revise.TaskThunk`](@ref).
"""
@noinline function revise_dir_queued(dirname)
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
                if hasfile(pkgdata, key)  # issue #228
                    push!(revision_queue, (pkgdata, relpath(key, pkgdata)))
                    notify(revision_event)
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

    dirfull, basename = splitdir(file)
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
        PkgId(pkgdata) != NOPACKAGE && push!(revision_queue, (pkgdata, relpath(file, pkgdata)))
    end
    return
end

# Because we delete first, we have to make sure we've parsed the file
function handle_deletions(pkgdata, file)
    fi = maybe_parse_from_cache!(pkgdata, file)
    maybe_extract_sigs!(fi)
    mexsold = fi.modexsigs
    idx = fileindex(pkgdata, file)
    filep = pkgdata.info.files[idx]
    if isa(filep, AbstractString)
        if file ≠ "."
            filep = normpath(basedir(pkgdata), file)
        else
            filep = normpath(basedir(pkgdata))
        end
    end
    topmod = first(keys(mexsold))
    fileok = file_exists(String(filep)::String)
    mexsnew = fileok ? parse_source(filep, topmod) : ModuleExprsSigs(topmod)
    if mexsnew !== nothing
        delete_missing!(mexsold, mexsnew)
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
    return mexsnew, mexsold
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
    for (k, v) in queue_errors
        push!(revision_queue, k)
    end
    revise()
end

"""
    revise(; throw=false)

`eval` any changes in the revision queue. See [`Revise.revision_queue`](@ref).
If `throw` is `true`, throw any errors that occur during revision or callback;
otherwise these are only logged.
"""
function revise(; throw=false)
    sleep(0.01)  # in case the file system isn't quite done writing out the new files
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
            push!(mexsnews, handle_deletions(pkgdata, file)[1])
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
                        sigs, includes = eval_rex(rex, exsold, mod; mode=mode)
                        if sigs !== nothing
                            exsnew[rex] = sigs
                        end
                        if includes !== nothing
                            maybe_add_includes_to_pkgdata!(pkgdata, file, includes; eval_now=true)
                        end
                    end
                    delete!(modsremaining, mod)
                    changed = true
                catch _err
                    err = _err
                end
            end
        end
        if isempty(modsremaining)
            pkgdata.fileinfos[i] = FileInfo(mexsnew, fi)
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

    process_user_callbacks!(throw=throw)

    nothing
end
revise(backend::REPL.REPLBackend) = revise()

"""
    revise(mod::Module)

Reevaluate every definition in `mod`, whether it was changed or not. This is useful
to propagate an updated macro definition, or to force recompiling generated functions.
"""
function revise(mod::Module)
    mod == Main && error("cannot revise(Main)")
    id = PkgId(mod)
    pkgdata = pkgdatas[id]
    for (i, file) in enumerate(srcfiles(pkgdata))
        fi = fileinfo(pkgdata, i)
        for (mod, exsigs) in fi.modexsigs
            for def in keys(exsigs)
                ex = def.ex
                exuw = unwrap(ex)
                isexpr(exuw, :call) && exuw.args[1] === :include && continue
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
function track(mod::Module, file; mode=:sigs, kwargs...)
    isfile(file) || error(file, " is not a file")
    # Determine whether we're already tracking this file
    id = Base.moduleroot(mod) == Main ? PkgId(mod, string(mod)) : PkgId(mod)  # see #689 for `Main`
    if haskey(pkgdatas, id)
        pkgdata = pkgdatas[id]
        relfile = relpath(abspath(file), pkgdata)
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
        file = abspath(file)
    end
    # Set up tracking
    fm = parse_source(file, mod; mode=mode)
    if fm !== nothing
        if mode === :includet
            mode = :sigs   # we already handled evaluation in `parse_source`
        end
        instantiate_sigs!(fm; mode=mode, kwargs...)
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
        push!(pkgdata, relpath(file, pkgdata)=>FileInfo(fm))
        init_watching(pkgdata, (String(file)::String,))
        pkgdatas[id] = pkgdata
    end
    return nothing
end

function track(file; kwargs...)
    startswith(file, juliadir) && error("use Revise.track(Base) or Revise.track(<stdlib module>)")
    track(Main, file; kwargs...)
end

"""
    includet(filename)

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
(See [`Revise.track`](@ref) to set it up manually.)
"""
function includet(mod::Module, file)
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
            showerror(stderr, err; blame_revise=false)
            println(stderr, "\nin expression starting at ", err.loc)
        else
            throw(err)
        end
    end
    return nothing
end
includet(file) = includet(Main, file)

"""
    Revise.silence(pkg)

Silence warnings about not tracking changes to package `pkg`.
"""
function silence(pkg::Symbol)
    push!(silence_pkgs, pkg)
    if !isdir(depsdir)
        mkpath(depsdir)
    end
    open(silencefile[], "w") do io
        for p in silence_pkgs
            println(io, p)
        end
    end
    nothing
end
silence(pkg::AbstractString) = silence(Symbol(pkg))

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
        for (mod, exs) in fi.modexsigs
            for sigs in values(exs)
                hassig |= !isempty(sigs)
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
        @warn "skipping $method to avoid parsing too much code"
        CodeTracking.invoked_setindex!(CodeTracking.method_info, method.sig, missing)
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
    @warn "$(method.sig) was not found"
    # So that we don't call it again, store missingness info in CodeTracking
    CodeTracking.invoked_setindex!(CodeTracking.method_info, method.sig, missing)
    return false
end

function get_def(method, pkgdata, filename)
    maybe_extract_sigs!(maybe_parse_from_cache!(pkgdata, filename))
    return get(CodeTracking.method_info, method.sig, nothing)
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
    mexs = ModuleExprsSigs(Main::Module)
    parse_source!(mexs, src, filename, Main::Module)
    instantiate_sigs!(mexs)
    fi = FileInfo(mexs)
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
        if t.linfo isa Core.MethodInstance
            m = t.linfo.def
            sigt = m.sig
            # Why not just call `whereis`? Because that forces tracking. This is being
            # clever by recognizing that these entries exist only if there have been updates.
            updated = get(CodeTracking.method_info, sigt, nothing)
            if updated !== nothing
                lnn = updated[1][1]     # choose the first entry by default
                lineoffset = lnn.line - m.line
                t = StackTraces.StackFrame(t.func, lnn.file, t.line+lineoffset, t.linfo, t.from_c, t.inlined, t.pointer)
                trace[i] = has_nrep ? (t, nrep) : t
            end
        end
    end
    return trace
end

function method_location(method::Method)
    # Why not just call `whereis`? Because that forces tracking. This is being
    # clever by recognizing that these entries exist only if there have been updates.
    updated = get(CodeTracking.method_info, method.sig, nothing)
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
        isa(exu, Expr) && exu.head === :call && length(exu.args) == 1 && exu.args[1] === :exit && return ex
    end
    # Check for queued revisions, and if so call `revise` first before executing the expression
    return Expr(:toplevel, :($isempty($revision_queue) || $(Base.invokelatest)($revise)), ex)
end

steal_repl_backend(args...) = @warn "`steal_repl_backend` has been removed from Revise, please update your `~/.julia/config/startup.jl`.\nSee https://timholy.github.io/Revise.jl/stable/config/"
wait_steal_repl_backend() = steal_repl_backend()
async_steal_repl_backend() = steal_repl_backend()

"""
    Revise.init_worker(p)

Define methods on worker `p` that Revise needs in order to perform revisions on `p`.
Revise itself does not need to be running on `p`.
"""
function init_worker(p)
    remotecall(Core.eval, p, Main, quote
        function whichtt(@nospecialize sig)
            @static if VERSION ≥ v"1.10.0-DEV.873"
                ret = Base._methods_by_ftype(sig, -1, Base.get_world_counter())
            else
                ret = Base._methods_by_ftype(sig, -1, typemax(UInt))
            end
            isempty(ret) && return nothing
            m = ret[end][3]::Method   # the last method returned is the least-specific that matches, and thus most likely to be type-equal
            methsig = m.sig
            (sig <: methsig && methsig <: sig) || return nothing
            return m
        end
        function delete_method_by_sig(@nospecialize sig)
            m = whichtt(sig)
            isa(m, Method) && Base.delete_method(m)
        end
    end)
end

function __init__()
    ccall(:jl_generating_output, Cint, ()) == 1 && return nothing
    run_on_worker = get(ENV, "JULIA_REVISE_WORKER_ONLY", "0")
    if !(myid() == 1 || run_on_worker == "1")
        return nothing
    end
    # Check Julia paths (issue #601)
    if !isdir(juliadir)
        major, minor = Base.VERSION.major, Base.VERSION.minor
        @warn """Expected non-existent $juliadir to be your Julia directory.
                 Certain functionality will be disabled.
                 To fix this, try deleting Revise's cache files in ~/.julia/compiled/v$major.$minor/Revise, then restart Julia and load Revise.
                 If this doesn't fix the problem, please report an issue at https://github.com/timholy/Revise.jl/issues."""
    end
    if isfile(silencefile[])
        pkgs = readlines(silencefile[])
        for pkg in pkgs
            push!(silence_pkgs, Symbol(pkg))
        end
    end
    polling = get(ENV, "JULIA_REVISE_POLL", "0")
    if polling == "1"
        polling_files[] = watching_files[] = true
    end
    rev_include = get(ENV, "JULIA_REVISE_INCLUDE", "0")
    if rev_include == "1"
        tracking_Main_includes[] = true
    end
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
    pkgdatas[id] = pkgdata = PkgData(id, nothing)
    # Set the lookup callbacks
    CodeTracking.method_lookup_callback[] = get_def
    CodeTracking.expressions_callback[] = get_expressions

    # Register the active-project watcher
    if isdefined(Pkg.Types, :active_project_watcher_thunks)
        push!(Pkg.Types.active_project_watcher_thunks, active_project_watcher)
    end

    # Watch the manifest file for changes
    mfile = manifest_file()
    if mfile !== nothing
        push!(watched_manifests, mfile)
        wmthunk = TaskThunk(watch_manifest, (mfile,))
        schedule(Task(wmthunk))
    end
    push!(Base.include_callbacks, watch_includes)
    push!(Base.package_callbacks, watch_package_callback)

    mode = get(ENV, "JULIA_REVISE", "auto")
    if mode == "auto"
        if isdefined(Main, :IJulia)
            Main.IJulia.push_preexecute_hook(revise)
        else
            pushfirst!(REPL.repl_ast_transforms, revise_first)
            # #664: once a REPL is started, it no longer interacts with REPL.repl_ast_transforms
            if isdefined(Base, :active_repl_backend)
                push!(Base.active_repl_backend.ast_transforms, revise_first)
            else
                # wait for active_repl_backend to exist
                # #719: do this async in case Revise is being loaded from startup.jl
                t = @async begin
                    iter = 0
                    while !isdefined(Base, :active_repl_backend) && iter < 20
                        sleep(0.05)
                        iter += 1
                    end
                    if isdefined(Base, :active_repl_backend)
                        push!(Base.active_repl_backend.ast_transforms, revise_first)
                    end
                end
                isdefined(Base, :errormonitor) && Base.errormonitor(t)
            end
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
    for mod in (CodeTracking, OrderedCollections, JuliaInterpreter, LoweredCodeUtils, Revise)
        id = PkgId(mod)
        pkgdata = parse_pkg_files(id)
        init_watching(pkgdata, srcfiles(pkgdata))
        pkgdatas[id] = pkgdata
    end
    return nothing
end

include("precompile.jl")
_precompile_()
