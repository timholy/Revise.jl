module ReviseCore

Base.Experimental.@optlevel 1

# Core dependencies (copied from Revise.jl main module)
using OrderedCollections, CodeTracking, JuliaInterpreter, LoweredCodeUtils

using CodeTracking: PkgFiles, basedir, srcfiles, basepath, MethodInfoKey
using JuliaInterpreter: Compiled, Frame, Interpreter, LineTypes, RecursiveInterpreter
using JuliaInterpreter: codelocs, get_return, is_doc_expr, isassign,
                        is_quotenode_egal, linetable, lookup, moduleof,
                        pc_expr, step_expr!
using LoweredCodeUtils: next_or_nothing!, callee_matches

using Base.Meta: isexpr
using Base: PkgId
using Core: MethodTable, CodeInfo

## BEGIN Abstract Distributed API

# Abstract type to represent a single worker
abstract type AbstractWorker end

# Wrapper struct to indicate a worker belonging to the Distributed stdlib. Other
# libraries should make their own type that subtypes AbstractWorker for Revise
# to dispatch on.
struct DistributedWorker <: AbstractWorker
    id::Int
end

# This is a list of functions that will retrieve a list of workers
const workers_functions = Base.Callable[]

# A distributed worker library wanting to use Revise should register their
# workers() function with this.
function register_workers_function(f::Base.Callable)
    push!(workers_functions, f)
    nothing
end

# The library should implement this method such that it behaves like
# Distributed.remotecall().
function remotecall_impl end

# The library should implement two methods for this function:
# - is_master_worker(::typeof(my_workers_function)): check if the current
#   process is the master.
# - is_master_worker(w::MyWorkerType): check if `w` is the master.
function is_master_worker end

## END abstract Distributed API

include("logging.jl")
include("relocatable_exprs.jl")
include("types.jl")
include("utils.jl")
include("parsing.jl")
include("lowered.jl")

const empty_exs_sigs = ExprsSigs()

function delete_missing!(exs_sigs_old::ExprsSigs, exs_sigs_new::ExprsSigs)
    with_logger(_debug_logger) do
        for (ex, siginfos) in exs_sigs_old
            haskey(exs_sigs_new, ex) && continue
            # ex was deleted
            siginfos === nothing && continue
            for siginfo in siginfos
                mt, sig = siginfo
                ret = Base._methods_by_ftype(sig, mt, -1, Base.get_world_counter())
                success = false
                if !isempty(ret)
                    m = ret[end].method
                    methsig = m.sig
                    if sig <: methsig && methsig <: sig
                        locdefs = get(CodeTracking.method_info, MethodInfoKey(siginfo), nothing)
                        if isa(locdefs, Vector{Tuple{LineNumberNode,Expr}})
                            if length(locdefs) > 1
                                line = firstline(ex)
                                ld = map(pr->linediff(line, pr[1]), locdefs)
                                idx = argmin(ld)
                                @assert ld[idx] < typemax(eltype(ld))
                                deleteat!(locdefs, idx)
                                continue
                            else
                                @assert length(locdefs) == 1
                            end
                        end
                        # Delete the method
                        for get_workers in workers_functions
                            for p in @invokelatest get_workers()
                                try
                                    @invokelatest remotecall_impl(Core.eval, p, Main, :(delete_method_by_sig($mt, $sig)))
                                catch
                                end
                            end
                        end
                        Base.delete_method(m)
                        delete!(CodeTracking.method_info, MethodInfoKey(siginfo))
                        if haskey(JuliaInterpreter.framedict, m)
                            delete!(JuliaInterpreter.framedict, m)
                        end
                        if isdefined(m, :generator)
                            empty!(JuliaInterpreter.genframedict)
                        end
                        success = true
                    end
                end
            end
        end
    end
    return exs_sigs_old
end

function delete_missing!(mod_exs_sigs_old::ModuleExprsSigs, mod_exs_sigs_new::ModuleExprsSigs)
    for (mod, exs_sigs_old) in mod_exs_sigs_old
        exs_sigs_new = get(mod_exs_sigs_new, mod, empty_exs_sigs)
        delete_missing!(exs_sigs_old, exs_sigs_new)
    end
    return mod_exs_sigs_old
end

