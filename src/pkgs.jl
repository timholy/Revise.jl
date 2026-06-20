# This is primarily used to parse non-precompilable packages.
# These lack a cache header that lists the files that constitute the package;
# they also lack the source cache, and so have to parsed immediately or
# we won't be able to compute a diff when a file is modified (we don't have a record
# of what the source was before the modification).
#
# The main trick here is that since `using` is recursive, `included_files`
# might contain files associated with many different packages. We have to figure
# out which correspond to a particular module `mod`, which we do by:
#   - checking the module in which each file is evaluated. This suffices to
#     detect "supporting" files, i.e., those `included` within the module
#     definition.
#   - checking the filename. The top-level file of a non-precompiled package
#     is `include`d into `Base.__toplevel__` (see `Base._require` in
#     `loading.jl`), so module-of-evaluation can't identify it. Here we hope
#     that the top-level filename follows convention and matches the module.
#
# We pass `Base.__toplevel__` through to `parse_and_maybe_eval_source` unchanged. `ExprSplitter`
# has a dedicated `loaded_modules` fallback for that case which resolves
# `module PkgName ... end` to the real loaded module even when `PkgName` is not
# a direct dep of the active project. Rewriting to `Main` here would skip that
# fallback and synthesize an empty `Main.PkgName` stub (#961).
function queue_includes!(pkgdata::PkgData, id::PkgId)
    modstring = id.name
    @lock revise_lock begin
        delids = Int[]
        for i = 1:length(included_files)
            mod, fname = included_files[i]
            modname = String(Symbol(mod))
            if startswith(modname, modstring) || endswith(fname, modstring*".jl")
                pr = parse_and_maybe_eval_source(fname, mod)
                if pr.success
                    fname = relpath(fname, pkgdata)
                    push!(pkgdata, fname=>FileInfo(pr.modexinfos))
                end
                push!(delids, i)
            end
        end
        deleteat!(included_files, delids)
    end
    CodeTracking._pkgfiles[id] = pkgdata.info
    return pkgdata
end

function queue_includes(mod::Module)
    id = PkgId(mod)
    pkgdata = get(pkgdatas, id, nothing)
    if pkgdata === nothing
        pkgdata = PkgData(id)
    end
    queue_includes!(pkgdata, id)
    if has_writable_paths(pkgdata)
        init_watching(pkgdata)
    end
    @lock revise_lock pkgdatas[id] = pkgdata
    return pkgdata
end

# A near-duplicate of some of the functionality of queue_includes!
# This gets called for silenced packages, to make sure they don't "contaminate"
# included_files
function remove_from_included_files(modsym::Symbol)
    i = 1
    modstring = string(modsym)
    @lock revise_lock begin
        while i <= length(included_files)
            mod, fname = included_files[i]
            modname = String(Symbol(mod))
            if startswith(modname, modstring) || endswith(fname, modstring*".jl")
                deleteat!(included_files, i)
            else
                i += 1
            end
        end
    end
end

read_from_cache(pkgdata::PkgData, file::AbstractString) =
    read_from_cache(pkgdata, file, fileinfo(pkgdata, file))
function read_from_cache(pkgdata::PkgData, file::AbstractString, fi::FileInfo)
    filep = joinpath(basedir(pkgdata), file)
    if fi.cachefile == basesrccache
        # Get the original path
        filec = get(cache_file_key, filep, filep)
        return open(basesrccache) do io
            Base._read_dependency_src(io, filec)
        end
    end
    # `read_dependency_src` matches paths by exact string equality, so look the source
    # up by the filename the cache was indexed with rather than one reconstructed from
    # `basedir` (which can diverge in form, e.g. across symlinks; see #1033).
    lookup = isempty(fi.cachefilename) ? filep : fi.cachefilename
    Base.read_dependency_src(fi.cachefile, lookup)
end

function maybe_parse_from_cache!(pkgdata::PkgData, file::AbstractString)
    if startswith(file, "REPL[")
        return add_definitions_from_repl(file)
    end
    return maybe_parse_from_cache!(pkgdata, file, fileinfo(pkgdata, file))
