function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    precompile(Tuple{typeof(setindex!), typeof(fileinfos), FileInfo, String})
    precompile(Tuple{typeof(setindex!), typeof(module2files), Vector{String}, Symbol})
    precompile(Tuple{typeof(setindex!), typeof(watched_files), WatchList, String})
    precompile(Tuple{typeof(haskey), typeof(watched_files), String})

    precompile(Tuple{typeof(_watch_package), Base.PkgId})
    precompile(Tuple{typeof(revise_dir_queued), String})
    precompile(Tuple{typeof(run_backend), REPL.REPLBackend})
    precompile(Tuple{typeof(steal_repl_backend), REPL.REPLBackend})

    return nothing
end
