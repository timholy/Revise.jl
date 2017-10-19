__precompile__(true)

module Revise

VERSION >= v"0.7.0-DEV.2359" && using FileWatching

using DataStructures: OrderedSet

export revise

include("relocatable_exprs.jl")
include("types.jl")
include("parsing.jl")

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
const basesrccache = joinpath(JULIA_HOME, Base.DATAROOTDIR, "julia", "base.cache")

## For excluding packages from tracking by Revise
const dont_watch_pkgs = Set{Symbol}()
const silence_pkgs = Set{Symbol}()
const depsdir = joinpath(dirname(@__DIR__), "deps")
const silencefile = Ref(joinpath(depsdir, "silence.txt"))  # Ref so that tests don't clobber

"""
    revmod = revised_statements(new_defs, old_defs)

Return a `Dict(Module=>changeset)`, `revmod`, listing the changes that
should be `eval`ed for each module to update definitions from `old_defs` to
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

revised_statements(mod::Module, newdefs::OrderedSet, olddefs::OrderedSet) =
    revised_statements!(ModDict(), mod, newdefs, olddefs)

function revised_statements!(revmd::ModDict, mod::Module,
                             newdefs::OrderedSet, olddefs::OrderedSet)
    for stmt in newdefs
        if isa(stmt, RelocatableExpr)
            stmt = stmt::RelocatableExpr
            @assert stmt.head != :module
            if stmt ∉ olddefs
                if !haskey(revmd, mod)
                    revmd[mod] = OrderedSet{RelocatableExpr}()
                end
                push!(revmd[mod], stmt)
            end
        end
    end
    revmd
end

function eval_revised(revmd::ModDict)
    for (mod, exprs) in revmd
        mod = mod == Base.__toplevel__ ? Main : mod
        for rex in exprs
            ex = convert(Expr, rex)
            try
                eval(mod, ex)
            catch err
                warn("failure to evaluate changes in ", mod)
                println(STDERR, ex)
            end
        end
    end
end

function use_compiled_modules()
    @static if VERSION >= v"0.7.0-DEV.1698"
        return Base.JLOptions().use_compiled_modules != 0
    else
        return Base.JLOptions().use_compilecache != 0
    end
end

"""
    parse_pkg_files(modsym)

This function gets called by `watch_package` and runs when a package is first loaded.
Its job is to organize the files and expressions defining the module so that later we can
detect and process revisions.
"""
function parse_pkg_files(modsym::Symbol)
    paths = String[]
    if use_compiled_modules()
        paths = Base.find_all_in_cache_path(modsym)
    end
    files = String[]
    if !isempty(paths)
        # We got the top-level file from the precompile cache
        length(paths) > 1 && error("Multiple paths detected: ", paths)
        _, mods_files_mtimes = Base.parse_cache_header(paths[1])
        for (modname, fname, _) in mods_files_mtimes
            modname == "#__external__" && continue
            mod = Base.root_module(Symbol(modname))
            # For precompiled packages, we can read the source later (whenever we need it)
            # from the *.ji cachefile.
            push!(file2modules, fname=>FileModules(mod, ModDict(), paths[1]))
            push!(files, fname)
        end
    else
        # Non-precompiled package(s). Here we rely on the `include` callbacks to have
        # already populated `included_files`; all we have to do is collect the relevant
        # files. The main trick here is that since `using` is recursive, `included_files`
        # might contain files associated with many different packages. We have to figure
        # out which correspond to `modsym`, which we do by:
        #   - checking the module in which each file is evaluated. This suffices to
        #     detect "supporting" files, i.e., those `included` within the module
        #     definition.
        #   - checking the filename. Since the "top level" file is evaluated into Main,
        #     we can't use the module-of-evaluation to find it. Here we hope that the
        #     top-level filename follows convention and matches the module. TODO?: it's
        #     possible that this needs to be supplemented with parsing.
        i = 1
        modstring = string(modsym)
        while i <= length(included_files)
            mod, fname = included_files[i]
            modname = String(Symbol(mod))
            if startswith(modname, modstring) || endswith(fname, modstring*".jl")
                pr = parse_source(fname, mod)
                if isa(pr, Pair)
                    push!(file2modules, pr)
                end
                push!(files, fname)
                deleteat!(included_files, i)
            else
                i += 1
            end
        end
    end
    module2files[modsym] = files
    files
end

# A near-duplicate of some of the functionality of parse_pkg_files
# This gets called for silenced packages, to make sure they don't "contaminate"
# included_files
function remove_from_included_files(modsym::Symbol)
    i = 1
    modstring = string(modsym)
    while i <= length(included_files)
        mod, fname = included_files[i]
        modname = String(Symbol(mod))
        if startswith(modname, modstring) || endswith(fname, modstring*".jl")
            deleteat!(included_files, i)
        else
            i += 1
        end
    end
end

function watch_files_via_dir(dirname)
    watch_file(dirname)  # this will block until there is a modification
    latestfiles = String[]
    wf = watched_files[dirname]
    for file in wf.trackedfiles
        path = joinpath(dirname, file)
        if mtime(path) + 1 >= floor(wf.timestamp) # OSX rounds mtime up, see #22
            push!(latestfiles, path)
        end
    end
    updatetime!(wf)
    latestfiles
end

"""
    watch_package(modsym)

