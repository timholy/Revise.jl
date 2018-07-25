"""
    Revise.track(Base)
    Revise.track(Core.Compiler)
    Revise.track(stdlib)

Track updates to the code in Julia's `base` directory, `base/compiler`, or one of its
standard libraries.
"""
function track(mod::Module)
    if mod == Base
        # Determine when the basesrccache was built
        mtcache = mtime(basesrccache)
        # Initialize expression-tracking for files, and
        # note any modified since Base was built
        files = String[]
        for (submod, filename) in Base._included_files
            submod == Main || startswith(String(nameof(submod)), "Base") || continue
            push!(file2modules, filename=>FileModules(submod, ModDict(), basesrccache))
            push!(files, filename)
            if mtime(filename) > mtcache
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

# For tracking subdirectories of Julia itself (base/compiler, stdlibs)
function track_subdir_from_git(mod::Module, subdir::AbstractString)
    # diff against files at the same commit used to build Julia
    repo, repo_path = git_repo(subdir)
    if repo == nothing
        error("could not find git repository at $subdir")
    end
    prefix = subdir[length(repo_path)+2:end]   # git-relative path of this subdir
    tree = git_tree(repo, Base.GIT_VERSION_INFO.commit)
    files = Iterators.filter(file->startswith(file, prefix), keys(tree))
    ccall((:giterr_clear, :libgit2), Cvoid, ())  # necessary to avoid errors like "the global/xdg file 'attributes' doesn't exist: No such file or directory"
    wfiles = String[]  # files to watch
    for file in files
        fullpath = joinpath(repo_path, file)
        src = git_source(file, tree)
        if src != read(fullpath, String)
            push!(revision_queue, fullpath)
        end
        fmod = get(juliaf2m, fullpath, Core.Compiler)  # Core.Compiler is not cached
        md = ModDict(fmod=>ExprsSigs())
        if !parse_source!(md, src, Symbol(file), 1, fmod)
            warn("failed to parse Git source text for ", file)
        end
        fm = FileModules(fmod, md)
        push!(file2modules, fullpath=>fm)
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
