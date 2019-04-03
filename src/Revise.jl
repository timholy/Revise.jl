module Revise

using FileWatching, REPL, Distributed, UUIDs
import LibGit2
using Base: PkgId
using Base.Meta: isexpr
using Core: CodeInfo

using OrderedCollections, CodeTracking, JuliaInterpreter, LoweredCodeUtils
using CodeTracking: PkgFiles, basedir, srcfiles
using JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return
using JuliaInterpreter: @lookup, moduleof, scopeof, pc_expr, prepare_thunk, split_expressions
using LoweredCodeUtils: next_or_nothing!, isanonymous_typedef, define_anonymous

export revise, includet, entr, MethodSummary

"""
    Revise.watching_files[]

Returns `true` if we watch files rather than their containing directory.
FreeBSD and NFS-mounted systems should watch files, otherwise we prefer to watch
directories.
"""
const watching_files = Ref(Sys.KERNEL == :FreeBSD)

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
        if Sys.islinux() && err isa SystemError && err.errnum == 28  # ENOSPC
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
# include("backedges.jl")
include("pkgs.jl")
include("git.jl")
include("recipes.jl")
include("logging.jl")
include("deprecations.jl")

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
    Revise.revision_queue

Global variable, `revision_queue` holds `(pkgdata,filename)` pairs that we need to revise, meaning
that these files have changed since we last processed a revision.
This list gets populated by callbacks that watch directories for updates.
"""
const revision_queue = Set{Tuple{PkgData,String}}()

"""
    Revise.pkgdatas

`pkgdatas` is the core information that tracks the relationship between source code
and julia objects, and allows re-evaluation of code in the proper module scope.
It is a dictionary indexed by PkgId:
`pkgdatas[id]` returns a value of type [`Revise.PkgData`](@ref).
"""
const pkgdatas = Dict{PkgId,PkgData}()

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

"""
    Revise.juliadir

