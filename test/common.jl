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

@static if Sys.isapple()
    const mtimedelay = 3.1  # so the defining files are old enough not to trigger mtime criterion
else
    const mtimedelay = 0.1
end

yry() = (sleep(mtimedelay); revise(); sleep(mtimedelay))

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
