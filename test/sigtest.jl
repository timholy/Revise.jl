using Revise, Test, CodeTracking

function isdefinedmod(mod::Module)
    # Not all modules---e.g., LibGit2---are reachable without loading the stdlib
    names = fullname(mod)
    pmod = Main
    for n in names
        isdefined(pmod, n) || return false
        pmod = getfield(pmod, n)
    end
    return true
end
function reljpath(path)
    for subdir in ("base/", "stdlib/", "test/")
        s = split(path, subdir)
        if length(s) == 2
            return subdir * s[end]
        end
    end
    return path
end
function filepredicate(file)
    bfile = Base.find_source_file(file)
    bfile === nothing && return false  # when the file is "none"
    return reljpath(bfile) ∈ basefiles
end
function signature_diffs(mod::Module, signatures; filepredicate=nothing)
    extras = copy(signatures)
    modeval, modinclude = getfield(mod, :eval), getfield(mod, :include)
    failed = []
    nmethods = 0
    for fsym in names(mod; all=true)
        isdefined(mod, fsym) || continue
        f = getfield(mod, fsym)
        isa(f, Base.Callable) || continue
        (f === modeval || f === modinclude) && continue
        for m in methods(f)
            nmethods += 1
            if haskey(signatures, m.sig)
                delete!(extras, m.sig)
            else
                if filepredicate !== nothing
                    filepredicate(String(m.file)) || continue # find signatures only in selected files
                end
                push!(failed, m.sig)
            end
        end
    end
    return failed, extras, nmethods
end
function extracttype(T)
    p1 = T.parameters[1]
    isa(p1, Type) && return p1
    isa(p1, TypeVar) && return p1.ub
    error("unrecognized type ", T)
end
function in_module_or_core(T, mod::Module)
    if isa(T, TypeVar)
        return in_module_or_core(T.ub, mod)
    end
    if isa(T, UnionAll)
        T = Base.unwrap_unionall(T)
    end
    if isa(T, Union)
        in_module_or_core(T.a, mod) || return false
        return in_module_or_core(T.b, mod)
    end
    if T.name.name == :Type
        return in_module_or_core(extracttype(T), mod)
    end
    Tmod = T.name.module
    return Tmod === mod || Tmod === Core
end

module Lowering end

@testset ":lambda expressions" begin
    ex = quote
        mutable struct InnerC
            x::Int
            valid::Bool

            function InnerC(x; notvalid::Bool=false)
                return new(x, !notvalid)
            end
        end
    end
    sigs, _ = Revise.eval_with_signatures(Lowering, ex)
    @test length(sigs) >= 2
end

basefiles = Set{String}()
@time for (i, (mod, file)) in enumerate(Base._included_files)
    # (isdefinedmod(mod) && mod != Base.__toplevel__) || continue
    endswith(file, "FileWatching.jl") && continue
    endswith(file, "sysimg.jl") && continue
    file = Revise.fixpath(file)
    push!(basefiles, reljpath(file))
    mexs = Revise.parse_source(file, mod)
    Revise.instantiate_sigs!(mexs)
end
failed, extras, nmethods = signature_diffs(Base, CodeTracking.method_info; filepredicate = filepredicate)
# In some cases, the above doesn't really select the file-of-origin. For example, anything
# defined with an @enum gets attributed to Enum.jl rather than the file in which @enum is used.
realfailed = similar(failed, 0)
for sig in failed
    ft = Base.unwrap_unionall(sig).parameters[1]
    match(r"^getfield\(Base, Symbol\(\"##\d", string(ft)) === nothing || continue  # exclude anonymous functions
    all(T->in_module_or_core(T, Base), Base.unwrap_unionall(sig).parameters[2:end]) || continue
    push!(realfailed, sig)
end
@test length(realfailed) < 40  # big enough for some cushion in case new "difficult" methods get added