end
function maybe_parse_from_cache!(pkgdata::PkgData, file::AbstractString, fi::FileInfo)
    if (isempty(fi.mod_exs_infos) && !fi.parsed[]) && (!isempty(fi.cachefile) || !isempty(fi.cacheexprs))
        # Source was never parsed, get it from the precompile cache
        src = read_from_cache(pkgdata, file, fi)
        filep = joinpath(basedir(pkgdata), file)
        filec = get(cache_file_key, filep, filep)
        topmod = first(keys(fi.mod_exs_infos))
        pr = parse_and_maybe_eval_source!(fi.mod_exs_infos, src, filec, topmod)
        if !pr.success
            @error "failed to parse cache file source text for $file"
        end
        if !pr.donotparse
            add_modexs!(fi, fi.cacheexprs)
            empty!(fi.cacheexprs)
        end
        fi.parsed[] = true
    end
    return fi
end

function add_modexs!(fi::FileInfo, modexs::Vector{Tuple{Module,Expr}})
    for (mod, rex) in modexs
        exs_infos = get(fi.mod_exs_infos, mod, nothing)
        if exs_infos === nothing
            fi.mod_exs_infos[mod] = exs_infos = ExprsInfos()
        end
        pushex!(exs_infos, rex)
    end
    return fi
end

function maybe_extract_sigs!(fi::FileInfo)
    if !fi.extracted[]
        instantiate_sigs!(fi.mod_exs_infos)
        fi.extracted[] = true
    end
    return fi
end
maybe_extract_sigs!(pkgdata::PkgData, file::AbstractString) = maybe_extract_sigs!(fileinfo(pkgdata, file))

# Signature extraction lowers and partially evaluates each top-level expression. For
# macro-generated code this can be fragile to re-lowering: JLLWrappers builds a `let`
# block that defines and immediately calls gensym'd closures, and re-`:sigs` after the
# package is already loaded can leave the closure's call method undefined for the freshly
# minted closure type (issue #706). The package is already loaded and correct, so on
# failure record the error the same way `revise()` does and keep going, rather than
# letting it abort the manifest watcher.
function maybe_extract_sigs_or_queue_error!(pkgdata::PkgData, file::AbstractString, fi::FileInfo)
    try
        maybe_extract_sigs!(fi)
    catch err
        isa(err, InterruptException) && rethrow(err)
        @lock revise_lock queue_errors[(pkgdata, file)] = (err, catch_backtrace())
    end
    return fi
end

is_not_populated(fi::FileInfo) =
    (isempty(fi.mod_exs_infos) && !fi.parsed[]) && (!isempty(fi.cachefile) || !isempty(fi.cacheexprs))

function maybe_extract_sigs_for_meths(meths)
    for m in meths
        methinfo = get(CodeTracking.method_info, MethodInfoKey(m), false)
        if methinfo === false
            pkgdata = get(pkgdatas, PkgId(m.module), nothing)
            pkgdata === nothing && continue
            for file in srcfiles(pkgdata)
                fi = fileinfo(pkgdata, file)
                if is_not_populated(fi)
                    fi = maybe_parse_from_cache!(pkgdata, file)
                    instantiate_sigs!(fi.mod_exs_infos)
                end
            end
        end
    end
end

function maybe_extract_sigs_for_types(types)
    for ty in types
        m = parentmodule(ty)
        pkgdata = get(pkgdatas, PkgId(m), nothing)
        pkgdata === nothing && continue
        for file in srcfiles(pkgdata)
            fi = fileinfo(pkgdata, file)
            if is_not_populated(fi)
                fi = maybe_parse_from_cache!(pkgdata, file)
                instantiate_sigs!(fi.mod_exs_infos)
            end
        end
    end
end

function maybe_add_includes_to_pkgdata!(pkgdata::PkgData, file::AbstractString, includes; eval_now::Bool=false)
    for (mod, inc) in includes
        inc = joinpath(splitdir(file)[1], inc)
        incrp = relpath(inc, pkgdata)
        hasfile = false
        for srcfile in srcfiles(pkgdata)
            if srcfile == incrp
                hasfile = true
                break
            end
        end
        if !hasfile
            # Add the file to pkgdata
            push!(pkgdata.info.files, incrp)
            fi = FileInfo(mod)
            push!(pkgdata.fileinfos, fi)
            # Parse the source of the new file
            fullfile = joinpath(basedir(pkgdata), incrp)
            if isfile(fullfile)
                parse_and_maybe_eval_source!(fi.mod_exs_infos, fullfile, mod)
                if eval_now
                    # Pin to Revise's frozen world (issue #552); `frozen`'s runtime dispatch
                    # also reduces latency.
                    frozen(instantiate_sigs!, fi.mod_exs_infos; mode=:eval)
                end
            end
            # Add to watchlist
            init_watching(pkgdata, (incrp,))
            yield()
        else
            # Already registered, but the watch may have been relinquished while
            # the file's directory was absent (e.g. a branch switch removed it
            # past `watch_reappear_grace`); an `include` of the file in revised
            # code is the signal to resume. Filesystem events were lost while
            # the watch was down — the stored state (including any deletion of
            # the file's methods) cannot be trusted — so bring the file current
            # before re-arming the watch.
            if !iswatched(pkgdata, incrp)
                revise_file_now(pkgdata, incrp)
                init_watching(pkgdata, (incrp,))
            end
        end
    end
