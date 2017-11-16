__precompile__()

module Revise

VERSION >= v"0.7.0-DEV.2359" && using FileWatching

using DataStructures: OrderedSet

export revise

const revision_queue = Set{String}()  # file names that have changed since last revision
# Some platforms (OSX) have trouble watching too many files. So we
# watch parent directories, and keep track of which files in them
# should be tracked.
mutable struct WatchList
    timestamp::Float64         # unix time of last revision
    trackedfiles::Set{String}
end
const watched_files = Dict{String,WatchList}()

## For excluding packages from tracking by Revise
const dont_watch_pkgs = Set{Symbol}()
const silence_pkgs = Set{Symbol}()
const depsdir = joinpath(dirname(@__DIR__), "deps")
const silencefile = Ref(joinpath(depsdir, "silence.txt"))  # Ref so that tests don't clobber

## Structures to manipulate parsed files

# We will need to detect new function bodies, compare function bodies
# to see if they've changed, etc.  This has to be done "blind" to the
# line numbers at which the functions are defined.
#
# Now, we could just discard line numbers from expressions, but that
# would have a very negative effect on the quality of backtraces. So
# we keep them, but introduce machinery to compare expressions without
# concern for line numbers.
#
# To reduce the performance overhead of this package, we try to
# achieve this goal with minimal copying of data.

"""
A `RelocatableExpr` is exactly like an `Expr` except that comparisons
between `RelocatableExpr`s ignore line numbering information.
"""
mutable struct RelocatableExpr
    head::Symbol
    args::Vector{Any}
    typ::Any

    RelocatableExpr(head::Symbol, args::Vector{Any}) = new(head, args)
    RelocatableExpr(head::Symbol, args...) = new(head, [args...])
end

# Works in-place and hence is unsafe. Only for internal use.
Base.convert(::Type{RelocatableExpr}, ex::Expr) = relocatable!(ex)

function relocatable!(ex::Expr)
    rex = RelocatableExpr(ex.head, relocatable!(ex.args))
    rex.typ = ex.typ
    rex
end

function relocatable!(args::Vector{Any})
    for (i, a) in enumerate(args)
        if isa(a, Expr)
            args[i] = relocatable!(a::Expr)
        end   # do we need to worry about QuoteNodes?
    end
    args
end

function Base.convert(::Type{Expr}, rex::RelocatableExpr)
    # This makes a copy. Used for `eval`, where we don't want to
    # mutate the cached represetation.
    ex = Expr(rex.head)
    ex.args = Base.copy_exprargs(rex.args)
    ex.typ = rex.typ
    ex
end
Base.copy_exprs(rex::RelocatableExpr) = convert(Expr, rex)

# Implement the required comparison functions. `hash` is needed for Dicts.
function Base.:(==)(a::RelocatableExpr, b::RelocatableExpr)
    a.head == b.head && isequal(LineSkippingIterator(a.args), LineSkippingIterator(b.args))
end

const hashrex_seed = UInt == UInt64 ? 0x7c4568b6e99c82d9 : 0xb9c82fd8
Base.hash(x::RelocatableExpr, h::UInt) = hash(LineSkippingIterator(x.args),
                                              hash(x.head, h + hashrex_seed))

# We could just collect all the non-line statements to a Vector, but
# doing things in-place will be more efficient.

struct LineSkippingIterator
    args::Vector{Any}
end

Base.start(iter::LineSkippingIterator) = skip_to_nonline(iter.args, 1)
Base.done(iter::LineSkippingIterator, i) = i > length(iter.args)
Base.next(iter::LineSkippingIterator, i) = (iter.args[i], skip_to_nonline(iter.args, i+1))

function skip_to_nonline(args, i)
    while true
        i > length(args) && return i
        ex = args[i]
        if isa(ex, RelocatableExpr) && (ex::RelocatableExpr).head == :line
            i += 1
        elseif isa(ex, LineNumberNode)
            i += 1
        else
            return i
        end
    end
end

function Base.isequal(itera::LineSkippingIterator, iterb::LineSkippingIterator)
    # We could use `zip` here except that we want to insist that the
    # iterators also have the same length.
    ia, ib = start(itera), start(iterb)
    while !done(itera, ia) && !done(iterb, ib)
        vala, ia = next(itera, ia)
        valb, ib = next(iterb, ib)
        if isa(vala, RelocatableExpr) && isa(valb, RelocatableExpr)
            vala = vala::RelocatableExpr
            valb = valb::RelocatableExpr
            vala.head == valb.head || return false
            isequal(LineSkippingIterator(vala.args), LineSkippingIterator(valb.args)) || return false
        else
            isequal(vala, valb) || return false
        end
    end
    done(itera, ia) && done(iterb, ib)
