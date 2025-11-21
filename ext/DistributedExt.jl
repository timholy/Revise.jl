module DistributedExt

import Distributed: myid, workers, remotecall

using Revise: ReviseCore
using .ReviseCore: DistributedWorker

function get_workers()
    map(DistributedWorker, workers())
end

function ReviseCore.remotecall_impl(f, worker::DistributedWorker, args...; kwargs...)
    remotecall(f, worker.id, args...; kwargs...)
end

ReviseCore.is_master_worker(::typeof(get_workers)) = myid() == 1
ReviseCore.is_master_worker(worker::DistributedWorker) = worker.id == 1

function __init__()
    ReviseCore.register_workers_function(get_workers)
end

end
