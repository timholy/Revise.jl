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
function yry()
    timedwait(() -> !isempty(Revise.revision_queue), event_timeout; pollint=0.02)
    sleep(0.02)
    revise()
    Revise.watching_files[] && sleep(mtimedelay)
end
macro yry()
    esc(quote
        yry()
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