end

const hashlsi_seed = UInt == UInt64 ? 0x533cb920dedccdae : 0x2667c89b
function Base.hash(iter::LineSkippingIterator, h::UInt)
    h += hashlsi_seed
    for x in iter
        h += hash(x, h)
    end
    h
end

"""

A `ModDict` is a `Dict{Module,Set{RelocatableExpr}}`. It is used to
organize expressions according to their module of definition. We use a
Set so that it is easy to find the differences between two `ModDict`s.

See also [`FileModules`](@ref).
"""
const ModDict = Dict{Module,OrderedSet{RelocatableExpr}}

"""
    FileModules(topmod::Module, md::ModDict)

Structure to hold the per-module expressions found when parsing a
single file.  `topmod` is the current module when the file is
parsed. `md` holds the evaluatable statements, organized by the module
of their occurance. In particular, if the file defines one or
more new modules, then `md` contains key/value pairs for each
module. If the file does not define any new modules, `md[topmod]` is
the only entry in `md`.

# Example:

Suppose MyPkg.jl has a file that looks like this:

```julia
__precompile__(true)

module MyPkg

foo(x) = x^2

end
```

Then if this module is loaded from `Main`, schematically the
corresponding `fm::FileModules` looks something like

```julia
fm.topmod = Main
fm.md = Dict(Main=>OrderedSet([:(__precompile__(true))]),
             Main.MyPkg=>OrderedSet[:(foo(x) = x^2)])
```
because the precompile statement occurs in `Main`, and the definition of
`foo` occurs in `Main.MyPkg`.

To create a `FileModules` from a source file, see [`parse_source`](@ref).
"""
struct FileModules
    topmod::Module
    md::ModDict
end

# Now it's easy to find the revised statements

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
            # if stmt.head == :module
            #     # We have to recurse into module definitions
            #     modsym = _module_name(stmt)
            #     oldstmt = find_module_def(olddefs, modsym)
            #     revised_statements!(revmd, getfield(mod, modsym)::Module,
            #                         Set(stmt.args), Set(oldstmt.args))
            # else
                if stmt ∉ olddefs
                    if !haskey(revmd, mod)
                        revmd[mod] = OrderedSet{RelocatableExpr}()
                    end
                    push!(revmd[mod], stmt)
                end
            # end
        end
    end
    revmd
end

# function find_module_def(s::Set, modsym::Symbol)
#     for ex in s
#         if ex.head == :module && _module_name(ex) == modsym
#             return ex
#         end
#     end
#     error("definition for module $modsym not found in $s")
# end

function eval_revised(revmd::ModDict)
    for (mod, exprs) in revmd
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

const file2modules = Dict{String,FileModules}()
const module2files = Dict{Symbol,Vector{String}}()
const new_files = String[]

function use_compiled_modules()
    @static if VERSION >= v"0.7.0-DEV.1698"
        return Base.JLOptions().use_compiled_modules != 0
    else
        return Base.JLOptions().use_compilecache != 0
    end
end

function parse_pkg_files(modsym::Symbol)
    paths = String[]
    if use_compiled_modules()
        # If we can, let's use the precompile cache. That is
        # guaranteed to have a complete list of the included files,
        # something that can't be guaranteed if we rely on parsing:
        #     for file in files
        #         include(file)
        #     end
        # isn't something that Revise can handle. Unfortunately we
        # can't fully exploit this just yet, see below.
        paths = Base.find_all_in_cache_path(modsym)
    end
    if !isempty(paths)
        # We got it from the precompile cache
        length(paths) > 1 && error("Multiple paths detected: ", paths)
        _, files_mtimes = Base.cache_dependencies(paths[1])
        files = map(ft->normpath(first(ft)), files_mtimes)   # idx 1 is the filename, idx 2 is the mtime
        mainfile = first(files)
        # We still have to parse the source code, and if there are
        # multiple modules then we don't know which module to `eval`
        # them into.
        parse_source(mainfile, Main, dirname(mainfile))
    else
        # Non-precompiled package, so we learn the list of files through parsing
        mainfile = Base.find_source_file(string(modsym))
        empty!(new_files)
        parse_source(mainfile, Main, dirname(mainfile))
        files = map(normpath, new_files)
    end
    module2files[modsym] = files
    files
end