end

# Is `file` (relative to `pkgdata`) registered with a directory watcher? A live
# watch must be left untouched by re-registration attempts: `init_watching`
# resets the file's ctime baseline, which is owned by the watcher task.
function iswatched(pkgdata::PkgData, file::AbstractString)
    dir, basename = splitdir(String(file)::String)
    dirfull = joinpath(basedir(pkgdata), dir)
    return @lock revise_lock begin
        wl = get(watched_files, dirfull, nothing)
        wl !== nothing && haskey(wl.trackedfiles, basename)
    end
end

# `@require` blocks are tracked under a synthetic filename built by appending this
# suffix to the real source file (see `add_require`). Such keys have no file on disk,
# so any path-based operation (reading, watching) must skip them.
const requires_suffix = "__@require__"
is_requires_file(file::AbstractString) = endswith(file, requires_suffix)

# This is used by Requires.jl: therefore even if it appears unused by Revise.jl,
# it cannot be removed as long as we support integration with Requires.jl
function add_require(sourcefile::String, modcaller::Module, idmod::String, ::String, expr::Expr)
    id = PkgId(modcaller)
    # If this fires when the module is first being loaded (because the dependency
    # was already loaded), Revise may not yet have the pkgdata for this package.
    if !haspkgdata(id)
        watch_package(id)
    end

    @lock revise_lock begin
        # Get/create the FileInfo specifically for tracking @require blocks
        pkgdata = pkgdatas[id]
        filekey = relpath(sourcefile, pkgdata) * requires_suffix
        fileidx = fileindex(pkgdata, filekey)
        if fileidx === nothing
            files = srcfiles(pkgdata)
            fileidx = length(files) + 1
            push!(files, filekey)
            push!(pkgdata.fileinfos, FileInfo(modcaller))
        end
        fi = pkgdata.fileinfos[fileidx]
        # Tag the expr to ensure it is unique
        expr = Expr(:block, copy(expr))
        push!(expr.args, :(const __pkguuid__ = $idmod))
        # Add the expression to the fileinfo
        complex = true     # is this too complex to delay?
        if !fi.extracted[]
            # If we haven't yet extracted signatures, do our best to avoid it now in case the
            # signature-extraction code has not yet been compiled (latency reduction)
            includes, complex = deferrable_require(expr)
            if !complex
                # [(modcaller, inc) for inc in includes] but without precompiling a Generator
                modincludes = Tuple{Module,String}[]
                for inc in includes
                    push!(modincludes, (modcaller, inc))
                end
                maybe_add_includes_to_pkgdata!(pkgdata, filekey, modincludes)
                if isempty(fi.mod_exs_infos)
                    # Source has not even been parsed
                    push!(fi.cacheexprs, (modcaller, expr))
                else
                    add_modexs!(fi, Tuple{Module,Expr}[(modcaller, expr)])
                end
            end
        end
        if complex
            frozen(eval_require_now, pkgdata, fileidx, filekey, sourcefile, modcaller, expr)
        end
    end
end

function deferrable_require(expr::Expr)
    includes = String[]
    complex = deferrable_require!(includes, expr)
    return includes, complex
end
function deferrable_require!(includes, expr::Expr)
    if expr.head === :call
        callee = expr.args[1]
        if is_some_include(callee)
            if isa(expr.args[2], AbstractString)
                push!(includes, expr.args[2])
            else
                return true
            end
        elseif callee === :eval || (isa(callee, Expr) && callee.head === :. && is_quotenode_egal(callee.args[2], :eval))
            # Any eval statement is suspicious and requires immediate action
            return false
        end
    end
    expr.head === :macrocall && expr.args[1] === Symbol("@eval") && return true
    for a in expr.args
        a isa Expr || continue
        deferrable_require!(includes, a) && return true
    end
    return false
