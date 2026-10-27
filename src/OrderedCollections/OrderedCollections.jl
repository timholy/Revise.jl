# Vendored subset of OrderedCollections.jl v2.0.1 (`OrderedDict` only); see License.md in this directory.
# Vendoring avoids version conflicts with other packages' OrderedCollections in stacked environments.
module OrderedCollections

    import Base: convert, length, isempty, iterate, delete!,
                 empty!, getindex, setindex!, get, get!,
                 haskey, merge, copy, pop!, popfirst!,
                 sizehint!, last, getkey, mergewith, empty, in,
                 dict_with_eltype

    export OrderedDict

    include("dict_support.jl")
    include("ordered_dict.jl")
end
