__precompile__(true)

module Revise

using FileWatching, REPL, Base.CoreLogging, Distributed
import LibGit2

using OrderedCollections: OrderedSet

export revise

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
    polling_files[] ? poll_file(file) : watch_file(file)
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
include("parsing.jl")
include("delete_method.jl")
include("pkgs.jl")
include("git.jl")
include("recipes.jl")

### Globals to keep track of state

"""
    Revise.watched_files

Global variable, `watched_files[dirname]` returns the collection of files in `dirname`
that we're monitoring for changes. The returned value has type [`WatchList`](@ref).

This variable allows us to watch directories rather than files, reducing the burden on
the OS.
"""
const watched_files = Dict{String,WatchList}()

"""
    Revise.revision_queue

Global variable, `revision_queue` holds the names of files that we need to revise, meaning
that these files have changed since we last processed a revision.
This list gets populated by callbacks that watch directories for updates.
"""
const revision_queue = Set{String}()

"""
    Revise.file2modules

Global variable, `file2modules` is the core information that allows re-evaluation of code in
the proper module scope.
It is a dictionary indexed by absolute paths of files;
`file2modules[filename]` returns a value of type [`Revise.FileModules`](@ref).
"""
const file2modules = Dict{String,FileModules}()

"""
    Revise.module2files

Global variable, `module2files` holds the list of filenames used to define a particular
module. This is only used by `revise(MyModule)` to "refresh" all the definitions in a module.
"""
const module2files = Dict{Symbol,Vector{String}}()

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
const basesrccache = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base.cache")

"""
    Revise.juliadir

Constant specifying full path to julia top-level directory from which julia was built.
This is reliable even for cross-builds.
"""
const juliadir = begin
    basefiles = map(x->x[2], Base._included_files)
    sysimg = filter(x->endswith(x, "sysimg.jl"), basefiles)[1]
    dirname(dirname(sysimg))
end

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

"""
    revmod = revised_statements(new_defs, old_defs)

Return a `Dict(Module=>changeset)`, `revmod`, listing the changes that
should be [`eval_revised`](@ref) for each module to update definitions from `old_defs` to
`new_defs`.  See [`parse_source`](@ref) to obtain the `defs` structures.
"""
function revised_statements(newfm::FileModules, oldfm::FileModules)
    @assert newfm.topmod == oldfm.topmod
    revised_statements(newfm.md, oldfm.md)
end

function revised_statements(newmd::ModDict, oldmd::ModDict)
    revmd = ModDict()
    for (mod, newdefs) in newmd
        if haskey(oldmd, mod) # in case of new submodules, see #43
            revised_statements!(revmd, mod, newdefs, oldmd[mod])
        end
    end
    revmd
end

revised_statements(mod::Module, newdefs::ExprsSigs, olddefs::ExprsSigs) =
    revised_statements!(ModDict(), mod, newdefs, olddefs)

function revised_statements!(revmd::ModDict, mod::Module,
                             newdefs::ExprsSigs, olddefs::ExprsSigs)
    # Detect new or revised expressions
    for stmt in newdefs.exprs
        if isa(stmt, RelocatableExpr)
            stmt = stmt::RelocatableExpr
            @assert stmt.head != :module
            if stmt ∉ olddefs.exprs
                if !haskey(revmd, mod)
                    revmd[mod] = ExprsSigs()
                end
                push!(revmd[mod].exprs, stmt)
            end
        end
    end
    # Detect method deletions
    for sig in olddefs.sigs
        if sig ∉ newdefs.sigs
            if !haskey(revmd, mod)
                revmd[mod] = ExprsSigs()
            end
            push!(revmd[mod].sigs, sig)
        end
    end
    revmd
end