# Core evaluation functionality
function eval_rex(rex_new::RelocatableExpr, exs_sigs_old::ExprsSigs, mod::Module; mode::Symbol=:eval)
    return with_logger(_debug_logger) do
        siginfos, includes = nothing, nothing
        rex_old = getkey(exs_sigs_old, rex_new, nothing)
        if rex_old === nothing
            ex = rex_new.ex
            siginfos, includes, thunk = eval_with_signatures(mod, ex; mode)
            if !isexpr(thunk, :thunk)
                thunk = ex
            end
            for get_workers in workers_functions
                if @invokelatest is_master_worker(get_workers)
                    for p in @invokelatest get_workers()
                        @invokelatest(is_master_worker(p)) && continue
                        try
                            @invokelatest remotecall_impl(Core.eval, p, mod, thunk)
                        catch
                        end
                    end
                end
            end
        else
            siginfos = exs_sigs_old[rex_old]
            ln, lno = firstline(unwrap(rex_new)), firstline(unwrap(rex_old))
            if siginfos !== nothing && !isempty(siginfos) && ln != lno
                ln, lno = ln::LineNumberNode, lno::LineNumberNode
                for siginfo in siginfos
                    locdefs = CodeTracking.method_info[MethodInfoKey(siginfo)]::AbstractVector
                    ld = let lno=lno
                        map(pr->linediff(lno, pr[1]), locdefs)
                    end
                    idx = argmin(ld)
                    if ld[idx] === typemax(eltype(ld))
                        idx = length(locdefs)
                    end
                    _, methdef = locdefs[idx]
                    locdefs[idx] = (fixpath(ln), methdef)
                end
            end
        end
        return siginfos, includes
    end
end

function eval_new!(exs_sigs_new::ExprsSigs, exs_sigs_old::ExprsSigs, mod::Module; mode::Symbol=:eval)
    includes = Vector{Pair{Module,String}}()
    for rex in keys(exs_sigs_new)
        siginfos, _includes = eval_rex(rex, exs_sigs_old, mod; mode)
        if siginfos !== nothing
            exs_sigs_new[rex] = siginfos
        end
        if _includes !== nothing
            append!(includes, _includes)
        end
    end
    return exs_sigs_new, includes
end

function eval_new!(mod_exs_sigs_new::ModuleExprsSigs, mod_exs_sigs_old::ModuleExprsSigs; mode::Symbol=:eval)
    includes = Vector{Pair{Module,String}}()
    for (mod, exs_sigs_new) in mod_exs_sigs_new
        if isdefined(mod, :__revise_mode__)
            mode = getfield(mod, :__revise_mode__)::Symbol
        end
        exs_sigs_old = get(mod_exs_sigs_old, mod, empty_exs_sigs)
        _, _includes = eval_new!(exs_sigs_new, exs_sigs_old, mod; mode)
        append!(includes, _includes)
    end
    return mod_exs_sigs_new, includes
end

# CodeTracking integration
struct CodeTrackingMethodInfo
    exprstack::Vector{Expr}
    allsigs::Vector{SigInfo}
    includes::Vector{Pair{Module,String}}
end
CodeTrackingMethodInfo(ex::Expr) = CodeTrackingMethodInfo([ex], SigInfo[], Pair{Module,String}[])

function add_signature!(methodinfo::CodeTrackingMethodInfo, mt_sig::MethodInfoKey, ln::LineNumberNode)
    locdefs = CodeTracking.invoked_get!(Vector{Tuple{LineNumberNode,Expr}}, CodeTracking.method_info, mt_sig)
    newdef = unwrap(methodinfo.exprstack[end])
    if newdef !== nothing
        if !any(locdef->locdef[1] == ln && isequal(RelocatableExpr(locdef[2]), RelocatableExpr(newdef)), locdefs)
            push!(locdefs, (fixpath(ln), newdef))
        end
        push!(methodinfo.allsigs, SigInfo(mt_sig))
    end
    return methodinfo
end
push_expr!(methodinfo::CodeTrackingMethodInfo, ex::Expr) = (push!(methodinfo.exprstack, ex); methodinfo)
pop_expr!(methodinfo::CodeTrackingMethodInfo) = (pop!(methodinfo.exprstack); methodinfo)
function add_includes!(methodinfo::CodeTrackingMethodInfo, mod::Module, filename)
    push!(methodinfo.includes, mod=>filename)
    return methodinfo
end

function eval_with_signatures(mod::Module, ex::Expr; mode::Symbol=:eval, kwargs...)
    methodinfo = CodeTrackingMethodInfo(ex)
    _, thk = methods_by_execution!(methodinfo, mod, ex; mode, kwargs...)
    return methodinfo.allsigs, methodinfo.includes, thk
end

function instantiate_sigs!(mod_exs_sigs::ModuleExprsSigs; mode::Symbol=:sigs, kwargs...)
    for (mod, exsigs) in mod_exs_sigs
        for rex in keys(exsigs)
            is_doc_expr(rex.ex) && continue
            exsigs[rex], _ = eval_with_signatures(mod, rex.ex; mode, kwargs...)
        end
    end
    return mod_exs_sigs
end

# Julia directory and path functions
"""
    expected_juliadir()

This is the path where we ordinarily expect to find a copy of the julia source files,
as well as the source cache. For `juliadir` we additionally search some fallback
locations to handle various corrupt and incomplete installations.
"""
expected_juliadir() = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")

"""
    ReviseCore.basesrccache

Full path to the running Julia's cache of source code defining `Base`.
"""
const basesrccache = normpath(joinpath(expected_juliadir(), "base.cache"))

"""
    ReviseCore.basebuilddir

Julia's top-level directory when Julia was built, as recorded by the entries in
`Base._included_files`.
"""
const basebuilddir = begin
    sysimg = filter(x->endswith(x[2], "sysimg.jl"), Base._included_files)[1][2]
    dirname(dirname(sysimg))