Constant specifying full path to julia top-level source directory.
This should be reliable even for local builds, cross-builds, and binary installs.
"""
const juliadir = begin
    local jldir = basebuilddir
    if !isdir(joinpath(jldir, "base"))
        # Binaries probably end up here. We fall back on Sys.BINDIR
        jldir = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
        if !isdir(joinpath(jldir, "base"))
            while true
                trydir = joinpath(jldir, "base")
                isdir(trydir) && break
                trydir = joinpath(jldir, "share", "julia", "base")
                if isdir(trydir)
                    jldir = joinpath(jldir, "share", "julia")
                    break
                end
                jldirnext = dirname(jldir)
                jldirnext == jldir && break
                jldir = jldirnext
            end
        end
    end
    normpath(jldir)
end
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

function delete_missing!(exs_sigs_old::ExprsSigs, exs_sigs_new)
    with_logger(_debug_logger) do
        for (ex, sigs) in exs_sigs_old
            haskey(exs_sigs_new, ex) && continue
            # ex was deleted
            sigs === nothing && continue
            for sig in sigs
                ret = Base._methods_by_ftype(sig, -1, typemax(UInt))
                success = false
                if !isempty(ret)
                    m = ret[end][3]::Method   # the last method returned is the least-specific that matches, and thus most likely to be type-equal
                    methsig = m.sig
                    if sig <: methsig && methsig <: sig
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

function eval_new!(exs_sigs_new::ExprsSigs, exs_sigs_old, mod::Module)
    with_logger(_debug_logger) do
        for rex in keys(exs_sigs_new)
            rexo = getkey(exs_sigs_old, rex, nothing)
            # extract the signatures and update the line info
            local sigs
            if rexo === nothing
                ex = rex.ex
                # ex is not present in old
                @debug "Eval" _group="Action" time=time() deltainfo=(mod, ex)
                # try
                    sigs = eval_with_signatures(mod, ex)  # All signatures defined by `ex`
                    for p in workers()
                        p == myid() && continue
                        try   # don't error if `mod` isn't defined on the worker
                            remotecall(Core.eval, p, mod, ex)
                        catch
                        end
                    end
                # catch err
                #     @error "failure to evaluate changes in $mod"
                #     showerror(stderr, err)
                #     println_maxsize(stderr, "\n", ex; maxlines=20)
                # end
            else
                sigs = exs_sigs_old[rexo]
                # Update location info
                ln, lno = firstline(rex), firstline(rexo)
                if sigs !== nothing && !isempty(sigs) && ln != lno
                    @debug "LineOffset" _group="Action" time=time() deltainfo=(sigs, lno=>ln)
                    for sig in sigs
                        local methloc, methdef
                        # try
                            methloc, methdef = CodeTracking.method_info[sig]
                        # catch err
                        #     @show sig sigs
                        #     @show CodeTracking.method_info
                        #     rethrow(err)
                        # end
                        CodeTracking.method_info[sig] = (newloc(methloc, ln, lno), methdef)
                    end
                end
            end
            # @show rex rexo sigs
            exs_sigs_new[rex] = sigs
        end
    end
    return exs_sigs_new
end

function eval_new!(mod_exs_sigs_new::ModuleExprsSigs, mod_exs_sigs_old)
    for (mod, exs_sigs_new) in mod_exs_sigs_new
        exs_sigs_old = get(mod_exs_sigs_old, mod, empty_exs_sigs)
        eval_new!(exs_sigs_new, exs_sigs_old, mod)
    end
    return mod_exs_sigs_new
end

struct CodeTrackingMethodInfo
    exprstack::Vector{Expr}
    allsigs::Vector{Any}
end
CodeTrackingMethodInfo(ex::Expr) = CodeTrackingMethodInfo([ex], Any[])
CodeTrackingMethodInfo(rex::RelocatableExpr) = CodeTrackingMethodInfo(rex.ex)

function add_signature!(methodinfo::CodeTrackingMethodInfo, @nospecialize(sig), ln)
    CodeTracking.method_info[sig] = (fixpath(ln), methodinfo.exprstack[end])
    push!(methodinfo.allsigs, sig)
    return methodinfo
end
push_expr!(methodinfo::CodeTrackingMethodInfo, mod::Module, ex::Expr) = (push!(methodinfo.exprstack, ex); methodinfo)
pop_expr!(methodinfo::CodeTrackingMethodInfo) = (pop!(methodinfo.exprstack); methodinfo)

# Eval and insert into CodeTracking data
function eval_with_signatures(mod, ex::Expr; define=true, kwargs...)
    methodinfo = CodeTrackingMethodInfo(ex)
    docexprs = Dict{Module,Vector{Expr}}()
    methods_by_execution!(finish_and_return!, methodinfo, docexprs, mod, ex; define=define, kwargs...)
    return methodinfo.allsigs
end

function instantiate_sigs!(modexsigs::ModuleExprsSigs; define=false, kwargs...)
    for (mod, exsigs) in modexsigs
        for rex in keys(exsigs)
            is_doc_expr(rex.ex) && continue
            sigs = eval_with_signatures(mod, rex.ex; define=define, kwargs...)
            exsigs[rex.ex] = sigs
        end
    end
    return modexsigs
end

# This is intended for testing purposes, but not general use. The key problem is
# that it doesn't properly handle methods that move from one file to another; there is the
# risk you could end up deleting the method altogether depending on the order in which you
# process these.
# See `revise` for the proper approach.
function eval_revised(mod_exs_sigs_new, mod_exs_sigs_old)
    delete_missing!(mod_exs_sigs_old, mod_exs_sigs_new)
    eval_new!(mod_exs_sigs_new, mod_exs_sigs_old)
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
function init_watching(pkgdata::PkgData, files)
    udirs = Set{String}()
    for file in files
        dir, basename = splitdir(file)
        dirfull = joinpath(basedir(pkgdata), dir)
        haskey(watched_files, dirfull) || (watched_files[dirfull] = WatchList())
        push!(watched_files[dirfull], basename)
        if watching_files[]
            fwatcher = Rescheduler(revise_file_queued, (pkgdata, file))
            schedule(Task(fwatcher))
        else
            push!(udirs, dir)
        end
    end
    for dir in udirs
        dirfull = joinpath(basedir(pkgdata), dir)
        updatetime!(watched_files[dirfull])
        if !watching_files[]
            dwatcher = Rescheduler(revise_dir_queued, (pkgdata, dir))
            schedule(Task(dwatcher))
        end
    end
    return nothing
end
init_watching(files) = init_watching(PkgId(Main), files)

"""
    revise_dir_queued(pkgdata::PkgData, dirname)

