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
