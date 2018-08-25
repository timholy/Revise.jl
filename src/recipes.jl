"""
    Revise.track(Base)
    Revise.track(Core.Compiler)
    Revise.track(stdlib)

Track updates to the code in Julia's `base` directory, `base/compiler`, or one of its
standard libraries.
"""
function track(mod::Module)
    if mod == Base
        # Test whether we know where to find the files
        if !isdir(joinpath(juliadir, "base"))
            @error "unable to find path containing Julia's base/ folder, tracking is not possible"
        end
        # Determine when the basesrccache was built
        mtcache = mtime(basesrccache)
        # Initialize expression-tracking for files, and
        # note any modified since Base was built
        files = String[]
        for (submod, filename) in Base._included_files
            filename = fixpath(filename)
            push!(fileinfos, filename=>FileInfo(submod, basesrccache))
            push!(files, filename)
            if mtime(filename) > mtcache
                with_logger(_debug_logger) do
                    @debug "Recipe for Base" _group="Watching" filename=filename mtime=mtime(filename) mtimeref=mtcache
                end
                push!(revision_queue, filename)
            end
        end
        # Add the files to the watch list
        init_watching(files)
    elseif mod == Core.Compiler
        compilerdir = joinpath(juliadir, "base", "compiler")
        track_subdir_from_git(Core.Compiler, compilerdir)
    elseif nameof(mod) ∈ stdlib_names
        stdlibdir = joinpath(juliadir, "stdlib")
        libdir = joinpath(stdlibdir, String(nameof(mod)), "src")
        track_subdir_from_git(mod, normpath(libdir))
    else
        error("no Revise.track recipe for module ", mod)
    end
    nothing
end

# Fix paths to files that define Julia (base and stdlibs)
function fixpath(filename; badpath=basebuilddir, goodpath=juliadir)
    isfile(filename) && return filename
    filec = filename
    startswith(filename, badpath) || error(filename, " does not start with ", badpath)
    relfilename = relpath(filename, badpath)
    for strippath in (joinpath("usr", "share", "julia"),)
        if startswith(relfilename, strippath)
            relfilename = relpath(relfilename, strippath)
        end
    end
    filename = normpath(joinpath(goodpath, relfilename))
    cache_file_key[filename] = filec
    return filename
end

# For tracking subdirectories of Julia itself (base/compiler, stdlibs)
function track_subdir_from_git(mod::Module, subdir::AbstractString; commit=Base.GIT_VERSION_INFO.commit)
    # diff against files at the same commit used to build Julia
    repo, repo_path = git_repo(subdir)
    if repo == nothing
        throw(GitRepoException(subdir))
    end
    prefix = relpath(subdir, repo_path)   # git-relative path of this subdir
    tree = git_tree(repo, commit)
    files = Iterators.filter(file->startswith(file, prefix) && endswith(file, ".jl"), keys(tree))
    ccall((:giterr_clear, :libgit2), Cvoid, ())  # necessary to avoid errors like "the global/xdg file 'attributes' doesn't exist: No such file or directory"
    wfiles = String[]  # files to watch
    for file in files
        fullpath = joinpath(repo_path, file)
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
        if src != read(fullpath, String)
            push!(revision_queue, fullpath)
        end
        fmod = get(juliaf2m, fullpath, Core.Compiler)  # Core.Compiler is not cached
        fi = FileInfo(fmod)
        if parse_source!(fi.fm, src, Symbol(file), 1, fmod) === nothing
            @warn "failed to parse Git source text for $file"
        else
            instantiate_sigs!(fi.fm)
        end
        fileinfos[fullpath] = fi
        push!(wfiles, fullpath)
    end
    init_watching(wfiles)
    return nothing
end

# For tracking Julia's own stdlibs
const stdlib_names = Set([
    :Base64, :CRC32c, :Dates, :DelimitedFiles, :Distributed,
    :FileWatching, :Future, :InteractiveUtils, :Libdl,
    :LibGit2, :LinearAlgebra, :Logging, :Markdown, :Mmap,
    :OldPkg, :Pkg, :Printf, :Profile, :Random, :REPL,
    :Serialization, :SHA, :SharedArrays, :Sockets, :SparseArrays,
    :Statistics, :SuiteSparse, :Test, :Unicode, :UUIDs])

# This replacement is needed because the path written during compilation differs from
# the git source path
const stdlib_rep = joinpath("usr", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)") => "stdlib"

const juliaf2m = Dict(normpath(replace(file, stdlib_rep))=>mod
    for (mod,file) in Base._included_files)