Wait for one or more of the files registered in `Revise.watched_files[dirname]` to be
modified, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called via a [`Revise.Rescheduler`](@ref).
"""
@noinline function revise_dir_queued(pkgdata::PkgData, dirname)
    dirname0 = dirname
    if !isabspath(dirname)
        dirname = joinpath(basedir(pkgdata), dirname)
    end
    if !isdir(dirname)
        sleep(0.1)   # in case git has done a delete/replace cycle
        if !isfile(dirname)
            with_logger(SimpleLogger(stderr)) do
                @warn "$dirname is not an existing directory, Revise is not watching"
            end
            return false
        end
    end
    latestfiles, stillwatching = watch_files_via_dir(dirname)  # will block here until file(s) change
    for file in latestfiles
        key = joinpath(dirname0, file)
        if hasfile(pkgdata, key)  # issue #228
            push!(revision_queue, (pkgdata, key))
        end
    end
    return stillwatching
end

# See #66.
"""
    revise_file_queued(pkgdata::PkgData, filename)

Wait for modifications to `filename`, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called via a [`Revise.Rescheduler`](@ref).

This is used only on platforms (like BSD) which cannot use [`Revise.revise_dir_queued`](@ref).
"""
function revise_file_queued(pkgdata::PkgData, file)
    file0 = file
    if !isabspath(file)
        file = joinpath(basedir(pkgdata), file)
    end
    if !isfile(file)
        sleep(0.1)  # in case git has done a delete/replace cycle
        if !isfile(file)
            with_logger(SimpleLogger(stderr)) do
                @error "$file is not an existing file, Revise is not watching"
            end
            return false
        end
    end

    wait_changed(file)  # will block here until the file changes
    # Check to see if we're still watching this file
    dirfull, basename = splitdir(file)
    if haskey(watched_files, dirfull)
        push!(revision_queue, (pkgdata, file0))
        return true
    end
    return false
end

# Because we delete first, we have to make sure we've parsed the file
function handle_deletions(pkgdata, file)
    fi = maybe_parse_from_cache!(pkgdata, file)
    mexsold = fi.modexsigs
    filep = normpath(joinpath(basedir(pkgdata), file))
    topmod = first(keys(mexsold))
    mexsnew = parse_source(filep, topmod)
    if mexsnew !== nothing
        delete_missing!(mexsold, mexsnew)
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
    i = fileindex(pkgdata, file)
    if i === nothing
        println("Revise is currently tracking the following files in $(pkgdata.id): ", keys(pkgdict))
        error(file, " is not currently being tracked.")
    end
    mexsnew, mexsold = handle_deletions(pkgdata, file)
    if mexsnew != nothing
        eval_new!(mexsnew, mexsold)
        fi = fileinfo(pkgdata, i)
        pkgdata.fileinfos[i] = FileInfo(mexsnew, fi)
    end
    nothing
end

"""
    revise()

