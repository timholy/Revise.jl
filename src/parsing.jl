"""
    md = parse_source(file::AbstractString, mod::Module)

Parse the source `file`, returning a `ModuleDict` `md` containing the
set of RelocatableExprs for each module used to evaluate code in `file`.
`mod` is the "parent" module for the file; if `file` defines more module(s)
then these will all have separate entries in `md`.

If parsing `file` fails, `nothing` is returned.
"""
function parse_source(file::AbstractString, mod::Module)
    # Create a blank ModDict to store the expressions. Parsing will "fill" this.
    md = ModDict(mod=>OrderedSet{RelocatableExpr}())
    parse_source!(md, file, mod) || return nothing
    fm = FileModules(mod, md)
    String(file) => fm
end

"""
    success = parse_source!(md::ModDict, file, mod::Module)

Top-level parsing of `file` as included into module
`mod`. Successfully-parsed expressions will be added to `md`. Returns
`true` if parsing finished successfully.

See also [`parse_source`](@ref).
"""
function parse_source!(md::ModDict, file::AbstractString, mod::Module)
    if !isfile(file)
        warn("omitting ", file, " from revision tracking")
        return false
    end
    parse_source!(md, read(file, String), Symbol(file), 1, mod)
end

"""
    success = parse_source!(md::ModDict, src::AbstractString, file::Symbol, pos::Integer, mod::Module)

Parse a string `src` obtained by reading `file` as a single
string. `pos` is the 1-based byte offset from which to begin parsing `src`.

See also [`parse_source`](@ref).
"""
function parse_source!(md::ModDict, src::AbstractString, file::Symbol, pos::Integer, mod::Module)
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
            parse_expr!(md, ex, file, mod)
        end
        # Update the number of lines
        line_offset += count(c->c=='\n', SubString(src, oldpos, pos-1))
    end
    true
end

"""
    success = parse_source!(md::ModDict, ex::Expr, file, mod::Module)

For a `file` that defines a sub-module, parse the body `ex` of the
sub-module.  `mod` will be the module into which this sub-module is
evaluated (i.e., included). Successfully-parsed expressions will be
added to `md`. Returns `true` if parsing finished successfully.

See also [`parse_source`](@ref).
"""
function parse_source!(md::ModDict, ex::Expr, file::Symbol, mod::Module)
    @assert ex.head == :block
    for a in ex.args
        if isa(a, Expr)
            parse_expr!(md, a::Expr, file, mod)
        end
    end
    md
end

"""
    parse_expr!(md::ModDict, ex::Expr, file::Symbol, mod::Module)

Recursively parse the expressions in `ex`, iterating over blocks and
sub-module definitions. Successfully parsed
expressions are added to `md` with key `mod`, and any sub-modules will
be stored in `md` using appropriate new keys. This accomplishes two main
tasks:

* add parsed expressions to the source-code cache (so that later we can detect changes)
* determine the module into which each parsed expression is `eval`uated into
"""
function parse_expr!(md::ModDict, ex::Expr, file::Symbol, mod::Module)
    if ex.head == :block
        for a in ex.args
            parse_expr!(md, a, file, mod)
        end
        return md
    end
    macroreplace!(ex, String(file))
    if ex.head == :line
        return md
    elseif ex.head == :module
        parse_module!(md, ex, file, mod)
    elseif isdocexpr(ex) && isa(ex.args[nargs_docexpr], Expr) && ex.args[nargs_docexpr].head == :module
        # Module with a docstring (issue #8)
        # Split into two expressions, a module definition followed by
        # `"docstring" newmodule`
        newmod = parse_module!(md, ex.args[nargs_docexpr], file, mod)
        ex.args[nargs_docexpr] = Symbol(newmod)
        push!(md[mod], convert(RelocatableExpr, ex))
    elseif ex.head == :call && ex.args[1] == :include
        # skip include statements
    else
        # Any expression that *doesn't* define line numbers, new
        # modules, or include new files must be "real code." Add it to
        # the cache.
        push!(md[mod], convert(RelocatableExpr, ex))
    end
    md
end

const nargs_docexpr = VERSION < v"0.7.0-DEV.328" ? 3 : 4
isdocexpr(ex) = ex.head == :macrocall && ex.args[1] == GlobalRef(Core, Symbol("@doc")) &&
           length(ex.args) >= nargs_docexpr


"""
    newmod = parse_module!(md::ModDict, ex::Expr, file, mod::Module)

Parse an expression `ex` that defines a new module `newmod`. This
module is "parented" by `mod`. Source-code expressions are added to
`md` under the appropriate module name.
"""
function parse_module!(md::ModDict, ex::Expr, file::Symbol, mod::Module)
    newname = _module_name(ex)
    if mod != Base.__toplevel__ && !isdefined(mod, newname)
        eval(mod, ex) # support creating new submodules
    end
    newmod = mod == Base.__toplevel__ ? Base.root_module(newname) : getfield(mod, Symbol(newname))
    md[newmod] = OrderedSet{RelocatableExpr}()
    parse_source!(md, ex.args[3], file, newmod)  # recurse into the body of the module
    newmod
end

_module_name(ex::Expr) = ex.args[2]
