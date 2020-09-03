using Random
using Base.Meta: isexpr

const rseed = Ref(Random.GLOBAL_RNG)  # to get new random directories (see julia #24445)
if isempty(methods(Random.seed!, Tuple{typeof(rseed[])}))
    # Julia 1.3-rc1 doesn't have this, fixed in https://github.com/JuliaLang/julia/pull/32961
    Random.seed!(rng::typeof(rseed[])) = Random.seed!(rng, nothing)
end
function randtmp()
    Random.seed!(rseed[])
    dirname = joinpath(tempdir(), randstring(10))
    rseed[] = Random.GLOBAL_RNG
    return dirname
end

const to_remove = String[]

function newtestdir()
    testdir = randtmp()
    mkdir(testdir)
    push!(to_remove, testdir)
    push!(LOAD_PATH, testdir)
    return testdir
end

@static if Sys.isapple()
    const mtimedelay = 2.1  # so the defining files are old enough not to trigger mtime criterion
else
    const mtimedelay = 0.1
end

SP = VERSION >= v"1.6.0-DEV.771" ? " " : "" # JuliaLang/julia #37085

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

if isdefined(Core, :ReturnNode)
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
else
    function isreturning(stmt, val)
        isa(stmt, Expr) || return false
        stmt.head === :return || return false
        return stmt.args[1] == val
    end
    function isreturning_slot(stmt, val)
        isa(stmt, Expr) || return false
        stmt.head === :return || return false
        v = stmt.args[1]
        isa(v, Core.SlotNumber) || return false
        return v.id == val
    end
end

if !isempty(ARGS) && "REVISE_TESTS_WATCH_FILES" ∈ ARGS
    Revise.watching_files[] = true
    println("Running tests with `Revise.watching_files[] = true`")
    idx = findall(isequal("REVISE_TESTS_WATCH_FILES"), ARGS)
    deleteat!(ARGS, idx)
end
