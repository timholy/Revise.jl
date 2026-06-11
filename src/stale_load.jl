# Load a package from a stale precompile cache and revise it up to date,
# skipping the re-precompilation that `using`/`import` would trigger (issue #738).

"""
    Revise.stale_load(pkg::Union{AbstractString,Symbol,Base.PkgId}; throw=false) → Module

Load `pkg` from its most recent loadable precompile cache—even if that cache is
*stale* (the package's source files have changed since the cache was built)—and
then revise the loaded code to match the current source. This skips the
re-precompilation that `using`/`import` triggers for an edited package, which
can be a substantial savings for packages that are expensive to compile.

`stale_load` must be called before `pkg` is loaded by any other means; a
subsequent `using`/`import` binds the already-loaded module:

```julia
using Revise
Revise.stale_load("MyBigPackage")
using MyBigPackage
```

The cache on disk is not modified: every `stale_load` of the same cache starts
from the same checkpoint and re-applies the (accumulating) source changes.
Precompile the package when convenient to establish a fresh checkpoint.

# Limitations

- Revision is subject to the usual restrictions; in particular, redefining a
  `struct` requires Julia 1.12+ with struct revision enabled (see the
  `revise_structs` preference). Errors during revision are logged and can be
  inspected with [`Revise.errors`](@ref); pass `throw=true` to raise them
  instead.
- On Julia 1.10, only `pkg` itself may be stale: dependencies whose sources
  have also been edited must be `stale_load`ed first (in dependency order) or
  freshly precompiled. On Julia 1.11+, edited dependencies are loaded from
  their own stale caches and revised automatically.
- A cache may be unloadable for reasons other than source edits (different
  Julia version or build flags, changed preferences, an unsatisfiable
  dependency). In that case `stale_load` throws, and the package must be
  loaded normally.
"""
function stale_load(id::PkgId; throw::Bool=false)
    if Base.JLOptions().use_compiled_modules == 0
        error("stale_load requires compiled modules; restart Julia without `--compiled-modules=no`")
    end
    if Base.root_module_exists(id)
        @warn "$(id.name) is already loaded; `stale_load` applies only to packages that have not yet been loaded"
        return Base.root_module(id)
    end
    newmods = load_from_serialized_no_stale(id)
    # Loading with the staleness check disabled skips both `register_root_module`
    # (so `using` would not find the module) and `run_package_callbacks` (so Revise
    # would not track it). Register every newly loaded module before running any
    # callback, so that callbacks observe a consistent set of root modules.
    @lock Base.require_lock begin
        for M in newmods
            key = PkgId(M)
            Base.root_module_exists(key) || Base.register_root_module(M)
        end
        for M in newmods
            key = PkgId(M)
            Base.insert_extension_triggers(key)
            Base.run_package_callbacks(key)
        end
    end
    # Queue each file whose on-disk source differs from the snapshot stored in the
    # cache; `revise` diffs against that snapshot (see `maybe_parse_from_cache!`).
    anychanged = false
    for M in newmods
        anychanged |= queue_changed_files!(PkgId(M))
    end
    anychanged && revise(; throw)
    return Base.root_module(id)
end

function stale_load(pkg::Union{AbstractString,Symbol}; kwargs...)
    id = Base.identify_package(String(pkg))
    id === nothing && error("could not identify a package named $pkg in the current environment")
    return stale_load(id; kwargs...)
end

@noinline function nocache_error(id::PkgId, @nospecialize(reason))
    msg = """
        no loadable precompile cache found for $(id.name). A cache can fail to load if it \
        was built by a different Julia version or with different options, if compile-time \
        preferences have changed, or if a dependency cannot be satisfied."""
    @static if VERSION < v"1.11"
        msg *= " On Julia 1.10, dependencies of the requested package must not be stale."
    end
    msg *= " Load the package normally to (re)build its cache."
    if reason !== nothing
        msg *= " Last failure: $reason"
    end
    error(msg)
end

@static if VERSION >= v"1.11"