end

function eval_require_now(pkgdata::PkgData, fileidx::Int, filekey::String, sourcefile::String, modcaller::Module, expr::Expr)
    fi = pkgdata.fileinfos[fileidx]
    exs_infos_new = ExprsInfos()
    exs_infos_new[RelocatableExpr(expr)] = nothing
    mod_exs_infos_new = ModuleExprsInfos(modcaller=>exs_infos_new)
    # Before executing the expression we need to set the load path appropriately
    prev = Base.source_path(nothing)
    tls = task_local_storage()
    tls[:SOURCE_PATH] = sourcefile
    # Now execute the expression
    mod_exs_infos_new, includes = try
        eval_new!(mod_exs_infos_new, fi.mod_exs_infos)
    finally
        if prev === nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    end
    # Add any new methods or `include`d files to tracked objects
    pkgdata.fileinfos[fileidx] = FileInfo(mod_exs_infos_new, fi)
    ret = maybe_add_includes_to_pkgdata!(pkgdata, filekey, includes; eval_now=true)
    return ret
end

# Block until `dirname` reports filesystem activity. Returns the set of entry
# names the events identified, or `nothing` when the changed entries are not
# known (polling mode, a torn-down monitor, or an event that did not name its
# file) -- a `nothing` return means "anything in the directory may have
# changed".
#
# On notifying filesystems this uses a *persistent, buffered* `FolderMonitor`
# (`watch_folder`): the OS watch stays registered between calls and queues every
# event, so a change that lands while we are busy enqueueing a previous one is
# retained rather than dropped. This is the crucial difference from `watch_file`,
# which arms a fresh one-shot monitor per call and silently loses anything that
# occurs in the gap between calls -- a dominant source of missed revisions on
# macOS FSEvents under load.
#
# On polling/non-notifying filesystems we keep the existing directory poll.
function wait_changed_dir(dirname::AbstractString)
    if polling_files[] || nonnotifying_path(dirname)
        wait_changed(dirname)  # unchanged poll behavior
        return nothing
    end
    changed = Set{String}()
    complete = true
    try
        name, _ = watch_folder(dirname)              # block for the next buffered event
        isempty(name) ? (complete = false) : push!(changed, name)
        while true                                   # drain a burst delivered in one wakeup
            name, event = watch_folder(dirname, 0)
            event.timedout && break
            isempty(name) ? (complete = false) : push!(changed, name)
        end
    catch e
        # EOFError: monitor torn down; let caller re-check state. issue #459: Ctrl-C.
        e isa EOFError || (isa(e, InterruptException) && throwto_repl(e)) || throw(e)
        return nothing
    end
    return complete ? changed : nothing
end

# Content hash for disambiguating events whose ctime is unchanged. Reads the
# file, so call it only on event-named files, not in the per-directory sweep.
filehash(path::AbstractString) = open(crc32c, path)

# Scan the `tracked` `name=>PkgId` pairs of directory `dirname`, returning those
# whose files should be queued for revision. `changed` is the set of entry names
# reported by the filesystem events (`nothing` if unknown).
#
# The primary change test compares ctimes, but the kernel stamps inodes with
# tick-resolution (often ~10ms) timestamps, so a delete-and-recreate that lands
# within one tick of the recorded ctime is invisible to it (#945). For a file
# named in an event, an unchanged ctime therefore means either a duplicate
# notification of a change already queued (a single save delivers several
# events, possibly across wakeups) or a same-tick rewrite; only content
# distinguishes the two, so those files are settled by comparing a stored
# hash. Hashes are recorded when a file is queued — an absent hash reads as
# changed, keeping the failure mode "spurious no-op revision", never a missed
# one. The timestamp sweep is unchanged for files the events did not name.
function scan_changed_files(dirname::AbstractString, wf::WatchList, tracked, changed::Union{Nothing,Set{String}})
    latestfiles = Pair{String,PkgId}[]
    for (file, id) in tracked
        fullpath = joinpath(dirname, file)
        if isdir(fullpath)
            # Detected a modification in a directory that we're watching in
            # itself (not as a container for watched files)
            push!(latestfiles, file=>id)
            continue
        elseif !file_exists(fullpath)
            # File may have been deleted. But check again after a very brief pause.
            sleep(0.1)
            if !file_exists(fullpath)
                # Queue the disappearance only once (stored ctime 0.0 marks it
                # as already queued); a sibling-file event must not requeue a
                # persistently missing file. The stored value reverts to a real
                # ctime when the file reappears.
                if (@lock revise_lock get(wf.file_ctimes, file, NaN)) != 0.0
                    push!(latestfiles, file=>id)
                    @lock revise_lock wf.file_ctimes[file] = 0.0
                end
                continue
            end
        end
        current_ctime = ctime(fullpath)
        queueit = current_ctime != @lock revise_lock get(wf.file_ctimes, file, current_ctime - 1)
        if !queueit && changed !== nothing && file in changed
            h = filehash(fullpath)
            queueit = h != @lock revise_lock get(wf.file_hashes, file, h + 1)
        end
        if queueit
            push!(latestfiles, file=>id)
            h = filehash(fullpath)
            @lock revise_lock begin
                wf.file_ctimes[file] = current_ctime
                wf.file_hashes[file] = h
            end
        end
    end
    return latestfiles