"""
    succeeded = eval_revised(revmd::ModDict, delete_methods=true)

Evaluate the changes listed in `revmd`, which consists of deleting all
the listed signatures in each `.sigs` field(s) (unless `delete_methods=false`)
and evaluating expressions in the `.exprs` field(s).

Returns `true` if all revisions in `revmd` were successfully implemented.
"""
function eval_revised(revmd::ModDict, delete_methods::Bool=true)
    succeeded = true
    for (mod, exprssigs) in revmd
        # mod = mod == Base.__toplevel__ ? Main : mod
        if delete_methods
            for sig in exprssigs.sigs
                try
                    sigexs = sig_type_exprs(sig)
                    for sig1 in sigexs  # default-arg functions generate multiple methods
                        m = get_method(mod, sig1)
                        isa(m, Method) && Base.delete_method(m)
                    end
                catch err
                    succeeded = false
                    @error "failure to delete signature $sig in module $mod"
                    showerror(stderr, err)
                end
            end
        end
        for rex in exprssigs.exprs
            ex = convert(Expr, rex)
            try
                if isdocexpr(ex) && mod == Base.__toplevel__
                    Core.eval(Main, ex)
                else
                    Core.eval(mod, ex)
                end
            catch err
                succeeded = false
                @error "failure to evaluate changes in $mod"
                showerror(stderr, err)
                println(stderr, "\n", ex)
            end
        end
    end
    succeeded
end

function use_compiled_modules()
    return Base.JLOptions().use_compiled_modules != 0
end

"""
    Revise.init_watching(files)

For every filename in `files`, monitor the filesystem for updates. When the file is
updated, either [`revise_dir_queued`](@ref) or [`revise_file_queued`](@ref) will
be called.
"""
function init_watching(files)
    udirs = Set{String}()
    for file in files
        dir, basename = splitdir(file)
        haskey(watched_files, dir) || (watched_files[dir] = WatchList())
        push!(watched_files[dir], basename)
        if watching_files[]
            @async revise_file_queued(file)
        else
            push!(udirs, dir)
        end
    end
    for dir in udirs
        updatetime!(watched_files[dir])
        @async revise_dir_queued(dir)
    end
    return nothing
end

"""
    revise_dir_queued(dirname)

Wait for one or more of the files registered in `Revise.watched_files[dirname]` to be
modified, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called within an `@async`.
"""
function revise_dir_queued(dirname)
    if !isdir(dirname)
        sleep(0.1)   # in case git has done a delete/replace cycle
        if !isfile(dirname)
            with_logger(SimpleLogger(stderr)) do
                @warn "$dirname is not an existing directory, Revise is not watching"
            end
            return nothing
        end
    end
    latestfiles = watch_files_via_dir(dirname)  # will block here until file(s) change
    for file in latestfiles
        push!(revision_queue, file)
    end
    @async revise_dir_queued(dirname)
end

# See #66.
"""
    revise_file_queued(filename)

Wait for modifications to `filename`, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called within an `@async`.

This is used only on platforms (like BSD) which cannot use [`revise_dir_queued`](@ref).
"""
function revise_file_queued(file)
    if !isfile(file)
        sleep(0.1)  # in case git has done a delete/replace cycle
        if !isfile(file)
            with_logger(SimpleLogger(stderr)) do
                @error "$file is not an existing file, Revise is not watching"
            end
            return nothing
        end
    end

    wait_changed(file)  # will block here until the file changes
    push!(revision_queue, file)
    @async revise_file_queued(file)
end

"""
    Revise.revise_file_now(file)

Process revisions to `file`. This parses `file` and computes an expression-level diff
between the current state of the file and its most recently evaluated state.
It then deletes any removed methods and re-evaluates any changed expressions.

`file` must be a key in [`Revise.file2modules`](@ref)
"""
function revise_file_now(file)
    if !haskey(file2modules, file)
        println("Revise is currently tracking the following files: ", keys(file2modules))
        error(file, " is not currently being tracked.")
    end
    oldmd = file2modules[file]
    if isempty(oldmd.md)
        # Source was never parsed, get it from the precompile cache
        src = read_from_cache(oldmd, file)
        push!(oldmd.md, oldmd.topmod=>ExprsSigs())
        if !parse_source!(oldmd.md, src, Symbol(file), 1, oldmd.topmod)
            @error "failed to parse cache file source text for $file"
        end
    end
    pr = parse_source(file, oldmd.topmod)
    if pr != nothing
        newmd = pr.second
        revmd = revised_statements(newmd.md, oldmd.md)
        if eval_revised(revmd)
            file2modules[file] = newmd
            for p in workers()
                p == myid() && continue
                try
                    remotecall(Revise.eval_revised, p, revmd)
                catch err
                    @error "error revising worker $p"
                    showerror(stderr, err)
                end
            end
        end
    end
    nothing
end

function read_from_cache(fm::FileModules, file::AbstractString)
    if fm.cachefile == basesrccache
        return open(basesrccache) do io
            Base._read_dependency_src(io, file)
        end
    end
    Base.read_dependency_src(fm.cachefile, file)