`eval` any changes in the revision queue. See [`Revise.revision_queue`](@ref).
"""
function revise()
    sleep(0.01)  # in case the file system isn't quite done writing out the new files

    # Do all the deletion first. This ensures that a method that moved from one file to another
    # won't get redefined first and deleted second.
    revision_errors = []
    finished = eltype(revision_queue)[]
    mexsnews = ModuleExprsSigs[]
    for (pkgdata, file) in revision_queue
        try
            push!(mexsnews, handle_deletions(pkgdata, file)[1])
            push!(finished, (pkgdata, file))
        catch err
            push!(revision_errors, (basedir(pkgdata), file, err))
        end
    end
    # Do the evaluation
    for ((pkgdata, file), mexsnew) in zip(finished, mexsnews)
        i = fileindex(pkgdata, file)
        fi = fileinfo(pkgdata, i)
        try
            eval_new!(mexsnew, fi.modexsigs)
            pkgdata.fileinfos[i] = FileInfo(mexsnew, fi)
        catch err
            push!(revision_errors, (basedir(pkgdata), file, err))
        end
    end
    empty!(revision_queue)
    for (basedir, file, err) in revision_errors
        fullpath = joinpath(basedir, file)
        @warn "Failed to revise $fullpath: $err"
    end
    tracking_Main_includes[] && queue_includes(Main)
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
                isexpr(ex, :call) && ex.args[1] == :include && continue
                try
                    Core.eval(mod, ex)
                catch err
                    @show mod
                    display(def)
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
"""
function track(mod::Module, file::AbstractString; define=false, skip_include=true)
    isfile(file) || error(file, " is not a file")
    file = normpath(abspath(file))
    fm = parse_source(file, mod)
    if fm !== nothing
        instantiate_sigs!(fm; define=define, skip_include=skip_include)
        id = PkgId(mod)
        if !haskey(pkgdatas, id)
            pkgdatas[id] = PkgData(id, pathof(mod))
        end
        pkgdata = pkgdatas[id]
        if !haskey(CodeTracking._pkgfiles, id)
            CodeTracking._pkgfiles[id] = pkgdata.info
        end
        push!(pkgdata, file=>FileInfo(fm))
        init_watching(pkgdata, (file,))
    end
end

track(file::AbstractString) = track(Main, file)

"""
    includet(filename)

Load `filename` and track any future changes to it. `includet` is simply shorthand for

    Revise.track(Main, filename; skip_include=false)

`includet` is intended for "user scripts," e.g., a file you use locally for a specific
purpose such as loading a specific data set or performing a particular analysis.
Do *not* use `includet` for packages, as those should be handled by `using` or `import`.
(If you're working with code in Base or one of Julia's standard libraries, use
`Revise.track(mod)` instead, where `mod` is the module.)
If `using` and `import` aren't working, you may have packages in a non-standard location;
try fixing it with something like `push!(LOAD_PATH, "/path/to/my/private/repos")`.

`includet` is deliberately non-recursive, so if `filename` loads any other files,
they will not be automatically tracked.
(See [`Revise.track`](@ref) to set it up manually.)
"""
includet(file::AbstractString) = track(Main, file; define=true, skip_include=false)

"""
    entr(f, files)
    entr(f, files, modules)

Execute `f()` whenever files listed in `files`, or code in `modules`, updates.
`entr` will process updates (and block your command line) until you press Ctrl-C.

# Example

```julia
entr(["/tmp/watched.txt"], [Pkg1, Pkg2]) do
    println("update")
end
```
This will print "update" every time `"/tmp/watched.txt"` or any of the code defining
`Pkg1` or `Pkg2` gets updated.
"""
function entr(f::Function, files, modules=nothing)
    files = collect(files)  # because we may add to this list
    if modules !== nothing
        for mod in modules
            id = PkgId(mod)
            pkgdata = pkgdatas[id]
            for file in srcfiles(pkgdata)
                push!(files, joinpath(basedir(pkgdata), file))
            end
        end
    end
    active = true
    try
        @sync begin
            for file in files
                waitfor = isdir(file) ? watch_folder : watch_file
                @async while active
                    ret = waitfor(file, 1)
                    ret.renamed && break
                    if active && ret.changed
                        revise()
                        f()
                    end
                end
            end
        end
    catch err
        if isa(err, InterruptException)
            active = false
        else
            rethrow(err)
        end
    end
end

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
    method = get_method(sigt)

Get the method `method` with signature-type `sigt`. This is used to provide
the method to `Base.delete_method`.

If `sigt` does not correspond to a method, returns `nothing`.

# Examples

