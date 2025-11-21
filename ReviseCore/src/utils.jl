relpath_safe(path::AbstractString, startpath::AbstractString) = isempty(startpath) ? path : relpath(path, startpath)

function Base.relpath(filename::AbstractString, pkgdata::PkgData)
    if isabspath(filename)
        # `Base.locate_package`, which is how `pkgdata` gets initialized, might strip pieces of the path.
        # For example, on Travis macOS the paths returned by `abspath`
        # can be preceded by "/private" which is not present in the value returned by `Base.locate_package`.
        idx = findfirst(basedir(pkgdata), filename)
        if idx !== nothing
            idx = first(idx)
            if idx > 1
                filename = filename[idx:end]
            end
            filename = relpath_safe(filename, basedir(pkgdata))
        end
    elseif startswith(filename, "compiler")
        # Core.Compiler's pkgid includes "compiler/" in the path
        filename = relpath(filename, "compiler")
    end
    return filename
end

function file_exists(filename::AbstractString)
    filename = normpath(filename)
    isfile(filename) && return true
    alt = get(cache_file_key, filename, nothing)
    alt === nothing && return false
    return isfile(alt)
end

function firstline(ex::Expr)
    for a in ex.args
        isa(a, LineNumberNode) && return a
        if isa(a, Expr)
            line = firstline(a)
            isa(line, LineNumberNode) && return line
        end
    end
    return nothing
end
firstline(rex::RelocatableExpr) = firstline(rex.ex)

location_string((file, line)::Tuple{AbstractString, Any},) = abspath(file)*':'*string(line)
location_string((file, line)::Tuple{Symbol, Any},) = location_string((string(file), line))
location_string(::Nothing) = "unknown location"

# Path correction for Julia Base/stdlib files
function fixpath(filename::AbstractString; badpath=basebuilddir, goodpath=juliadir)
    startswith(filename, badpath) || return normpath(filename)
    relfilename = relpath(filename, badpath)
    relfilename0 = relfilename
    for strippath in (#joinpath("usr", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)"),
                      joinpath("usr", "share", "julia"),)
        if startswith(relfilename, strippath)
            relfilename = relpath(relfilename, strippath)
            if occursin("stdlib", relfilename0) && !occursin("stdlib", relfilename)
                relfilename = joinpath("stdlib", relfilename)
            end
        end
    end
    ffilename = normpath(joinpath(goodpath, relfilename))
    if (isfile(filename) & !isfile(ffilename))
        ffilename = normpath(filename)
    end
    return ffilename
end
_fixpath(lnn; kwargs...) = LineNumberNode(lnn.line, Symbol(fixpath(String(lnn.file); kwargs...)))
fixpath(lnn::LineNumberNode; kwargs...) = _fixpath(lnn; kwargs...)
fixpath(lnn::Core.LineInfoNode; kwargs...) = _fixpath(lnn; kwargs...)

function linediff(la::LineNumberNode, lb::LineNumberNode)
    (isa(la.file, Symbol) && isa(lb.file, Symbol) && (la.file::Symbol === lb.file::Symbol)) || return typemax(Int)
    return abs(la.line - lb.line)
end

# Return the only non-trivial expression in ex, or ex itself
function unwrap(ex::Expr)
    if ex.head === :block || ex.head === :toplevel
        for (i, a) in enumerate(ex.args)
            if isa(a, Expr)
                for j = i+1:length(ex.args)
                    istrivial(ex.args[j]) || return ex
                end
                return unwrap(a)
            elseif !istrivial(a)
                return ex
            end
        end
        return nothing
    end
    return ex
end
unwrap(rex::RelocatableExpr) = RelocatableExpr(unwrap(rex.ex))

istrivial(@nospecialize a) = a === nothing || isa(a, LineNumberNode)

function unwrap_where(ex::Expr)
    while isexpr(ex, :where)
        ex = ex.args[1]
    end
    return ex::Expr
end

function pushex!(exsigs::ExprsSigs, ex::Expr)
    uex = unwrap(ex)
    if is_doc_expr(uex)
        body = uex.args[4]
        # Don't trigger for exprs where the documented expression is just a signature
        # (e.g. `"docstr" f(x::Int)`, `"docstr" f(x::T) where T` etc.)
        if isa(body, Expr) && unwrap_where(body).head !== :call
            exsigs[RelocatableExpr(body)] = nothing
        end
        if length(uex.args) < 5
            push!(uex.args, false)
        else
            uex.args[5] = false
        end
    end
    exsigs[RelocatableExpr(ex)] = nothing
    return exsigs
end

"""
    success = throwto_repl(e::Exception)

Try throwing `e` from the REPL's backend task. Returns `true` if the necessary conditions
were met and the throw can be expected to succeed. The throw is generated from another
task, so a `yield` will need to occur before it happens.
"""
function throwto_repl(e::Exception)
    if isdefined(Base, :active_repl_backend) &&
            !isnothing(Base.active_repl_backend) &&
            Base.active_repl_backend.backend_task.state === :runnable &&
            isempty(Base.Workqueue) &&
            Base.active_repl_backend.in_eval
        @async Base.throwto(Base.active_repl_backend.backend_task, e)
        return true
    end
    return false
end

function printf_maxsize(f::Function, io::IO, args...; maxchars::Integer=500, maxlines::Integer=20)
    # This is dumb but certain to work
    iotmp = IOBuffer()
    for a in args
        print(iotmp, a)
    end
    print(iotmp, '\n')
    seek(iotmp, 0)
    str = read(iotmp, String)
    if length(str) > maxchars
        str = first(str, (maxchars+1)÷2) * "…" * last(str, maxchars - (maxchars+1)÷2)
    end
    lines = split(str, '\n')
    if length(lines) <= maxlines
        for line in lines
            f(io, line)
        end
        return
    end
    half = (maxlines+1) ÷ 2
    for i = 1:half
        f(io, lines[i])
    end
    maxlines > 1 && f(io, '⋮')
    for i = length(lines) - (maxlines-half) + 1:length(lines)
        f(io, lines[i])
    end
end
println_maxsize(args...; kwargs...) = println_maxsize(stdout, args...; kwargs...)
println_maxsize(io::IO, args...; kwargs...) = printf_maxsize(println, io, args...; kwargs...)

"""
    trim_toplevel!(bt)

Truncate a list of instruction pointers, as obtained from `backtrace()` or `catch_backtrace()`,
at the first "top-level" call (e.g., as executed from the REPL prompt) or the
first entry corresponding to a method in Revise or its dependencies.

This is used to make stacktraces obtained with Revise more similar to those obtained
without Revise, while retaining one entry to reveal Revise's involvement.
"""
function trim_toplevel!(bt, Revise::Module)
    # return bt       # uncomment this line if you're debugging Revise itself
    n = itoplevel = length(bt)
    for (i, t) in enumerate(bt)
        sfs = StackTraces.lookup(t)
        for sf in sfs
            if sf.func === Symbol("top-level scope") || (let mi = sf.linfo
                mi isa Core.MethodInstance && (let def = mi.def
                    def isa Method && def.module ∈ (JuliaInterpreter, LoweredCodeUtils, ReviseCore, Revise)
                end) end)
                itoplevel = i
                break
            end
        end
        itoplevel < n && break
    end
    deleteat!(bt, itoplevel+1:length(bt))
    return bt
end