end

function watch_files_via_dir(dirname::AbstractString)
    changed = wait_changed_dir(dirname)  # block until the directory changes (buffered on notifying filesystems)
    # Snapshot the tracked files under the lock. We then do the (potentially
    # blocking) filesystem checks below without holding it, reacquiring only to
    # read/update ctimes, so we never hold `revise_lock` across `sleep`.
    snap = @lock revise_lock begin
        wf = get(watched_files, dirname, nothing)
        wf === nothing ? nothing : (wf, collect(wf.trackedfiles))
    end
    snap === nothing && return Pair{String,PkgId}[], false
    wf, tracked = snap
    return scan_changed_files(dirname, wf, tracked, changed), true
end

"""
    watch_package(id::Base.PkgId)

Start watching a package for changes to the files that define it.
This function gets called via a callback registered with `Base.require`, at the completion
of module-loading by `using` or `import`.
"""
function watch_package(id::PkgId)
    # we may have switched environments, so make sure we're watching the right manifest
    active_project_watcher()

    return @lock revise_lock begin
        local pkgdata = get(pkgdatas, id, nothing)
        pkgdata !== nothing && return pkgdata
        modsym = Symbol(id.name)
        if modsym ∈ dont_watch_pkgs
            if id.name ∉ silence_pkgs
                @warn "$modsym is excluded from watching by Revise. Use Revise.silence(\"$modsym\") to quiet this warning."
            end
            remove_from_included_files(modsym)
            return nothing
        end
        pkgdata = parse_pkg_files(id)
        if has_writable_paths(pkgdata)
            init_watching(pkgdata, srcfiles(pkgdata))
        end
        pkgdatas[id] = pkgdata
        pkgdata
    end
end

function has_writable_paths(pkgdata::PkgData)
    dir = basedir(pkgdata)
    isdir(dir) || return true
    haswritable = false
    # Compatibility note:
    # The following can be written in cd(dir) do ... end block
    # but that would trigger Julia to crash for some corner cases.
    # This is identified on Julia 1.7.3 + modified ubuntu 18.04, and it is
    # verified that doesn't happen for Julia 1.9.2 on the same machine.
    current_dir = pwd()
    try
        cd(dir)
        for file in srcfiles(pkgdata)
            haswritable |= iswritable(file)
        end
    finally
        cd(current_dir)
    end
    return haswritable
end

function watch_includes(mod::Module, fn::AbstractString)
    @lock revise_lock push!(included_files, (mod, abspath_no_normalize(fn)))
end

## Working with Pkg and code-loading

# Much of this is adapted from base/loading.jl

function manifest_file(project_file = Base.active_project())
    if project_file isa String && isfile(project_file)
        mfile = Base.project_file_manifest_path(project_file)
        if mfile isa String
            return mfile
        end
    end
    return nothing
end

