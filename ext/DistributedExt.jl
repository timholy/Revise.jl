module DistributedExt

import Distributed: myid, workers, remotecall

import Revise
import Revise: DistributedWorker


function get_workers()
    map(DistributedWorker, workers())
end

function Revise.remotecall_impl(f, worker::DistributedWorker, args...; kwargs...)
    remotecall(f, worker.id, args...; kwargs...)
end

Revise.is_master_worker(::typeof(get_workers)) = myid() == 1
Revise.is_master_worker(worker::DistributedWorker) = worker.id == 1

function __init__()
    Revise.register_workers_function(get_workers)
end

end