"""
    md = parse_source(file::AbstractString, mod::Module, path)

Parse the source `file`, returning a `ModuleDict` `md` containing the
set of RelocatableExprs for each module defined in `file`. `mod` is
the "parent" module for the file; if `file` defines more module(s)
then these will all have separate entries in `md`.

Set `path` to be the directory name of `file` if you want to recurse
into any `include`d files and add them to `Revise.file2modules`. (This
is appropriate for when you parse a package/module definition upon
initial load.) Otherwise set `path=nothing`.

If parsing `file` fails, `nothing` is returned.
"""
function parse_source(file::AbstractString, mod::Module, path)
    # Create a blank ModDict to store the expressions. Parsing will "fill" this.
    md = ModDict(mod=>OrderedSet{RelocatableExpr}())
    nfile = normpath(file)
    if path != nothing
        # Parsing is recursive (depth-first), so to preserve the order
        # we add `file` to the list now
        push!(new_files, nfile)
    end
    if !parse_source!(md, file, mod, path)
        pop!(new_files)  # since it failed, remove it from the list
        return nothing
    end
    fm = FileModules(mod, md)
    if path != nothing
        file2modules[nfile] = fm
    end
    fm
end

"""
    success = parse_source!(md::ModDict, file, mod::Module, path)

Top-level parsing of `file` as included into module
`mod`. Successfully-parsed expressions will be added to `md`. Returns
`true` if parsing finished successfully.

See also [`parse_source`](@ref).
"""
function parse_source!(md::ModDict, file::AbstractString, mod::Module, path)
    if !isfile(file)
        warn("omitting ", file, " from revision tracking")
        return false
    end
    if VERSION >= v"0.7.0-DEV.1053"
        parse_source!(md, read(file, String), Symbol(file), 1, mod, path)
    else
        parse_source!(md, readstring(file), Symbol(file), 1, mod, path)
    end
end

"""
    success = parse_source!(md::ModDict, src::AbstractString, file::Symbol, pos::Integer, mod::Module, path)

Parse a string `src` obtained by reading `file` as a single
string. `pos` is the 1-based byte offset from which to begin parsing `src`.

See also [`parse_source`](@ref).
"""
function parse_source!(md::ModDict, src::AbstractString, file::Symbol, pos::Integer, mod::Module, path)
    local ex, oldpos
    # Since `parse` doesn't keep track of line numbers (it works
    # expression-by-expression), to ensure good backtraces we have to
    # keep track of them here. For each expression we parse, we count
    # the number of linefeed characters that occurred between the
    # beginning and end of the portion of the string consumed to parse
    # the expression.
    line_offset = 0
    while pos < endof(src)
        try
            oldpos = pos
            ex, pos = Meta.parse(src, pos; greedy=true)
        catch err
            ex, posfail = Meta.parse(src, pos; greedy=true, raise=false)
            warn(STDERR, "omitting ", file, " due to parsing error near line ",
                 line_offset + count(c->c=='\n', SubString(src, oldpos, posfail)) + 1)
            showerror(STDERR, err)
            println(STDERR)
            return false
        end
        if isa(ex, Expr)
            ex = ex::Expr
            fix_line_statements!(ex, file, line_offset)  # fixes the backtraces
            parse_expr!(md, ex, file, mod, path)
        end
        # Update the number of lines
        line_offset += count(c->c=='\n', SubString(src, oldpos, pos-1))
    end
    true
end

"""
    success = parse_source!(md::ModDict, ex::Expr, file, mod::Module, path)

For a `file` that defines a sub-module, parse the body `ex` of the
sub-module.  `mod` will be the module into which this sub-module is
evaluated (i.e., included). Successfully-parsed expressions will be
added to `md`. Returns `true` if parsing finished successfully.

See also [`parse_source`](@ref).
"""
function parse_source!(md::ModDict, ex::Expr, file::Symbol, mod::Module, path)
    @assert ex.head == :block
    for a in ex.args
        if isa(a, Expr)
            parse_expr!(md, a::Expr, file, mod, path)
        end
    end
    md
end

