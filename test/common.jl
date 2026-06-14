using Random
using Base.Meta: isexpr

# Testsets will reset the default RNG after each testset to make
# tests more reproducible, but we need to be able to create new random
# directories (see julia #24445)
const RNG = copy(Random.default_rng())
const to_remove = String[]

randtmp() = joinpath(tempdir(), randstring(RNG, 10))

function newtestdir()
    testdir = randtmp()
    mkdir(testdir)
    push!(to_remove, testdir)
    push!(LOAD_PATH, testdir)
    return testdir
end

# Spacing between successive writes to a tracked file, so that the watcher sees
# each edit as distinct. A file named in a filesystem event is settled by a
# content hash when its ctime is unchanged (see `scan_changed_files`), so this
# only needs to clear the resolution of `mtime`-based change detection on the
# polling/non-notifying path, where ext4 timestamps are fine-grained.
const mtimedelay = 0.1

# The suite assumes a deleted tracked file is processed at the first revise():
# `yry()` waits on `revision_queue` becoming non-empty, and several testsets
# assert on captured logs — a deletion deferred by `missing_file_grace` would
# keep stray entries queued (making the wait vacuous) and emit its warning
# inside whichever later testset crosses the grace boundary. The deferral
# itself is exercised by the "Missing-file grace" testset, which sets its own
# values.
Revise.missing_file_grace[] = 0.0

# Upper bound on how long `yry()` will wait for the file-watcher task to push
# the expected change onto `revision_queue`. Only paid by yry() calls that
# produce no revision (rare), so a generous value protects against slow
# FSEvents delivery on macOS CI without significantly affecting wall time.
const event_timeout = 10.0

if isdefined(Core, :var"@latestworld")
    using Core: @latestworld
else
    # In older Julia versions, there were more implicit
    # world age increments, so the macro is generally not
    # required.
    macro latestworld()
        nothing
    end
end

# Wait for a pending file change to be revised:
#   * the pre-revise wait is event-driven (block until the background watcher
#     task populates `Revise.revision_queue`), with `event_timeout` as a
#     fall-through for tests that legitimately produce no revision.
#   * a short settling pause lets a *burst* of writes that the watcher delivers
#     across more than one wakeup land in the queue before we revise.
#   * under `watching_files[]` (per-file and polling watches) a trailing pause
#     lets the one-shot `watch_file` re-arm before the next test write. That
#     path re-watches a single file after each revision and, unlike the
#     buffered per-directory watcher, has neither an event queue nor a content
#     hash to recover a write that lands while it is between watches.
#
# `expect_revision=true` (the default) means a write should already have been
# queued: hitting `event_timeout` then signals a dropped/late filesystem event,
# the usual cause of "revision not applied" CI flakes, so we warn. Tests that
# legitimately expect no revision pass `expect_revision=false` to take the
# timeout silently.
function yry(; expect_revision::Bool=true)
    status = timedwait(() -> !isempty(Revise.revision_queue), event_timeout; pollint=0.02)
    if expect_revision && status === :timed_out
        @warn "yry: timed out after $(event_timeout)s waiting for revision_queue; a filesystem event was likely dropped or delayed"
    end
    sleep(0.02)
    revise()
    # Drain to quiescence. The watcher can deliver a just-written edit's event
    # *after* this first revise (notably under macOS FSEvents latency): the first
    # revise then drains some earlier/stale queue entry while the edit we are
    # waiting for is still in flight, so a single revise would leave it unapplied
    # until a later `yry`. Keep revising as long as each pass clears something,
    # absorbing such stragglers within this call. Two stop conditions keep this
    # bounded: skip entirely once a revision errors (an errored file stays queued
    # for retry, and re-revising it would re-log and perturb error-reporting
    # tests), and stop on any pass that makes no progress (a missing file within
    # `missing_file_grace` is re-queued each pass, so the queue need not empty).
    if expect_revision
        for _ in 1:50   # hard cap; the conditions below are the normal exits
            isempty(Revise.queue_errors) || break
            timedwait(() -> !isempty(Revise.revision_queue), mtimedelay; pollint=0.02) === :ok || break
            n = length(Revise.revision_queue)
            revise()
            length(Revise.revision_queue) < n || break
        end
    end
    Revise.watching_files[] && sleep(mtimedelay)
