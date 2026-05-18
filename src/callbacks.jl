# Globals needed to support `entr` and other callbacks

"""
    Revise.revision_event::Base.Event

This event is used to notify `entr` that one of the watched files has changed.
It is created with `autoreset=true` so that a `notify` fired between a waiter's
return from `wait` and its next call to `wait` is not lost — see issue #837.
"""
const revision_event = Base.Event(true)

"""
    Revise.user_callbacks_queue

Global variable, `user_callbacks_queue` holds `key` values for which the
file has changed but the user hooks have not yet been called.
"""
const user_callbacks_queue = Set{Any}()

"""
    Revise.user_callbacks_by_file

Global variable, maps files (identified by their absolute path) to the set of
callback keys registered for them.
"""
const user_callbacks_by_file = Dict{String, Set{Any}}()

"""
    Revise.user_callbacks_by_key

Global variable, maps callback keys to user hooks.
"""
const user_callbacks_by_key = Dict{Any, Any}()

"""
    key = Revise.add_callback(f, files, modules=nothing; key=gensym())

Add a user-specified callback, to be executed during the first run of
`revise()` after a file in `files` or a module in `modules` is changed on the
file system. If `all` is set to `true`, also execute the callback whenever any
file already monitored by Revise changes. In an interactive session like the
REPL, Juno or Jupyter, this means the callback executes immediately before
executing a new command / cell.

You can use the return value `key` to remove the callback later
(`Revise.remove_callback`) or to update it using another call
to `Revise.add_callback` with `key=key`.
"""
function add_callback(f, files, modules=nothing; all=false, key=gensym())
    fix_trailing(path) = isdir(path) ? joinpath(path, "") : path   # insert a trailing '/' if missing, see https://github.com/timholy/Revise.jl/issues/470#issuecomment-633298553

    remove_callback(key)

    files = map(fix_trailing, map(abspath, files))
    init_watching(files)

    # in case the `all` kwarg was set:
    # add all files which are already known to Revise
    if all
        for pkgdata in values(pkgdatas)
            append!(files, joinpath.(Ref(basedir(pkgdata)), srcfiles(pkgdata)))
        end
    end

    if modules !== nothing
        for mod in modules
            track(mod)  # Potentially needed for modules like e.g. Base
            id = PkgId(mod)
            pkgdata = pkgdatas[id]
            for file in srcfiles(pkgdata)
                absname = joinpath(basedir(pkgdata), file)
                push!(files, absname)
            end
        end
    end

    # There might be duplicate entries in `files`, but it shouldn't cause any
    # problem with the sort of things we do here
    for file in files
        cb = get!(Set, user_callbacks_by_file, file)
        push!(cb, key)
    end
    user_callbacks_by_key[key] = f

    return key
end

"""
    Revise.remove_callback(key)

Remove a callback previously installed by a call to `Revise.add_callback(...)`.
See its docstring for details.
"""
function remove_callback(key)
    for cbs in values(user_callbacks_by_file)
        delete!(cbs, key)
    end
    delete!(user_callbacks_queue, key)
    delete!(user_callbacks_by_key, key)

    # possible future work: we may stop watching (some of) these files
    # now. But we don't really keep track of what background tasks are running
    # and Julia doesn't have an ergonomic way of task cancellation yet (see
    # e.g.
    #     https://github.com/JuliaLang/Juleps/blob/master/StructuredConcurrency.md
    # so we'll omit this for now. The downside is that in pathological cases,
    # this may exhaust inotify resources.

    nothing
end

function process_user_callbacks!(keys = user_callbacks_queue; throw::Bool=false)
    try
        # use (a)sync so any exceptions get nicely collected into CompositeException
        @sync for key in keys
            f = user_callbacks_by_key[key]
            @async Base.invokelatest(f)
        end
    catch err
        if throw
            rethrow(err)
        else
            @warn "[Revise] Ignoring callback errors" err
        end
    finally
        empty!(keys)
    end
end

"""
    entr(f, files; all=false, postpone=false, pause=0.02)
    entr(f, files, modules; all=false, postpone=false, pause=0.02)

Execute `f()` whenever files or directories listed in `files`, or code in `modules`, updates.
If `all` is `true`, also execute `f()` as soon as code updates are detected in
any module tracked by Revise.

`entr` will process updates (and block your command line) until you press Ctrl-C.
Unless `postpone` is `true`, `f()` will be executed also when calling `entr`,
regardless of file changes. The `pause` is the quiet period (in seconds) that
`entr` waits after the most recent change before calling `f()`; a cluster of
modifications less than `pause` apart — such as those produced by saving files
in certain text editors — therefore triggers only a single call.

# Example

```julia
entr(["/tmp/watched.txt"], [Pkg1, Pkg2]) do
    println("update")
end
```
This will print "update" every time `"/tmp/watched.txt"` or any of the code defining
`Pkg1` or `Pkg2` gets updated.
"""
function entr(f::Function, files, modules=nothing; all=false, postpone=false, pause=0.02)
    yield()
    postpone || f()
    # `entr` runs `f` on a trailing-edge debounce: a change schedules `f` for
    # `pause` seconds later, and any further change before then pushes the
    # deadline out. A burst of changes no more than `pause` apart therefore
    # collapses into a single `f()` call.
    lk = ReentrantLock()
    deadline = Ref(0.0)                          # `time()` at which `f` should next run; a past value means "nothing pending"
    dtask = Ref{Union{Task,Nothing}}(nothing)    # the in-flight debounce task, or `nothing`
    err = Ref{Any}(nothing)                      # an error from `f`, relayed to the loop below so it can rethrow
    stopped = Ref(false)
    function run_debounce()
        while true
            local remaining
            @lock lk begin
                remaining = deadline[] - time()
                # Decide to exit and clear `dtask` atomically, so a change
                # arriving now either extends this task or spawns a fresh one.
                remaining <= 0 && (dtask[] = nothing)
            end
            remaining <= 0 && break
            sleep(remaining)
        end
        stopped[] && return
        try
            Base.invokelatest(f)  # `f` typically calls code that `revise` just updated
        catch e
            err[] = e
            notify(revision_event)  # wake the loop below so it can rethrow
        end
        return
    end
    # The watch callback fires once per detected change and must return
    # promptly (it runs while `revise` holds `revision_queue_lock`), so it only
    # records a new deadline; the wait and `f()` happen in `run_debounce`. A
    # debounce task already counting down will see the bumped `deadline` and
    # extend itself, so spawn one only when `dtask` is empty. Pairing this with
    # the task clearing `dtask` as it commits to exit (both under `lk`) means a
    # change racing an expiring task either extends it or spawns its successor.
    key = add_callback(files, modules; all=all) do
        @lock lk begin
            deadline[] = time() + pause
            if dtask[] === nothing
                dtask[] = @async run_debounce()
            end
        end
    end
    try
        while true
            wait(revision_event)  # autoreset; see issue #837
            err[] === nothing || throw(err[])
            revise(throw=true)
            err[] === nothing || throw(err[])
        end
    catch e
        isa(e, InterruptException) || rethrow(e)
    finally
        stopped[] = true
        remove_callback(key)
    end
    nothing
end