end

function fallback_juliadir(candidate = expected_juliadir())
    if !isdir(joinpath(candidate, "base"))
        while true
            trydir = joinpath(candidate, "base")
            isdir(trydir) && break
            trydir = joinpath(candidate, "share", "julia", "base")
            if isdir(trydir)
                candidate = joinpath(candidate, "share", "julia")
                break
            end
            next_candidate = dirname(candidate)
            next_candidate == candidate && break
            candidate = next_candidate
        end
    end
    normpath(candidate)
end

function find_juliadir()
    candidate = expected_juliadir()
    isdir(candidate) && return normpath(candidate)
    # Couldn't find julia dir in the expected place.
    # Let's look in the source build also - it's possible that the Makefile didn't
    # set up the symlinks.
    # N.B.: We need to make sure here that the julia we're running is actually
    # the one being built. It's very common on buildbots that the original build
    # dir exists, but is a different julia that is currently being built.
    if Sys.BINDIR == joinpath(basebuilddir, "usr", "bin")
        return normpath(basebuilddir)
    end

    @warn "Unable to find julia source directory in the expected places.\n
           Looking in fallback locations. If this happens on a non-development build, please file an issue."
    return fallback_juliadir(candidate)
end

"""
    ReviseCore.juliadir

Constant specifying full path to julia top-level source directory.
This should be reliable even for local builds, cross-builds, and binary installs.
"""
global juliadir::String = find_juliadir()

const cache_file_key = Dict{String,String}() # corrected=>uncorrected filenames
const src_file_key   = Dict{String,String}() # uncorrected=>corrected filenames

# Cache parsing functions
function read_from_cache(pkgdata::PkgData, file::AbstractString)
    fi = fileinfo(pkgdata, file)
    filep = joinpath(basedir(pkgdata), file)
    if fi.cachefile == basesrccache
        # Get the original path
        filec = get(cache_file_key, filep, filep)
        return open(basesrccache) do io
            Base._read_dependency_src(io, filec)
        end
    end
    Base.read_dependency_src(fi.cachefile, filep)
end

function maybe_parse_from_cache!(pkgdata::PkgData, file::AbstractString)
    fi = fileinfo(pkgdata, file)
    if (isempty(fi.modexsigs) && !fi.parsed[]) && (!isempty(fi.cachefile) || !isempty(fi.cacheexprs))
        # Source was never parsed, get it from the precompile cache
        src = read_from_cache(pkgdata, file)
        filep = joinpath(basedir(pkgdata), file)
        filec = get(cache_file_key, filep, filep)
        topmod = first(keys(fi.modexsigs))
        ret = parse_source!(fi.modexsigs, src, filec, topmod)
        if ret === nothing
            @error "failed to parse cache file source text for $file"
        end
        if ret !== DoNotParse()
            add_modexs!(fi, fi.cacheexprs)
            empty!(fi.cacheexprs)
        end
        fi.parsed[] = true
    end
    return fi
end

# Because we delete first, we have to make sure we've parsed the file
function handle_deletions(deletion_callback, pkgdata::PkgData, file::AbstractString)
    fi = maybe_parse_from_cache!(pkgdata, file)
    maybe_extract_sigs!(fi)
    mod_exs_sigs_old = fi.modexsigs
    idx = fileindex(pkgdata, file)
    filep = pkgdata.info.files[idx]
    if isa(filep, AbstractString)
        if file ≠ "."
            filep = normpath(basedir(pkgdata), file)
        else
            filep = normpath(basedir(pkgdata))
        end
    end
    topmod = first(keys(mod_exs_sigs_old))
    fileok = file_exists(String(filep)::String)
    mod_exs_sigs_new = fileok ? parse_source(filep, topmod) : ModuleExprsSigs(topmod)
    if mod_exs_sigs_new !== nothing && mod_exs_sigs_new !== DoNotParse()
        delete_missing!(mod_exs_sigs_old, mod_exs_sigs_new)
    end
    if !fileok
        @warn("$filep no longer exists, deleted all methods")
        deleteat!(pkgdata.fileinfos, idx)
        deleteat!(pkgdata.info.files, idx)
        deletion_callback(idx)
    end
    return mod_exs_sigs_new, mod_exs_sigs_old
end
handle_deletions(args...) = handle_deletions(Returns(nothing), args...)

function add_modexs!(fi::FileInfo, modexs)
    for (mod, rex) in modexs
        exsigs = get(fi.modexsigs, mod, nothing)
        if exsigs === nothing
            fi.modexsigs[mod] = exsigs = ExprsSigs()
        end
        pushex!(exsigs, rex)
    end
    return fi
end

function maybe_extract_sigs!(fi::FileInfo)
    if !fi.extracted[]
        instantiate_sigs!(fi.modexsigs)
        fi.extracted[] = true
    end
    return fi
end
maybe_extract_sigs!(pkgdata::PkgData, file::AbstractString) = maybe_extract_sigs!(fileinfo(pkgdata, file))

end # module ReviseCore
