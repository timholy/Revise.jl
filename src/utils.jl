relpath_safe(path, startpath) = isempty(startpath) ? path : relpath(path, startpath)

function Base.relpath(filename, pkgdata::PkgData)
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

function iswritable(file::AbstractString)  # note this trashes the Base definition, but we don't need it
    return uperm(stat(file)) & 0x02 != 0x00
end

function unique_dirs(iter)
    udirs = Set{String}()
    for file in iter
        dir, basename = splitdir(file)
        push!(udirs, dir)
    end
    return udirs
end

function file_exists(filename)
    filename = normpath(filename)
    isfile(filename) && return true
    alt = get(cache_file_key, filename, nothing)
    alt === nothing && return false
    return isfile(alt)
end

function use_compiled_modules()
    return Base.JLOptions().use_compiled_modules != 0
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

newloc(methloc::LineNumberNode, ln, lno) = fixpath(ln)

location_string(file::AbstractString, line) = abspath(file)*':'*string(line)
location_string(file::Symbol, line) = location_string(string(file), line)

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

istrivial(a) = a === nothing || isa(a, LineNumberNode)

function unwrap_where(ex::Expr)
    while isexpr(ex, :where)
        ex = ex.args[1]
    end
    return ex
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

## WatchList utilities
function updatetime!(wl::WatchList)
    wl.timestamp = time()
end
Base.push!(wl::WatchList, filenameid::Pair{<:AbstractString,PkgId}) =
    push!(wl.trackedfiles, filenameid)
Base.push!(wl::WatchList, filenameid::Pair{<:AbstractString,PkgFiles}) =
    push!(wl, filenameid.first=>filenameid.second.id)
Base.push!(wl::WatchList, filenameid::Pair{<:AbstractString,PkgData}) =
    push!(wl, filenameid.first=>filenameid.second.info)
WatchList() = WatchList(time(), Dict{String,PkgId}())
Base.in(file, wl::WatchList) = haskey(wl.trackedfiles, file)

@static if Sys.isapple()
    # HFS+ rounds time to seconds, see #22
    # https://developer.apple.com/library/archive/technotes/tn/tn1150.html#HFSPlusDates
    newer(mtime, timestamp) = ceil(mtime) >= floor(timestamp)
else
    newer(mtime, timestamp) = mtime >= timestamp
end

"""
    success = throwto_repl(e::Exception)

Try throwing `e` from the REPL's backend task. Returns `true` if the necessary conditions
were met and the throw can be expected to succeed. The throw is generated from another
task, so a `yield` will need to occur before it happens.
"""
function throwto_repl(e::Exception)
    if isdefined(Base, :active_repl_backend) &&
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
    maxlines > 1 && f(io, ⋮)
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
function trim_toplevel!(bt)
    # return bt       # uncomment this line if you're debugging Revise itself
    n = itoplevel = length(bt)
    for (i, t) in enumerate(bt)
        sfs = StackTraces.lookup(t)
        for sf in sfs
            if sf.func === Symbol("top-level scope") || (isa(sf.linfo, Core.MethodInstance) && isa(sf.linfo.def, Method) && ((sf.linfo::Core.MethodInstance).def::Method).module ∈ (JuliaInterpreter, LoweredCodeUtils, Revise))
                itoplevel = i
                break
            end
        end
        itoplevel < n && break
    end
    deleteat!(bt, itoplevel+1:length(bt))
    return bt
end
