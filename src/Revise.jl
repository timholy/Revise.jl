__precompile__(true)

module Revise

using FileWatching, REPL, Base.CoreLogging
using Distributed
using Compat
using Compat.REPL

if VERSION < v"0.7.0-DEV.3483"
    register_root_module(m::Module) = Base.register_root_module(Base.module_name(m), m)
else
    register_root_module(m::Module) = Base.register_root_module(m)
end

if VERSION < v"0.7.0-DEV.3936"
    taskfetch(t::Task) = wait(t)
else
    taskfetch(t::Task) = fetch(t)
end

using DataStructures: OrderedSet

export revise

# Should we watch directories or files? FreeBSD and NFS-mounted systems should watch files,
# otherwise we watch directories.
const watching_files = Ref(Sys.KERNEL == :FreeBSD)

# The following two definitions are motivated by wishing to support code stored on
# NFS-mounted shares, where it needs to use `poll_file` instead of `watch_file`. See #60
# and the `JULIA_REVISE_POLL` environment variable.
const polling_files = Ref(false)
function wait_changed(file)
    polling_files[] ? poll_file(file) : watch_file(file)
    return nothing
end

include("relocatable_exprs.jl")
include("types.jl")
include("parsing.jl")
include("delete_method.jl")

if VERSION < v"0.7.0-DEV.3483"
    include("pkgs_deprecated.jl")
else
    include("pkgs.jl")
end

### Globals to keep track of state
# revision_queue holds the names of files that we need to revise, meaning that these
# files have changed since we last processed a revision. This list gets populated
# by callbacks that watch directories for updates.
const revision_queue = Set{String}()
# watched_files[dirname] returns the list of files in dirname that we're monitoring for changes
const watched_files = Dict{String,WatchList}()

# file2modules is indexed by absolute paths of files, and provides access to the parsed
# source code defined in the file. The expressions in the source code are organized by the
# module in which they should be evaluated.
const file2modules = Dict{String,FileModules}()
# module2files holds the list of filenames used to define a particular module
const module2files = Dict{Symbol,Vector{String}}()

# included_files gets populated by callbacks we register with `include`. It's used
# to track non-precompiled packages.
const included_files = Tuple{Module,String}[]  # (module, filename)

# Full path to the running Julia's cache of source code defining Base
if VERSION < v"0.7.0-DEV.3073" # https://github.com/JuliaLang/julia/pull/25102
    const basesrccache = joinpath(JULIA_HOME, Base.DATAROOTDIR, "julia", "base.cache")
else
    const basesrccache = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base.cache")
end

## For excluding packages from tracking by Revise
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
                    m = get_method(mod, sig)
                    isa(m, Method) && Base.delete_method(m)
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
                println(stderr, ex)
            end
        end
    end
    succeeded
end

function use_compiled_modules()
    @static if VERSION >= v"0.7.0-DEV.1698"
        return Base.JLOptions().use_compiled_modules != 0
    else
        return Base.JLOptions().use_compilecache != 0
    end
end

function process_parsed_files(files)
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

# Require by FreeBSD.
# Because the behaviour of `watch_file` is different on FreeBSD.
# See #66.
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

`eval` any changes in tracked files in the appropriate modules.
"""
function revise()
    sleep(0.01)  # in case the file system isn't quite done writing out the new files
    for file in revision_queue
        revise_file_now(file)
    end
    empty!(revision_queue)
    nothing
end

"""
    revise(mod::Module)

Reevaluate every definition in `mod`, whether it was changed or not. This is useful
to propagate an updated macro definition, or to force recompiling generated functions.
"""
function revise(mod::Module)
    for file in module2files[Symbol(mod)]
        eval_revised(file2modules[file].md, false)
    end
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
    process_parsed_files((file,))
end
track(file::AbstractString) = track(Main, file)

"""
    Revise.track(Base)

Track the code in Julia's `base` directory for updates. This
facilitates making changes to Julia itself and testing them
immediately (without rebuilding).

At present some files in Base are not trackable, see the README.
"""
function track(mod::Module)
    if mod == Base
        # Determine when the basesrccache was built
        mtcache = mtime(basesrccache)
        # Initialize expression-tracking for files, and
        # note any modified since Base was built
        files = String[]
        for (submod, filename) in Base._included_files
            push!(file2modules, filename=>FileModules(submod, ModDict(), basesrccache))
            push!(files, filename)
            if mtime(filename) > mtcache
                push!(revision_queue, filename)
            end
        end
        # Add the files to the watch list
        process_parsed_files(files)
    else
        error("no Revise.track recipe for module ", mod)
    end
    nothing
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
if VERSION < v"0.7.0-DEV.328"
    file_line_statement(lnn::LineNumberNode, file::Symbol, line_offset) =
        LineNumberNode(lnn.line + line_offset)
else
    file_line_statement(lnn::LineNumberNode, file::Symbol, line_offset) =
        LineNumberNode(lnn.line + line_offset, file)
end

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

function steal_repl_backend(backend = Base.active_repl_backend)
    # terminate the current backend
    put!(backend.repl_channel, (nothing, -1))
    taskfetch(backend.backend_task)
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
            revise()
            REPL.eval_user_input(ast, backend)
        end
    end
    backend
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
            @async steal_repl_backend()
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
