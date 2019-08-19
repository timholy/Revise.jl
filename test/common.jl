using Random

const rseed = Ref(Random.GLOBAL_RNG)  # to get new random directories (see julia #24445)
if isempty(methods(Random.seed!, Tuple{typeof(rseed[])}))
    # Julia 1.3-rc1 doesn't have this, fixed in https://github.com/JuliaLang/julia/pull/32961
    Random.seed!(rng::typeof(rseed[])) = Random.seed!(rng, nothing)
end
function randtmp()
    Random.seed!(rseed[])
    dirname = joinpath(tempdir(), randstring(10))
    rseed[] = Random.GLOBAL_RNG
    dirname
end

@static if Sys.isapple()
    yry() = (sleep(1.1); revise(); sleep(1.1))
else
    yry() = (sleep(0.1); revise(); sleep(0.1))
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
