__precompile__()

module Revise

export revise

const revision_queue = Set{String}()  # file names that have changed since last revision

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
const ModDict = Dict{Module,Set{RelocatableExpr}}

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
fm.md = Dict(Main=>Set([:(__precompile__(true))]), Main.MyPkg=>Set[:(foo(x) = x^2)])
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
        revised_statements!(revmd, mod, newdefs, oldmd[mod])
    end
    revmd
end

revised_statements(mod::Module, newdefs::Set, olddefs::Set) =
    revised_statements!(ModDict(), mod, newdefs, olddefs)

function revised_statements!(revmd::ModDict, mod::Module,
                             newdefs::Set, olddefs::Set)
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
                        revmd[mod] = Set{RelocatableExpr}()
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
const new_files = String[]

function parse_pkg_files(modsym::Symbol)
    paths = String[]
    if Base.JLOptions().use_compilecache != 0
        paths = Base.find_all_in_cache_path(modsym)
    end
    if !isempty(paths)
        length(paths) > 1 && error("Multiple paths detected: ", paths)
        _, files_mtimes = Base.cache_dependencies(paths[1])
        files = map(first, files_mtimes)   # idx 1 is the filename, idx 2 is the mtime
        mainfile = first(files)
        parse_source(mainfile, Main, dirname(mainfile))
    else
        mainfile = Base.find_source_file(string(modsym))
        empty!(new_files)
        parse_source(mainfile, Main, dirname(mainfile))
        files = new_files
    end
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
    md = ModDict(mod=>Set{RelocatableExpr}())
    if !parse_source!(md, file, mod, path)
        return nothing
    end
    fm = FileModules(mod, md)
    if path != nothing
        nfile = normpath(file)
        file2modules[nfile] = fm
        push!(new_files, nfile)
    end
    fm
end

function parse_source!(md::ModDict, file::AbstractString, mod::Module, path)
    if !isfile(file)
        warn("omitting ", file, " from revision tracking")
        return false
    end
    parse_source!(md, readstring(file), Symbol(file), 1, mod, path)
end

function parse_source!(md::ModDict, src::AbstractString, file::Symbol, pos::Integer, mod::Module, path)
    local ex
    while pos < endof(src)
        try
            ex, pos = parse(src, pos; greedy=true)
        catch err
            ex, posfail = parse(src, pos; greedy=true, raise=false)
            warn("omitting ", file, " due to parsing error near line ", countlines(src, posfail))
            showerror(STDERR, err)
            println(STDERR)
            return false
        end
        if isa(ex, Expr)
            ex = ex::Expr
            add_filename!(ex, file)  # fixes the backtraces
            parse_expr!(md, ex, file, mod, path)
        end
    end
    true
end

function parse_source!(md::ModDict, ex::Expr, file::Symbol, mod::Module, path)
    @assert ex.head == :block
    for a in ex.args
        if isa(a, Expr)
            parse_expr!(md, a::Expr, file, mod, path)
        end
    end
    md
end

function parse_expr!(md::ModDict, ex::Expr, file::Symbol, mod::Module, path)
    if ex.head == :block
        for a in ex.args
            parse_expr!(md, a, file, mod, path)
        end
        return md
    elseif ex.head == :line
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
        if path != nothing
            filename = ex.args[2]
            if isa(filename, AbstractString)
            elseif isa(filename, Symbol)
                if isdefined(mod, filename)
                    filename = getfield(mod, filename)
                    isa(filename, AbstractString) || warn(filename, " is not a string")
                else
                    warn("unable to resolve filename ", filename)
                end
            elseif isa(filename, Expr)
                try
                    filename = eval(mod, macroreplace(filename, file))
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
        push!(md[mod], convert(RelocatableExpr, ex))
    end
    md
end

function parse_module!(md::ModDict, ex::Expr, file::Symbol, mod::Module, path)
    newmod = getfield(mod, _module_name(ex))
    md[newmod] = Set{RelocatableExpr}()
    parse_source!(md, ex.args[3], file, newmod, path)
    newmod
end

function watch_package(modsym::Symbol)
    files = parse_pkg_files(modsym)
    for file in files
        @schedule revise_file_queued(file)
    end
    return nothing
end

function revise_file_queued(file)
    if !isfile(file)
        sleep(0.1)   # in case git has done a delete/replace cycle
        if !isfile(file)
            warn(file, " is not an existing file, Revise is not watching")
            return nothing
        end
    end
    watch_file(file)  # will block here until the file changes
    push!(revision_queue, file)
    @schedule revise_file_queued(file)
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
    Revise.track(mod::Module, file::AbstractString)
    Revise.track(file::AbstractString)

Watch `file` for updates and [`revise`](@ref) loaded code with any
changes. If `mod` is omitted it defaults to `Main`.
"""
function track(mod::Module, file::AbstractString)
    isfile(file) || error(file, " is not a file")
    empty!(new_files)
    parse_source(file, mod, dirname(file))
    for fl in new_files
        @schedule revise_file_queued(fl)
    end
    nothing
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
        empty!(new_files)
        mainfile = joinpath(dirname(dirname(JULIA_HOME)), "base", "sysimg.jl")
        parse_source(mainfile, Main, dirname(mainfile))
        for file in new_files
            @schedule revise_file_queued(file)
        end
    else
        error("no Revise.track recipe for module ", mod)
    end
    nothing
end

## Utilities

_module_name(ex::Expr) = ex.args[2]

function add_filename!(ex::Expr, file::Symbol)
    if ex.head == :line
        ex.args[2] = file
    else
        for (i, a) in enumerate(ex.args)
            if isa(a, Expr)
                add_filename!(a::Expr, file)
            elseif isa(a, LineNumberNode)
                ex.args[i] = add_filename(a::LineNumberNode, file)
            end
        end
    end
    ex
end
if VERSION < v"0.7.0-DEV.328"
    add_filename(lnn::LineNumberNode, file::Symbol) = lnn
else
    add_filename(lnn::LineNumberNode, file::Symbol) = LineNumberNode(lnn.line, file)
end

function countlines(str::AbstractString, pos::Integer, eol='\n')
    n = 0
    for (i, c) in enumerate(str)
        i > pos && break
        n += c == eol
    end
    n
end

function macroreplace(ex::Expr, filename)
    for i = 1:length(ex.args)
        ex.args[i] = macroreplace(ex.args[i], filename)
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
macroreplace(s, filename) = s

const nargs_docexpr = VERSION < v"0.7.0-DEV.328" ? 3 : 4
isdocexpr(ex) = ex.head == :macrocall && ex.args[1] == GlobalRef(Core, Symbol("@doc")) &&
           length(ex.args) >= nargs_docexpr

function steal_repl_backend(backend = Base.active_repl_backend)
    # terminate the current backend
    put!(backend.repl_channel, (nothing, -1))
    yield()
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
    push!(Base.package_callbacks, watch_package)
    mode = get(ENV, "JULIA_REVISE", "auto")
    if mode == "auto" && isdefined(Base, :active_repl_backend)
        steal_repl_backend()
    end
end

end # module