```jldoctest; setup = :(using Revise), filter = r"in Main at.*"
julia> mymethod(::Int) = 1
mymethod (generic function with 1 method)

julia> mymethod(::AbstractFloat) = 2
mymethod (generic function with 2 methods)

julia> Revise.get_method(Tuple{typeof(mymethod), Int})
mymethod(::Int64) in Main at REPL[0]:1

julia> Revise.get_method(Tuple{typeof(mymethod), Float64})
mymethod(::AbstractFloat) in Main at REPL[1]:1

julia> Revise.get_method(Tuple{typeof(mymethod), Number})

```
"""
function get_method(@nospecialize(sigt))
    mths = Base._methods_by_ftype(sigt, -1, typemax(UInt))
    length(mths) == 1 && return mths[1][3]
    if !isempty(mths)
        # There might be many methods, but the one that should match should be the
        # last one, since methods are ordered by specificity
        i = lastindex(mths)
        while i > 0
            m = mths[i][3]
            m.sig == sigt && return m
            i -= 1
        end
    end
    return nothing
end

"""
    success = get_def(method::Method)

As needed, load the source file necessary for extracting the code defining `method`.
The source-file defining `method` must be tracked.
If it is in Base, this will execute `track(Base)` if necessary.

This is a callback function used by `CodeTracking.jl`'s `definition`.
"""
function get_def(method::Method; modified_files=revision_queue)
    yield()   # magic bug fix for the OSX test failures. TODO: figure out why this works (prob. Julia bug)
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
        CodeTracking.method_info[method.sig] = missing
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
    CodeTracking.method_info[method.sig] = missing
    return false
end

function get_def(method, pkgdata, filename)
    maybe_parse_from_cache!(pkgdata, filename)
    return get(CodeTracking.method_info, method.sig, nothing)
end

function get_tracked_id(id::PkgId; modified_files=revision_queue)
    # Methods from Base or the stdlibs may require that we start tracking
    if !haskey(pkgdatas, id)
        recipe = id.name === "Compiler" ? :Compiler : Symbol(id.name)
        recipe == :Core && return nothing
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
    maybe_parse_from_cache!(pkgdata, filename)
    fi = fileinfo(pkgdata, filename)
    return fi.modexsigs
end

function add_definitions_from_repl(filename)
    hist_idx = parse(Int, filename[6:end-1])
    hp = Base.active_repl.interface.modes[1].hist
    src = hp.history[hp.start_idx+hist_idx]
    id = PkgId(nothing, "@REPL")
    pkgdata = pkgdatas[id]
    mexs = ModuleExprsSigs(Main)
    parse_source!(mexs, src, filename, Main)
    instantiate_sigs!(mexs)
    fi = FileInfo(mexs)
    push!(pkgdata, filename=>fi)
    return fi
end

function fix_line_statements!(ex::Expr, file::Symbol, line_offset::Int=0)
    if ex.head == :line
        ex.args[1] += line_offset
        ex.args[2] = file
    else
        for (i, a) in enumerate(ex.args)
            if isa(a, Expr)
                fix_line_statements!(a::Expr, file, line_offset)
            elseif isa(a, LineNumberNode)
                ex.args[i] = file_line_statement(a::LineNumberNode, file, line_offset)
            end
        end
    end
    ex
end

file_line_statement(lnn::LineNumberNode, file::Symbol, line_offset) =
    LineNumberNode(lnn.line + line_offset, file)

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
                lnn = updated[1]
                lineoffset = lnn.line - m.line
                t = StackTraces.StackFrame(t.func, lnn.file, t.line+lineoffset, t.linfo, t.from_c, t.inlined, t.pointer)
                trace[i] = has_nrep ? (t, nrep) : t
            end
        end
    end
    return trace
end

@noinline function run_backend(backend)
    while true
        tls = task_local_storage()
        tls[:SOURCE_PATH] = nothing
        ast, show_value = take!(backend.repl_channel)
        if show_value == -1
            # exit flag
            break
        end
        # Process revisions
        revise(backend)
        # Now eval the input
        REPL.eval_user_input(ast, backend)
    end
    nothing
end

"""
    steal_repl_backend(backend = Base.active_repl_backend)

