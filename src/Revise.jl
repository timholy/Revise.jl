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

Base.convert(::Type{RelocatableExpr}, ex::Expr) = relocatable!(ex)

# RelocatableExpr <---> Expr. Mutating in-place, so only for internal use.
function relocatable!(ex::Expr)
    rex = RelocatableExpr(ex.head, relocatable!(ex.args))
    rex.typ = ex.typ
    rex
end
function unrelocatable!(rex::RelocatableExpr)
    ex = Expr(rex.head, unrelocatable!(rex.args)...)
    ex.typ = rex.typ
    ex
end

# A copying transformation. Because the above mutate in-place, to
# eval RelocatableExprs without changing their underlying
# representation, we have to make a copy.
# We only call this when we've detected a new or changed expression.
function unrelocatable(rex::RelocatableExpr)
    ex = Expr(rex.head, unrelocatable!(deepcopy(rex.args))...)
    ex.typ = rex.typ
    ex
end

function relocatable!(args::Vector{Any})
    for (i, a) in enumerate(args)
        if isa(a, Expr)
            args[i] = relocatable!(a)
        # elseif isa(a, QuoteNode)
        #     dump(a)  # debugging: do we need to worry about QuoteNodes?
        end
    end
    args
end
function unrelocatable!(args::Vector{Any})
    for (i, a) in enumerate(args)
        if isa(a, RelocatableExpr)
            args[i] = unrelocatable!(a)
        end
    end
    args
end

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
        for ex in exprs
            try
                eval(mod, unrelocatable(ex))
            catch err
                warn("failure to evaluate changes in ", mod)
                println(STDERR, unrelocatable(ex))
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
        file2modules[file] = fm
        push!(new_files, file)
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
            add_filename!(ex, file)  # fixes the backtraces
            parse_expr!(md, ex::Expr, file, mod, path)
        else
            if ex != nothing
                println(ex) # debugging
            end
        end
    end
    true
end

function parse_source!(md::ModDict, ex::Expr, file::Symbol, mod::Module, path)
    @assert ex.head == :block
    for a in ex.args
        if isa(a, Expr)
            parse_expr!(md, a::Expr, file, mod, path)
        else
            if a != nothing
                println(a)  # debugging
            end
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
        newmod = getfield(mod, _module_name(ex))
        md[newmod] = Set{RelocatableExpr}()
        parse_source!(md, ex.args[3], file, newmod, path)
    elseif ex.head == :call && ex.args[1] == :include && path != nothing
        filename = ex.args[2]
        if isa(filename, String)
            dir, fn = splitdir(filename)
            parse_source(joinpath(path, filename), mod, joinpath(path, dir))
        elseif isa(filename, Expr)
            try
                filename = eval(mod, macroreplace(filename, file))
            catch
                warn("could not parse `include` expression ", filename)
                return md
            end
            if startswith(filename, ".")
                filename = joinpath(path, filename)
            end
            parse_source(filename, mod, dirname(filename))
        else
            error(filename, " not recognized")
        end
    else
        push!(md[mod], convert(RelocatableExpr, ex))
    end
    md
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
    event = watch_file(file)
    if event.changed
        push!(revision_queue, file)
    else
        warn(file, " changed in ways that Revise cannot track. You will likely have to restart your Julia session.")
        return nothing
    end
    @schedule revise_file_queued(file)
end

function revise_file_now(file)
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

function revise()
    for file in revision_queue
        revise_file_now(file)
    end
    empty!(revision_queue)
    nothing
end

## Utilities

_module_name(ex::Expr) = ex.args[2]

function add_filename!(ex::Expr, file::Symbol)
    if ex.head == :line
        ex.args[2] = file
    else
        for a in ex.args
            if isa(a, Expr)
                add_filename!(a::Expr, file)
            end
        end
    end
    ex
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
