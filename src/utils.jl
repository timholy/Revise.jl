relpath_safe(path, startpath) = isempty(startpath) ? path : relpath(path, startpath)

function Base.relpath(filename, pkgdata::PkgData)
    if isabspath(filename) && startswith(filename, basedir(pkgdata))
        filename = relpath_safe(filename, basedir(pkgdata))
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

# Return the only non-trivial expression in ex, or ex itself
function unwrap(ex::Expr)
    if ex.head == :block
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
unwrap(rex::RelocatableExpr) = unwrap(rex.ex)

istrivial(a) = a === nothing || isa(a, LineNumberNode)

## WatchList utilities
function systime()
    # It's important to use the same clock used by the filesystem
    tv = Libc.TimeVal()
    tv.sec + tv.usec/10^6
end
function updatetime!(wl::WatchList)
    wl.timestamp = systime()
end
Base.push!(wl::WatchList, filename) = push!(wl.trackedfiles, filename)
WatchList() = WatchList(systime(), Set{String}())
Base.in(file, wl::WatchList) = in(file, wl.trackedfiles)

@static if Sys.isapple()
     # HFS+ rounds time to seconds, see #22
     # https://developer.apple.com/library/archive/technotes/tn/tn1150.html#HFSPlusDates
     newer(mtime, timestamp) = ceil(mtime) >= floor(timestamp)
 else
     newer(mtime, timestamp) = mtime >= timestamp
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
println_maxsize(io::IO, args...; kwargs...) = printf_maxsize(println, stdout, args...; kwargs...)