Replace the REPL's normal backend with one that calls [`revise`](@ref) before executing
any REPL input.
"""
function steal_repl_backend(backend = Base.active_repl_backend)
    @async begin
        # terminate the current backend
        put!(backend.repl_channel, (nothing, -1))
        fetch(backend.backend_task)
        # restart a new backend that differs only by processing the
        # revision queue before evaluating each user input
        backend.backend_task = @async run_backend(backend)
    end
    nothing
end

function wait_steal_repl_backend()
    iter = 0
    # wait for active_repl_backend to exist
    while !isdefined(Base, :active_repl_backend) && iter < 20
        sleep(0.05)
        iter += 1
    end
    if isdefined(Base, :active_repl_backend)
        steal_repl_backend(Base.active_repl_backend)
    else
        @warn "REPL initialization failed, Revise is not in automatic mode. Call `revise()` manually."
    end
end

"""
    Revise.async_steal_repl_backend()

Wait for the REPL to complete its initialization, and then call [`Revise.steal_repl_backend`](@ref).
This is necessary because code registered with `atreplinit` runs before the REPL is
initialized, and there is no corresponding way to register code to run after it is complete.
"""
function async_steal_repl_backend()
    mode = get(ENV, "JULIA_REVISE", "auto")
    if mode == "auto"
        atreplinit() do repl
            @async wait_steal_repl_backend()
        end
    end
    return nothing
end

"""
    Revise.init_worker(p)

Define methods on worker `p` that Revise needs in order to perform revisions on `p`.
Revise itself does not need to be running on `p`.
"""
function init_worker(p)
    remotecall(Core.eval, p, Main, quote
        function whichtt(sig)
            ret = Base._methods_by_ftype(sig, -1, typemax(UInt))
            isempty(ret) && return nothing
            m = ret[end][3]::Method   # the last method returned is the least-specific that matches, and thus most likely to be type-equal
            methsig = m.sig
            (sig <: methsig && methsig <: sig) || return nothing
            return m
        end
        function delete_method_by_sig(sig)
            m = whichtt(sig)
            isa(m, Method) && Base.delete_method(m)
        end
    end)
end

function __init__()
    myid() == 1 || return nothing
    if isfile(silencefile[])
        pkgs = readlines(silencefile[])
        for pkg in pkgs
            push!(silence_pkgs, Symbol(pkg))
        end
    end
    push!(Base.package_callbacks, watch_package)
    push!(Base.include_callbacks,
        (mod::Module, fn::AbstractString) -> push!(included_files, (mod, normpath(abspath(fn)))))
    mode = get(ENV, "JULIA_REVISE", "auto")
    if mode == "auto"
        if isdefined(Base, :active_repl_backend)
            steal_repl_backend(Base.active_repl_backend::REPL.REPLBackend)
        elseif isdefined(Main, :IJulia)
            Main.IJulia.push_preexecute_hook(revise)
        end
        if isdefined(Main, :Atom)
            setup_atom(getfield(Main, :Atom)::Module)
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
    # Populate CodeTracking data for dependencies and initialize watching
    for mod in (CodeTracking, OrderedCollections, JuliaInterpreter, LoweredCodeUtils)
        id = PkgId(mod)
        parse_pkg_files(id)
        pkgdata = pkgdatas[id]
        init_watching(pkgdata, srcfiles(pkgdata))
    end
    # Set up a repository for methods defined at the REPL
    id = PkgId(nothing, "@REPL")
    pkgdatas[id] = pkgdata = PkgData(id, nothing)
    # Set the lookup callbacks
    CodeTracking.method_lookup_callback[] = get_def
    CodeTracking.expressions_callback[] = get_expressions

    # Watch the manifest file for changes
    mfile = manifest_file()
    if mfile === nothing
        @warn "no Manifest.toml file found, static paths used"
    else
        wmthunk = Rescheduler(watch_manifest, (mfile,))
        schedule(Task(wmthunk))
    end
    return nothing
end

function setup_atom(atommod::Module)::Nothing
    handlers = getfield(atommod, :handlers)
    for x in ["eval", "evalall", "evalrepl"]
        old = handlers[x]
        Main.Atom.handle(x) do data
            revise()
            old(data)
        end
    end
    return nothing
end

include("precompile.jl")
_precompile_()

end # module
