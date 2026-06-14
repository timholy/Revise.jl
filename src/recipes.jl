"""
    Revise.track(Base; revise_throw::Bool=!isinteractive())
    Revise.track(Core.Compiler; revise_throw::Bool=!isinteractive())
    Revise.track(stdlib; revise_throw::Bool=!isinteractive())
    Revise.track(SysimagePackage; revise_throw::Bool=!isinteractive())

Track updates to the code in Julia's `base` directory, `base/compiler`, one of its
standard libraries, or a package baked into the running system image (e.g. one
compiled with PackageCompiler.jl). Calls `revise()` after tracking to ensure that any
changes detected during tracking are applied immediately. Optionally, if `revise_throw`
is `true`, `revise()` will throw if any exceptions are encountered while revising.

A package compiled into a system image is already loaded at startup, so Revise's
usual package callback never fires and any source edits made since the image was
built go unnoticed. Calling `Revise.track` on such a package starts watching it and
applies any pending edits.
"""
function track(mod::Module; modified_files=revision_queue, revise_throw::Bool=!isinteractive())
    id = pkgidid_for_mod(mod)
    modname = nameof(mod)
    ret = _track(id, modname; modified_files=modified_files)
    revise(; throw=revise_throw) # force revision so following calls in the same block work
    return ret
end

pkgidid_for_mod(mod) = Base.moduleroot(mod) == Core.Compiler ? PkgId(mod, "Core.Compiler") : PkgId(mod)

const vstring = "v$(VERSION.major).$(VERSION.minor)"

function inpath(path::AbstractString, dirs::Vector{String})
    spath = splitpath(path)
    idx = findfirst(isequal(first(dirs)), spath)
    idx === nothing && return false
    for i = 2:length(dirs)
        idx += 1
        idx <= length(spath) || return false
        if spath[idx] == vstring
            idx += 1
        end
        spath[idx] == dirs[i] || return false
    end
    return true
end

function _track(id::PkgId, modname::Symbol; modified_files=revision_queue)
    haspkgdata(id) && return nothing  # already tracked
    isbase = modname === :Base
    isstdlib = !isbase && Base.is_stdlib(id)
    if isbase || isstdlib
        # Test whether we know where to find the files
        if isbase
            srcdir = fixpath(joinpath(juliadir, "base"))
            dirs = String["base"]
        else
            stdlibv = joinpath("stdlib", vstring, String(modname))
            srcdir = fixpath(joinpath(juliadir, stdlibv))
            if !isdir(srcdir)
                srcdir = fixpath(joinpath(juliadir, "stdlib", String(modname)))
            end
            if !isdir(srcdir)
                # This can happen for Pkg, since it's developed out-of-tree
                srcdir = joinpath(juliadir, "usr", "share", "julia", stdlibv)  # omit fixpath deliberately
            end
            dirs = String["stdlib", String(modname)]
        end
        if !isdir(srcdir)
            @error "unable to find path containing source for $modname, tracking is not possible"
        end
        # Determine when the basesrccache was built
        mtcache = mtime(basesrccache)
        # Initialize expression-tracking for files, and
        # note any modified since Base was built
        pkgdata = getpkgdata(id)
        if pkgdata === nothing
            pkgdata = PkgData(id, srcdir)
        end
        ret = Revise.pkg_fileinfo(id)
        if ret !== nothing
            cachefile, _ = ret
            if cachefile === nothing
                @error "unable to find cache file for $id, tracking is not possible"
            end
        else
            cachefile = basesrccache
        end
        @lock revise_lock begin
            for (submod, filename) in modulefiles_basestlibs(id)
                ffilename = fixpath(filename)
                inpath(ffilename, dirs) || continue
                keypath = ffilename[1:last(findfirst(dirs[end], ffilename))]
                rpath = relpath(ffilename, keypath)
                fullpath = joinpath(basedir(pkgdata), rpath)
                if fullpath != filename
                    cache_file_key[fullpath] = filename
                    src_file_key[filename] = fullpath
                end
                push!(pkgdata, rpath=>FileInfo(submod, cachefile))
                if mtime(ffilename) > mtcache
                    with_logger(_debug_logger) do
                        @debug "Recipe for Base/StdLib" _group="Watching" filename=filename mtime=mtime(filename) mtimeref=mtcache
                    end
                    push!(modified_files, (pkgdata, rpath))
                end
            end
        end
        # Add files to CodeTracking pkgfiles
        CodeTracking._pkgfiles[id] = pkgdata.info
        # Add the files to the watch list
        init_watching(pkgdata, srcfiles(pkgdata))
        # Save the result (unnecessary if already in pkgdatas, but doesn't hurt either)
        @lock revise_lock pkgdatas[id] = pkgdata
    elseif modname === :Compiler
        compilerdir = joinpath(juliadir, "Compiler", "src")
        compilerdir_pre_112 = joinpath(juliadir, "base", "compiler")
        isdir(compilerdir) || (compilerdir = compilerdir_pre_112)
        pkgdata = getpkgdata(id)
        if pkgdata === nothing
            pkgdata = PkgData(id, compilerdir)
        end
        track_subdir_from_git!(pkgdata, compilerdir; modified_files=modified_files)
        # insertion into pkgdatas is done by track_subdir_from_git!
    else
        # issue #685: a package compiled into a system image (e.g. with
        # PackageCompiler.jl) is already loaded when the session starts, so the
        # `using`/`import` package callback that normally sets up watching never
        # fired, and Julia never checked whether the on-disk source is newer than
        # the baked-in code. Set up watching now and queue any source file modified
        # since the package was precompiled. We use the precompile cache file's
        # mtime as the reference point; for a sysimage package the cache file
        # remains in the depot after the build.
        origin = get(Base.pkgorigins, id, nothing)
        cachepath = origin === nothing ? nothing : origin.cachepath
        if cachepath === nothing || isempty(cachepath)
            error("no Revise.track recipe for module ", modname)
        end
        pkgdata = watch_package(id)
        pkgdata === nothing && return nothing
        reftime = mtime(cachepath)
        @lock revise_lock begin
            for rpath in srcfiles(pkgdata)
                fullpath = joinpath(basedir(pkgdata), rpath)
                if mtime(fullpath) > reftime
                    push!(modified_files, (pkgdata, rpath))
                end
            end
        end
    end
    return nothing