end
macro yry(args...)
    # Forward `@yry(expect_revision=false)` as a keyword argument, not a positional one.
    kws = [a isa Expr && a.head === :(=) ? Expr(:kw, a.args[1], a.args[2]) : a for a in args]
    esc(quote
        yry($(kws...))
        @latestworld
    end)
end

function collectexprs(rex::Revise.RelocatableExpr)
    items = []
    for item in Revise.LineSkippingIterator(rex.ex.args)
        push!(items, isa(item, Expr) ? Revise.RelocatableExpr(item) : item)
    end
    items
end

# Test helpers, *not* Revise functions: each wraps `Revise.parse_and_maybe_eval_source[!]`, asserts
# the parse succeeded, and returns the resulting `ModuleExprsInfos`. Sharing one terse name keeps the
# many call sites readable and localizes the `ParseResult` unwrapping to this one spot.
function parse_source(file::AbstractString, mod::Module; kwargs...)
    pr = Revise.parse_and_maybe_eval_source(file, mod; kwargs...)
    pr.success || error("parsing $file produced no usable expressions")
    return pr.modexinfos
end
function parse_source!(mexs::Revise.ModuleExprsInfos, args...; kwargs...)
    pr = Revise.parse_and_maybe_eval_source!(mexs, args...; kwargs...)
    pr.success || error("parsing produced no usable expressions")
    return pr.modexinfos
end

function get_docstring(obj)
    while !isa(obj, AbstractString)
        fn = fieldnames(typeof(obj))
        if :content ∈ fn
            obj = obj.content[1]
        elseif :code ∈ fn
            obj = obj.code
        else
            error("unknown object ", obj)
        end
    end
    return obj
end

function get_code(f, typ)
    # Julia 1.5 introduces ":code_coverage_effect" exprs
    ci = code_typed(f, typ)[1].first
    code = copy(ci.code)
    while !isempty(code) && isexpr(code[1], :code_coverage_effect)
        popfirst!(code)
    end
    return code
end

function do_test(name)
    runtest = isempty(ARGS) || name in ARGS
    # Sometimes we get "no output received for 10 minutes" on CI,
    # to debug this it may be useful to know what test is being run.
    runtest && haskey(ENV, "CI") && println("Starting test ", name)
    return runtest
end

function rm_precompile(pkgname::AbstractString)
    filepath = Base.cache_file_entry(Base.PkgId(pkgname))
    isa(filepath, Tuple) && (filepath = filepath[1]*filepath[2])  # Julia 1.3+
    for depot in DEPOT_PATH
        fullpath = joinpath(depot, filepath)
        isfile(fullpath) && rm(fullpath)
    end
end

function isreturning(stmt, val)
    isa(stmt, Core.ReturnNode) || return false
    return stmt.val == val
end
function isreturning_slot(stmt, val)
    isa(stmt, Core.ReturnNode) || return false
    v = stmt.val
    isa(v, Core.SlotNumber) || isa(v, Core.Argument) || return false
    return (isa(v, Core.SlotNumber) ? v.id : v.n) == val
end

if !isempty(ARGS) && "REVISE_TESTS_WATCH_FILES" ∈ ARGS
    Revise.watching_files[] = true
    println("Running tests with `Revise.watching_files[] = true`")
    idx = findall(isequal("REVISE_TESTS_WATCH_FILES"), ARGS)
    deleteat!(ARGS, idx)
end

errmsg(err::Base.Meta.ParseError) = err.msg
errmsg(err::AbstractString) = err
