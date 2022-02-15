"""
    Revise.track(Base)
    Revise.track(Core.Compiler)
    Revise.track(stdlib)

Track updates to the code in Julia's `base` directory, `base/compiler`, or one of its
standard libraries.
"""
function track(mod::Module; modified_files=revision_queue)
    id = PkgId(mod)
    modname = nameof(mod)
    return _track(id, modname; modified_files=modified_files)
end

const vstring = "v$(VERSION.major).$(VERSION.minor)"

function inpath(path, dirs)
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

function _track(id, modname; modified_files=revision_queue)
    haskey(pkgdatas, id) && return nothing  # already tracked
    isbase = modname === :Base
    isstdlib = !isbase && modname ∈ stdlib_names
    if isbase || isstdlib
        # Test whether we know where to find the files
        if isbase
            srcdir = fixpath(joinpath(juliadir, "base"))
            dirs = ["base"]
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
            dirs = ["stdlib", String(modname)]
        end
        if !isdir(srcdir)
            @error "unable to find path containing source for $modname, tracking is not possible"
        end
        # Determine when the basesrccache was built
        mtcache = mtime(basesrccache)
        # Initialize expression-tracking for files, and
        # note any modified since Base was built
        pkgdata = get(pkgdatas, id, nothing)
        if pkgdata === nothing
            pkgdata = PkgData(id, srcdir)
        end
        for (submod, filename) in Iterators.drop(Base._included_files, 1)  # stepping through sysimg.jl rebuilds Base, omit it
            ffilename = fixpath(filename)
            inpath(ffilename, dirs) || continue
            keypath = ffilename[1:last(findfirst(dirs[end], ffilename))]
            rpath = relpath(ffilename, keypath)
            fullpath = joinpath(basedir(pkgdata), rpath)
            if fullpath != filename
                cache_file_key[fullpath] = filename
                src_file_key[filename] = fullpath
            end
            push!(pkgdata, rpath=>FileInfo(submod, basesrccache))
            if mtime(ffilename) > mtcache
                with_logger(_debug_logger) do
                    @debug "Recipe for Base/StdLib" _group="Watching" filename=filename mtime=mtime(filename) mtimeref=mtcache
                end
                push!(modified_files, (pkgdata, rpath))
            end
        end
        # Add files to CodeTracking pkgfiles
        CodeTracking._pkgfiles[id] = pkgdata.info
        # Add the files to the watch list
        init_watching(pkgdata, srcfiles(pkgdata))
        # Save the result (unnecessary if already in pkgdatas, but doesn't hurt either)
        pkgdatas[id] = pkgdata
    elseif modname === :Compiler
        compilerdir = normpath(joinpath(juliadir, "base", "compiler"))
        pkgdata = get(pkgdatas, id, nothing)
        if pkgdata === nothing
            pkgdata = PkgData(id, compilerdir)
        end
        track_subdir_from_git!(pkgdata, compilerdir; modified_files=modified_files)
        # insertion into pkgdatas is done by track_subdir_from_git!
    else
        error("no Revise.track recipe for module ", modname)
    end
    return nothing
end

# Fix paths to files that define Julia (base and stdlibs)
function fixpath(filename::AbstractString; badpath=basebuilddir, goodpath=juliadir)
    startswith(filename, badpath) || return normpath(filename)
    filec = filename
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
    prefix = relpath(subdir, repo_path)   # git-relative path of this subdir
    tree = git_tree(repo, commit)
    files = Iterators.filter(file->startswith(file, prefix) && endswith(file, ".jl"), keys(tree))
    ccall((:giterr_clear, :libgit2), Cvoid, ())  # necessary to avoid errors like "the global/xdg file 'attributes' doesn't exist: No such file or directory"
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
        if fmod === Core.Compiler
            endswith(fullpath, "compiler.jl") && continue  # defines the module, skip
            @static if isdefined(Core.Compiler, :EscapeAnalysis)
                # after https://github.com/JuliaLang/julia/pull/43800
                if contains(fullpath, "compiler/ssair/EscapeAnalysis")
                    fmod = Core.Compiler.EscapeAnalysis
                end
            end
        end
        if src != read(fullpath, String)
            push!(modified_files, (pkgdata, rpath))
        end
        fi = FileInfo(fmod)
        if parse_source!(fi.modexsigs, src, file, fmod) === nothing
            @warn "failed to parse Git source text for $file"
        else
            instantiate_sigs!(fi.modexsigs)
        end
        push!(pkgdata, rpath=>fi)
    end
    if !isempty(pkgdata.fileinfos)
        id = PkgId(pkgdata)
        CodeTracking._pkgfiles[id] = pkgdata.info
        init_watching(pkgdata, srcfiles(pkgdata))
        pkgdatas[id] = pkgdata
    end
    return nothing
end

# For tracking Julia's own stdlibs
const stdlib_names = Set([
    :Base64, :CRC32c, :Dates, :DelimitedFiles, :Distributed,
    :FileWatching, :Future, :InteractiveUtils, :Libdl,
    :LibGit2, :LinearAlgebra, :Logging, :Markdown, :Mmap,
    :OldPkg, :Pkg, :Printf, :Profile, :Random, :REPL,
    :Serialization, :SHA, :SharedArrays, :Sockets, :SparseArrays,
    :Statistics, :SuiteSparse, :Test, :Unicode, :UUIDs,
    :TOML, :Artifacts, :LibCURL_jll, :LibCURL, :MozillaCACerts_jll,
    :Downloads, :Tar, :ArgTools, :NetworkOptions])

# This replacement is needed because the path written during compilation differs from
# the git source path
const stdlib_rep = joinpath("usr", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)") => "stdlib"

const juliaf2m = Dict(normpath(replace(file, stdlib_rep))=>mod
    for (mod,file) in Base._included_files)