end

# Fix paths to files that define Julia (base and stdlibs)
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

# For tracking subdirectories of Julia itself (base/compiler, stdlibs)
function track_subdir_from_git!(pkgdata::PkgData, subdir::AbstractString; commit=Base.GIT_VERSION_INFO.commit, modified_files=revision_queue)
    # diff against files at the same commit used to build Julia
    repo, repo_path = git_repo(subdir)
    if repo == nothing
        throw(GitRepoException(subdir))
    end
    prefix = string(relpath(realpath(subdir), realpath(repo_path)), "/")   # git-relative path of this subdir
    tree = git_tree(repo, commit)
    files = Iterators.filter(file->startswith(file, prefix) && endswith(file, ".jl"), keys(tree))
    ccall((:giterr_clear, :libgit2), Cvoid, ())  # necessary to avoid errors like "the global/xdg file 'attributes' doesn't exist: No such file or directory"
    @lock revise_lock begin
        for file in files
            fullpath = joinpath(repo_path, file)
            rpath = relpath(fullpath, pkgdata)  # this might undo the above, except for Core.Compiler
            local src
            try
                src = git_source(file, tree)
            catch err
                if err isa KeyError
                    @warn "skipping $file, not found in repo"
                    continue
                end
                rethrow(err)
            end
            fmod = get(juliaf2m, fullpath, Core.Compiler)  # Core.Compiler is not cached
            # The top-level Compiler.jl file `include`s every other Compiler source file
            # and defines the `Compiler` baremodule itself. We can't usefully parse/track
            # it as a normal source file: in Julia 1.12+ its parent module is `Base` (via
            # `Base._included_files`) rather than `Core.Compiler`, and re-executing its
            # contents would attempt to redefine the `Compiler` baremodule.
            endswith(fullpath, "compiler.jl") && continue              # v1.11-: defines the module
            endswith(fullpath, "/Compiler/src/Compiler.jl") && continue  # v1.12+: defines the module
            if fmod === Core.Compiler
                @static if isdefined(Core.Compiler, :EscapeAnalysis)
                    # after https://github.com/JuliaLang/julia/pull/43800
                    if endswith(fullpath, "/compiler/ssair/EscapeAnalysis.jl") || contains(fullpath, "/Compiler/src/ssair/EscapeAnalysis.jl")
                        fmod = Core.Compiler.EscapeAnalysis
                    end
                end
                @static if isdefined(Core.Compiler, :TrimVerifier)
                    if endswith(fullpath, "/Compiler/src/verifytrim.jl")
                        fmod = Core.Compiler.TrimVerifier
                    end
                end
            end
            if src != read(fullpath, String)
                push!(modified_files, (pkgdata, rpath))
            end
            fi = FileInfo(fmod)
            if !parse_and_maybe_eval_source!(fi.mod_exs_infos, src, file, fmod).success
                @warn "failed to parse Git source text for $file"
            else
                instantiate_sigs!(fi.mod_exs_infos)
            end
            push!(pkgdata, rpath=>fi)
        end
    end
    if !isempty(pkgdata.fileinfos)
        id = PkgId(pkgdata)
        CodeTracking._pkgfiles[id] = pkgdata.info
        init_watching(pkgdata, srcfiles(pkgdata))
        @lock revise_lock pkgdatas[id] = pkgdata
    end
    return nothing
end

# This replacement is needed because the path written during compilation differs from
# the git source path
const stdpath_rep = (joinpath("usr", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)") => "stdlib",
                    joinpath("usr", "share", "julia", "Compiler") => "Compiler")

const juliaf2m = Dict(normpath(replace(file, stdpath_rep...))=>mod
    for (mod,file) in Base._included_files)