function manifest_paths!(pkgpaths::Dict, manifest_file::String)
    d = if isdefined(Base, :get_deps) # `get_deps` is present in versions that support new manifest formats
        Base.get_deps(Base.parsed_toml(manifest_file))
    else
        Base.parsed_toml(manifest_file)
    end
    for (name, entries) in d
        entries::Vector{Any}
        for entry in entries
            id = PkgId(UUID(entry["uuid"]::String), name)
            path = Base.explicit_manifest_entry_path(manifest_file, id, entry)
            if path isa String
                if isfile(path)
                    # Workaround for #802
                    path = dirname(dirname(path))
                end
                pkgpaths[id] = path
            end
        end
    end
    return pkgpaths
end

manifest_paths(manifest_file::String) =
    manifest_paths!(Dict{PkgId,String}(), manifest_file)

function watch_manifest(mfile::String)
    while true
        try
            wait_changed(mfile)
        catch e
            # issue #459
            (isa(e, InterruptException) && throwto_repl(e)) || throw(e)
        end
        manifest_file() == mfile || continue   # process revisions only if this is the active manifest
        try
            with_logger(_debug_logger) do
                @debug "Pkg" _group="manifest_update" manifest_file=mfile
                isfile(mfile) || return nothing
                pkgdirs = manifest_paths(mfile)
                pathreplacements = Pair{String,String}[]
                @lock revise_lock begin
                    for (id, pkgdir) in pkgdirs
                        if haskey(pkgdatas, id)
                            pkgdata = pkgdatas[id]
                            if !samefile(pkgdir, basedir(pkgdata))
                                ## The package directory has changed
                                @debug "Pkg" _group="pathswitch" oldpath=basedir(pkgdata) newpath=pkgdir
                                push!(pathreplacements, basedir(pkgdata)=>pkgdir)
                                switch_basepath(pkgdata, pkgdir)
                            end
                        end
                    end
                    # Update the paths in the watchlist
                    for (oldpath, newpath) in pathreplacements
                        for (_, pkgdata) in pkgdatas
                            if samefile(basedir(pkgdata), oldpath)
                                switch_basepath(pkgdata, newpath)
                            end
                        end
                    end
                end
            end
        catch err
            @error "Error watching manifest" exception=(err, trim_toplevel!(catch_backtrace()))
        end
    end
end

function switch_basepath(pkgdata::PkgData, newpath::String)
    # Stop all associated watching tasks
    for dir in unique_dirs(srcfiles(pkgdata))
        @debug "Pkg" _group="unwatch" dir=dir
        @lock revise_lock delete!(watched_files, joinpath(basedir(pkgdata), dir))
        # Note: if the file is revised, the task(s) will run one more time.
        # However, because we've removed the directory from the watch list this will be a no-op,
        # and then the tasks will be dropped.
    end
    # Revise code as needed
    files = String[]
    mustnotify = false
    for file in srcfiles(pkgdata)
        # issue #678: `@require` blocks are tracked under a synthetic filename with no
        # file on disk; reading or watching it as a real path would error.
        is_requires_file(file) && continue
        fi = try
            maybe_parse_from_cache!(pkgdata, file)
        catch
            # https://github.com/JuliaLang/julia/issues/42404
            # Get the source-text from the package source instead
            fi = fileinfo(pkgdata, file)
            if isempty(fi.mod_exs_infos) && (!isempty(fi.cachefile) || !isempty(fi.cacheexprs))
                filep = joinpath(basedir(pkgdata), file)
                src = read(filep, String)
                topmod = first(keys(fi.mod_exs_infos))
                if !parse_and_maybe_eval_source!(fi.mod_exs_infos, src, filep, topmod).success
                    @error "failed to parse source text for $filep"
                end
                add_modexs!(fi, fi.cacheexprs)
                empty!(fi.cacheexprs)
                fi.parsed[] = true
            end
            fi
        end
        maybe_extract_sigs_or_queue_error!(pkgdata, file, fi)
        @lock revise_lock push!(revision_queue, (pkgdata, file))
        push!(files, file)
        mustnotify = true
    end
    mustnotify && notify(revision_event)
    # Update the directory
    pkgdata.info.basedir = newpath
    # Restart watching, if applicable
    if has_writable_paths(pkgdata)
        init_watching(pkgdata, files)
    end
    return nothing
end

function active_project_watcher()
    mfile = manifest_file()
    isnothing(mfile) && return
    @lock revise_lock begin
        mfile ∈ watched_manifests && return
        push!(watched_manifests, mfile)
    end
    wmthunk = TaskThunk(watch_manifest, (mfile,))
    schedule(Task(wmthunk))
    return
end
