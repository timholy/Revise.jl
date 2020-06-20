"""
    repo, repo_path = git_repo(path::AbstractString)

Return the `repo::LibGit2.GitRepo` containing the file or directory `path`.
`path` does not necessarily need to be the top-level directory of the
repository. Also returns the `repo_path` of the top-level directory for the
repository.
"""
function git_repo(path::AbstractString)
    if isfile(path)
        path = dirname(path)
    end
    while true
        # check if we are at the repo root
        git_dir = joinpath(path, ".git")
        if ispath(git_dir)
            return LibGit2.GitRepo(path), path
        end
        # traverse to parent folder
        previous = path
        path = dirname(path)
        if previous == path
            return nothing, path
        end
    end
end

function git_tree(repo::LibGit2.GitRepo, commit="HEAD")
    return LibGit2.GitTree(repo, "$commit^{tree}")
end
function git_tree(path::AbstractString, commit="HEAD")
    repo, _ = git_repo(path)
    return git_tree(repo, commit)
end

"""
    files = git_files(repo)

Return the list of files checked into `repo`.
"""
function git_files(repo::LibGit2.GitRepo)
    status = LibGit2.GitStatus(repo;
        status_opts=LibGit2.StatusOptions(flags=LibGit2.Consts.STATUS_OPT_INCLUDE_UNMODIFIED))
    files = String[]
    for i = 1:length(status)
        e = status[i]
        dd = unsafe_load(e.head_to_index)
        push!(files, unsafe_string(dd.new_file.path))
    end
    return files
end
Base.keys(tree::LibGit2.GitTree) = git_files(tree.owner)

"""
    Revise.git_source(file::AbstractString, reference)

Read the source-text for `file` from a git commit `reference`.
The reference may be a string, Symbol, or `LibGit2.Tree`.

# Example:

    Revise.git_source("/path/to/myfile.jl", "HEAD")
    Revise.git_source("/path/to/myfile.jl", :abcd1234)  # by commit SHA
"""
function git_source(file::AbstractString, reference)
    fullfile = abspath(file)
    tree = git_tree(fullfile, reference)
    # git uses Unix-style paths even on Windows
    filepath = replace(relpath(fullfile, LibGit2.path(tree.owner)),
                       Base.Filesystem.path_separator_re=>'/')
    return git_source(filepath, tree)
end

function git_source(file::AbstractString, tree::LibGit2.GitTree)
    local blob
    blob = tree[file]
    if blob === nothing
        # assume empty tree when tracking new files
        src = ""
    else
        src = LibGit2.content(blob)
    end
    return src
end