"""
    parse_expr!(md::ModDict, ex::Expr, file::Symbol, mod::Module, path)

Recursively parse the expressions in `ex`, iterating over blocks,
sub-module definitions, `include` statements, etc. Successfully parsed
expressions are added to `md` with key `mod`, and any sub-modules will
be stored in `md` using appropriate new keys. This accomplishes three main
tasks:

* add parsed expressions to the source-code cache (so that later we can detect changes)
* determine the module into which each parsed expression is `eval`uated into
* detect `include` statements so that we know to recurse into
  additional files, attempting to extract accurate path information
  even when using constructs such as `@__FILE__`.
"""
function parse_expr!(md::ModDict, ex::Expr, file::Symbol, mod::Module, path)
    if ex.head == :block
        for a in ex.args
            parse_expr!(md, a, file, mod, path)
        end
        return md
    end
    macroreplace!(ex, String(file))
    if ex.head == :line
        return md
    elseif ex.head == :module
        parse_module!(md, ex, file, mod, path)
    elseif isdocexpr(ex) && isa(ex.args[nargs_docexpr], Expr) && ex.args[nargs_docexpr].head == :module
        # Module with a docstring (issue #8)
        # Split into two expressions, a module definition followed by
        # `"docstring" newmodule`
        newmod = parse_module!(md, ex.args[nargs_docexpr], file, mod, path)
        ex.args[nargs_docexpr] = Symbol(newmod)
        push!(md[mod], convert(RelocatableExpr, ex))
    elseif ex.head == :call && ex.args[1] == :include
        # Extract the filename. This is easy if it's a simple string,
        # but if it involves `joinpath` expressions or other such
        # shenanigans, it's a little trickier.
        # Unfortunately expressions like `include(filename)` where
        # `filename` is a variable cannot be handled. Such files are not tracked.
        if path != nothing
            filename = ex.args[end]
            if isa(filename, AbstractString)
            elseif isa(filename, Symbol)
                if isdefined(mod, filename)
                    filename = getfield(mod, filename)
                    if !isa(filename, AbstractString)
                        warn(filename, " is not a string")
                        return md
                    end
                else
                    warn("unable to resolve filename ", filename)
                    return md
                end
            elseif isa(filename, Expr)
                try
                    filename = eval(mod, filename)
                catch
                    warn("could not parse `include` expression ", filename)
                    return md
                end
            else
                error(filename, " not recognized")
            end
            if !isabspath(filename)
                filename = joinpath(path, filename)
            end
            dir, fn = splitdir(filename)
            parse_source(filename, mod, joinpath(path, dir))
        end
        # Note that if path == nothing (we're parsing the file to
        # detect changes compared to the cached version), then we skip
        # the include statement.
    else
        # Any expression that *doesn't* define line numbers, new
        # modules, or include new files must be "real code." Add it to
        # the cache.
        push!(md[mod], convert(RelocatableExpr, ex))
    end
    md
end

"""
    newmod = parse_module!(md::ModDict, ex::Expr, file, mod::Module, path)

Parse an expression `ex` that defines a new module `newmod`. This
module is "parented" by `mod`. Source-code expressions are added to
`md` under the appropriate module name.
"""
function parse_module!(md::ModDict, ex::Expr, file::Symbol, mod::Module, path)
    mod = moduleswap(mod)
    mname = _module_name(ex)
    if !isdefined(mod, mname)
        eval(mod, ex)
    end
    newmod = getfield(mod, mname)
    md[newmod] = OrderedSet{RelocatableExpr}()
    parse_source!(md, ex.args[3], file, newmod, path)  # recurse into the body of the module
    newmod
end
if VERSION >= v"0.7.0-DEV.1877"
    moduleswap(mod) = mod == Base.__toplevel__ ? Main : mod
else
    moduleswap(mod) = mod
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
        return nothing
    end
    @schedule watch_package_impl(modsym)
    nothing
end

function watch_package_impl(modsym)
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

function revise_file_now(file0)
    file = normpath(file0)
    if !haskey(file2modules, file)
        println("Revise is currently tracking the following files: ", keys(file2modules))
        error(file, " is not currently being tracked.")
    end
    oldmd = file2modules[file]
    newmd = parse_source(file, oldmd.topmod, nothing)
    if newmd != nothing
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
changes. If `mod` is omitted it defaults to `Main`.
"""
function track(mod::Module, file::AbstractString)
    isfile(file) || error(file, " is not a file")
    empty!(new_files)
    file = normpath(abspath(file))
    parse_source(file, mod, dirname(file))
    process_parsed_files(new_files)
end
track(file::AbstractString) = track(Main, file)

const sysimg_path =  # where `baremodule Base` is defined
    realpath(joinpath(JULIA_HOME, Base.DATAROOTDIR, "julia", "base", "sysimg.jl"))

"""
    Revise.track(Base)

Track the code in Julia's `base` directory for updates. This
facilitates making changes to Julia itself and testing them
immediately (without rebuilding).

At present some files in Base are not trackable, see the README.
"""
function track(mod::Module)
    if mod == Base
        empty!(new_files)
        parse_source(sysimg_path, Main, dirname(sysimg_path))
        process_parsed_files(new_files)
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

_module_name(ex::Expr) = ex.args[2]

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

const nargs_docexpr = VERSION < v"0.7.0-DEV.328" ? 3 : 4
isdocexpr(ex) = ex.head == :macrocall && ex.args[1] == GlobalRef(Core, Symbol("@doc")) &&
           length(ex.args) >= nargs_docexpr

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
    if isfile(silencefile[])
        pkgs = readlines(silencefile[])
        for pkg in pkgs
            push!(silence_pkgs, Symbol(pkg))
        end
    end
    push!(Base.package_callbacks, watch_package)
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