This function gets called via a callback registered with `Base.require`, at the completion
of module-loading by `using` or `import`.
"""
function watch_package(modsym::Symbol)
    # Because the callbacks are made with `invokelatest`, for reasons of performance
    # we need to make sure this function is fast to compile. By hiding the real
    # work behind a @schedule, we truncate the chain of dependency.
    @schedule _watch_package(modsym)
end

function _watch_package(modsym::Symbol)
    if modsym ∈ dont_watch_pkgs
        if modsym ∉ silence_pkgs
            warn("$modsym is excluded from watching by Revise. Use Revise.silence(\"$modsym\") to quiet this warning.")
        end
        remove_from_included_files(modsym)
        return nothing
    end
    files = parse_pkg_files(modsym)
    process_parsed_files(files)
end

function process_parsed_files(files)
    udirs = Set{String}()
    for file in files
        dir, basename = splitdir(file)
        haskey(watched_files, dir) || (watched_files[dir] = WatchList())
        push!(watched_files[dir], basename)
        push!(udirs, dir)
    end
    for dir in udirs
        updatetime!(watched_files[dir])
        @schedule revise_dir_queued(dir)
    end
    return nothing
end

function revise_dir_queued(dirname)
    if !isdir(dirname)
        sleep(0.1)   # in case git has done a delete/replace cycle
        if !isfile(dirname)
            warn(dirname, " is not an existing directory, Revise is not watching")
            return nothing
        end
    end
    latestfiles = watch_files_via_dir(dirname)  # will block here until file(s) change
    for file in latestfiles
        push!(revision_queue, file)
    end
    @schedule revise_dir_queued(dirname)
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
        push!(oldmd.md, oldmd.topmod=>OrderedSet{RelocatableExpr}())
        if !parse_source!(oldmd.md, src, Symbol(file), 1, oldmd.topmod)
            warn("failed to parse cache file source text for ", file)
        end
    end
    pr = parse_source(file, oldmd.topmod)
    if pr != nothing
        newmd = pr.second
        revmd = revised_statements(newmd.md, oldmd.md)
        try
            eval_revised(revmd)
            file2modules[file] = newmd
        catch err
            warn("evaluation error during revision: ", err)
            Base.show_backtrace(STDERR, catch_backtrace())
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
        eval_revised(file2modules[file].md)
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
    wait(backend.backend_task)
    # restart a new backend that differs only by processing the
    # revision queue before evaluating each user input
    backend.backend_task = @schedule begin
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
            Base.REPL.eval_user_input(ast, backend)
        end
    end
    backend
end

function __init__()
    Base.register_root_module(Symbol("Base.__toplevel__"), Base.__toplevel__)
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
            @schedule steal_repl_backend()
        elseif isdefined(Main, :IJulia)
            Main.IJulia.push_preexecute_hook(revise)
        elseif isdefined(Main, :Atom)
            for x in ["eval", "evalall", "evalrepl"]
                old = Main.Atom.handlers[x]
                Main.Atom.handle(x) do data
                    revise()
                    old(data)
                end
            end
        end
    end
end

## WatchList utilities
function updatetime!(wl::WatchList)
    tv = Libc.TimeVal()
    wl.timestamp = tv.sec + tv.usec/10^6
end
Base.push!(wl::WatchList, filename) = push!(wl.trackedfiles, filename)
WatchList() = WatchList(Dates.datetime2unix(now()), Set{String}())
Base.in(file, wl::WatchList) = in(file, wl.trackedfiles)

end # module
