"""
    Revise.WatchList

A struct for holding files that live inside a directory.
Some platforms (OSX) have trouble watching too many files. So we
watch parent directories, and keep track of which files in them
should be tracked.

Fields:
- `timestamp`: mtime of last update
- `trackedfiles`: Set of filenames, generally expressed as a relative path
"""
mutable struct WatchList
    timestamp::Float64         # unix time of last revision
    trackedfiles::Dict{String,PkgId}
end

## WatchList utilities
function updatetime!(wl::WatchList)
    wl.timestamp = time()
end
Base.push!(wl::WatchList, filenameid::Pair{<:AbstractString,PkgId}) =
    push!(wl.trackedfiles, filenameid)
Base.push!(wl::WatchList, filenameid::Pair{<:AbstractString,PkgFiles}) =
    push!(wl, filenameid.first=>filenameid.second.id)
Base.push!(wl::WatchList, filenameid::Pair{<:AbstractString,PkgData}) =
    push!(wl, filenameid.first=>filenameid.second.info)
WatchList() = WatchList(time(), Dict{String,PkgId}())
Base.in(file, wl::WatchList) = haskey(wl.trackedfiles, file)

@static if Sys.isapple()
    # HFS+ rounds time to seconds, see #22
    # https://developer.apple.com/library/archive/technotes/tn/tn1150.html#HFSPlusDates
    newer(mtime, timestamp) = ceil(mtime) >= floor(timestamp)
else
    newer(mtime, timestamp) = mtime >= timestamp
end

"""
    success = throwto_repl(e::Exception)

Try throwing `e` from the REPL's backend task. Returns `true` if the necessary conditions
were met and the throw can be expected to succeed. The throw is generated from another
task, so a `yield` will need to occur before it happens.
"""
function throwto_repl(e::Exception)
    if isdefined(Base, :active_repl_backend) &&
            !isnothing(Base.active_repl_backend) &&
            Base.active_repl_backend.backend_task.state === :runnable &&
            isempty(Base.Workqueue) &&
            Base.active_repl_backend.in_eval
        @async Base.throwto(Base.active_repl_backend.backend_task, e)
        return true
    end
    return false
end