end

"""
    revise()

`eval` any changes in the revision queue. See [`Revise.revision_queue`](@ref).
"""
function revise()
    sleep(0.01)  # in case the file system isn't quite done writing out the new files
    for file in revision_queue
        revise_file_now(file)
    end
    empty!(revision_queue)
    tracking_Main_includes[] && queue_includes(Main)
    nothing
end

# This variant avoids unhandled task failures
function revise(backend::REPL.REPLBackend)
    sleep(0.01)  # in case the file system isn't quite done writing out the new files
    for file in revision_queue
        try
            revise_file_now(file)
        catch err
            put!(backend.response_channel, (err, catch_backtrace()))
        end
    end
    empty!(revision_queue)
    tracking_Main_includes[] && queue_includes(Main)
    nothing
end

"""
    revise(mod::Module)

Reevaluate every definition in `mod`, whether it was changed or not. This is useful
to propagate an updated macro definition, or to force recompiling generated functions.

Returns `true` if all revisions in `mod` were successfully implemented.
"""
function revise(mod::Module)
    all(map(file -> eval_revised(file2modules[file].md, false), module2files[Symbol(mod)]))
end

"""
    Revise.track(mod::Module, file::AbstractString)
    Revise.track(file::AbstractString)

Watch `file` for updates and [`revise`](@ref) loaded code with any
changes. `mod` is the module into which `file` is evaluated; if omitted,
it defaults to `Main`.
"""
function track(mod::Module, file::AbstractString)
    isfile(file) || error(file, " is not a file")
    file = normpath(abspath(file))
    pr = parse_source(file, mod)
    if isa(pr, Pair)
        push!(file2modules, pr)
    end
    init_watching((file,))
end

track(file::AbstractString) = track(Main, file)

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

function macroreplace!(ex::Expr, filename)
    for i = 1:length(ex.args)
        ex.args[i] = macroreplace!(ex.args[i], filename)
    end
    if ex.head == :macrocall
        m = ex.args[1]
        if m == Symbol("@__FILE__")
            return String(filename)
        elseif m == Symbol("@__DIR__")
            return dirname(String(filename))
        end
    end
    return ex
end
macroreplace!(s, filename) = s

"""
    steal_repl_backend(backend = Base.active_repl_backend)

Replace the REPL's normal backend with one that calls [`revise`](@ref) before executing
any REPL input.
"""
function steal_repl_backend(backend = Base.active_repl_backend)
    # terminate the current backend
    put!(backend.repl_channel, (nothing, -1))
    fetch(backend.backend_task)
    # restart a new backend that differs only by processing the
    # revision queue before evaluating each user input
    backend.backend_task = @async begin
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
    end
    backend
end

"""
    Revise.async_steal_repl_backend()

Wait for the REPL to complete its initialization, and then call [`steal_repl_backend`](@ref).
This is necessary because code registered with `atreplinit` runs before the REPL is
initialized, and there is no corresponding way to register code to run after it is complete.
"""
function async_steal_repl_backend()
    atreplinit() do repl
        @async begin
            iter = 0
            # wait for active_repl_backend to exist
            while !isdefined(Base, :active_repl_backend) && iter < 20
                sleep(0.05)
                iter += 1
            end
            if isdefined(Base, :active_repl_backend)
                steal_repl_backend(Base.active_repl_backend)
            else
                @warn "REPL initialization failed, Revise is not watching files."
            end
        end
    end
    return nothing
end

function __init__()
    # Base.register_root_module(Base.__toplevel__)
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
            steal_repl_backend()
        elseif isdefined(Main, :IJulia)
            Main.IJulia.push_preexecute_hook(revise)
        end
        if isdefined(Main, :Atom)
            for x in ["eval", "evalall", "evalrepl"]
                old = Main.Atom.handlers[x]
                Main.Atom.handle(x) do data
                    revise()
                    old(data)
                end
            end
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
end

## WatchList utilities
function systime()
    tv = Libc.TimeVal()
    tv.sec + tv.usec/10^6
end
function updatetime!(wl::WatchList)
    wl.timestamp = systime()
end
Base.push!(wl::WatchList, filename) = push!(wl.trackedfiles, filename)
WatchList() = WatchList(systime(), Set{String}())
Base.in(file, wl::WatchList) = in(file, wl.trackedfiles)

end # module