# `_require_search_from_serialized` with `stalecheck=false` (the mode `require_stdlib`
# uses) picks the newest cachefile that passes all structural validation—header, flags,
# CPU target, dependency build_ids, CRCs, preferences—while skipping only the
# source-freshness checks. Stale dependencies load recursively the same way.
function load_from_serialized_no_stale(id::PkgId)
    @lock Base.require_lock begin
        before = IdSet{Module}()
        for M in Iterators.flatten(values(Base.loaded_precompiles))
            push!(before, M)
        end
        spec = isdefined(Base, :locate_package_load_spec) ?
            Base.locate_package_load_spec(id) : Base.locate_package(id)
        spec === nothing && error("cannot locate source for $(id.name); is it in the current environment?")
        sourcepath = spec isa String ? spec : spec.path
        Base.set_pkgorigin_version_path(id, sourcepath)
        loaded = Base.start_loading(id, UInt128(0), false)
        if loaded === nothing
            try
                loaded = Base._require_search_from_serialized(id, spec, UInt128(0), false)
            finally
                Base.end_loading(id, loaded)
            end
        end
        loaded isa Module || nocache_error(id, loaded)
        newmods = Module[M for M in Iterators.flatten(values(Base.loaded_precompiles)) if M ∉ before]
        # The target module may have been loaded earlier (e.g., by a failed prior call)
        # without being registered; make sure it gets registered and announced.
        if loaded ∉ newmods && !Base.root_module_exists(id)
            push!(newmods, loaded)
        end
        return newmods
    end
end

else # VERSION < v"1.11"

# 1.10 lacks the `stalecheck` keyword, but `_tryrequire_from_serialized(pkg, path,
# ocachepath)` loads a given cachefile while ignoring staleness—of the requested
# package only; its dependencies are loaded through the normal (stale-checked) path.
# It also registers every restored module and runs the callbacks for the
# dependencies, but not for `pkg` itself.
function load_from_serialized_no_stale(id::PkgId)
    @lock Base.require_lock begin
        sourcepath = Base.locate_package(id)
        sourcepath === nothing && error("cannot locate source for $(id.name); is it in the current environment?")
        Base.set_pkgorigin_version_path(id, sourcepath)
        local loaded = nothing
        local lastfail = nothing
        for path in Base.find_all_in_cache_path(id)  # sorted newest-first
            ocachepath = nothing
            ok = try
                clone_targets = Base.parse_cache_header(path)[7]
                if isempty(clone_targets)
                    true
                elseif Base.JLOptions().use_pkgimages == 0
                    false
                else
                    ocachepath = Base.ocachefile_from_cachefile(path)
                    isfile(ocachepath)
                end
            catch
                false
            end
            ok || continue
            ret = Base._tryrequire_from_serialized(id, path, ocachepath)
            if ret isa Module
                loaded = ret
                break
            end
            lastfail = ret
        end
        loaded isa Module || nocache_error(id, lastfail)
        return Module[loaded]
    end
end

end # @static if

function queue_changed_files!(id::PkgId)
    changed = false
    @lock revise_lock begin
        pkgdata = get(pkgdatas, id, nothing)
        if pkgdata === nothing
            # `watch_package` declines some packages (e.g., `Revise.dont_watch_pkgs`)
            # and warns on its own; nothing more to do here.
            return false
        end
        if isempty(srcfiles(pkgdata))
            error("Revise could not obtain the file list for $(id.name); it remains in the state of its precompile cache")
        end
        for file in srcfiles(pkgdata)
            fi = fileinfo(pkgdata, file)
            isempty(fi.cachefile) && continue  # no cache snapshot; the baseline is the on-disk source
            filep = joinpath(basedir(pkgdata), file)
            if !isfile(filep)
                @warn "$filep is recorded in the cache for $(id.name) but no longer exists; its definitions remain active"
                continue
            end
            cached = try
                read_from_cache(pkgdata, file)
            catch
                nothing  # queue it; revision will surface the problem
            end
            if cached === nothing || cached != read(filep, String)
                push!(revision_queue, (pkgdata, file))
                changed = true
            end
        end
    end
    return changed
end
