# These can be changed, to trade off better performance for space
const global maxallowedprobe = isdefined(Base, :maxallowedprobe) ? Base.maxallowedprobe : 16
const global maxprobeshift   = isdefined(Base, :maxprobeshift) ? Base.maxprobeshift : 6

"""
    OrderedDict

`OrderedDict`s are simply dictionaries whose entries have a particular order. The order
refers to insertion order, which allows deterministic iteration over the dictionary.
"""
mutable struct OrderedDict{K,V} <: AbstractDict{K,V}
    slots::Vector{Int32}
    keys::Vector{K}
    vals::Vector{V}
    live::Vector{Bool}
    ndel::Int
    maxprobe::Int
    dirty::Bool
    firstlive::Int
    lastlive::Int
end

function OrderedDict{K,V}() where {K,V}
    OrderedDict{K,V}(zeros(Int32,16), Vector{K}(), Vector{V}(), Vector{Bool}(), 0, 0, false, 1, 0)
end

function OrderedDict{K,V}(kv) where {K,V}
    h = OrderedDict{K,V}()
    for (k,v) in kv
        h[k] = v
    end
    return h
end

OrderedDict{K,V}(p::Pair) where {K,V} = setindex!(OrderedDict{K,V}(), p.second, p.first)

function OrderedDict{K,V}(ps::Pair...) where {K,V}
    h = OrderedDict{K,V}()
    sizehint!(h, length(ps))
    for p in ps
        h[p.first] = p.second
    end
    return h
end

function OrderedDict{K,V}(d::OrderedDict{K,V}) where {K,V}
    # Copy the representation verbatim (holes included) so copying never mutates `d`.
    OrderedDict{K,V}(copy(d.slots), copy(d.keys), copy(d.vals), copy(d.live), d.ndel, d.maxprobe, d.dirty, d.firstlive, d.lastlive)
end

OrderedDict() = OrderedDict{Any,Any}()
OrderedDict(kv::Tuple{}) = OrderedDict()
copy(d::OrderedDict) = OrderedDict(d)

# TODO: this can probably be simplified using `eltype` as a THT (Tim Holy trait)
# OrderedDict{K,V}(kv::Tuple{Vararg{Tuple{K,V}}})     = OrderedDict{K,V}(kv)
# OrderedDict{K  }(kv::Tuple{Vararg{Tuple{K,Any}}})   = OrderedDict{K,Any}(kv)
# OrderedDict{V  }(kv::Tuple{Vararg{Tuple{Any,V}}})   = OrderedDict{Any,V}(kv)
OrderedDict(kv::Tuple{Vararg{Pair{K,V}}}) where {K,V}  = OrderedDict{K,V}(kv)

OrderedDict(kv::AbstractArray{Tuple{K,V}}) where {K,V} = OrderedDict{K,V}(kv)
OrderedDict(kv::AbstractArray{Pair{K,V}}) where {K,V}  = OrderedDict{K,V}(kv)
OrderedDict(kv::AbstractDict{K,V}) where {K,V}         = OrderedDict{K,V}(kv)

OrderedDict(ps::Pair{K,V}...) where {K,V} = OrderedDict{K,V}(ps)
OrderedDict(ps::Pair...)                  = OrderedDict(ps)

@static if VERSION >= v"1.11"
    # see JuliaLang/julia#53151
    OrderedDict(kv) = dict_with_eltype((K, V) -> OrderedDict{K, V}, kv, eltype(kv))
else
    function OrderedDict(kv)
        try
            dict_with_eltype((K, V) -> OrderedDict{K, V}, kv, eltype(kv))
        catch e
            if isempty(methods(iterate, (typeof(kv),))) ||
                !all(x->isa(x, Union{Tuple,Pair}), kv)
                throw(ArgumentError("OrderedDict(kv): kv needs to be an iterator of tuples or pairs"))
            else
                rethrow(e)
            end
        end
    end
end

empty(d::OrderedDict{K,V}) where {K,V} = OrderedDict{K,V}()
empty(d::OrderedDict, ::Type{K}, ::Type{V}) where {K, V} = OrderedDict{K, V}()

length(d::OrderedDict) = length(d.keys) - d.ndel
isempty(d::OrderedDict) = (length(d) == 0)

"""
    isordered(::Type)

Property of associative containers, that is `true` if the container type has a
defined order (such as `OrderedDict` and `SortedDict`), and `false` otherwise.
"""
isordered(::Type{T}) where {T<:AbstractDict} = false
isordered(::Type{T}) where {T<:OrderedDict} = true

# conversion between OrderedDict types
function convert(::Type{OrderedDict{K,V}}, d::AbstractDict) where {K,V}
    d isa OrderedDict{K, V} && return d
    if !isordered(typeof(d))
        throw(ArgumentError("Cannot convert unordered `AbstractDict`s into `OrderedDicts`"))
    end
    h = OrderedDict{K,V}()
    for (k,v) in d
        ck = convert(K,k)
        if !haskey(h,ck)
            h[ck] = convert(V,v)
        else
            error("key collision during dictionary conversion")
        end
    end
    return h
end

isslotempty(slot_value::Integer) = slot_value == 0
isslotfilled(slot_value::Integer) = slot_value > 0
isslotmissing(slot_value::Integer) = slot_value < 0

function rehash!(h::OrderedDict{K,V}, newsz::Integer = length(h.slots)) where {K,V}
    keys = h.keys
    vals = h.vals
    newsz = _tablesz(newsz)
    h.dirty = true
    count0 = length(h)
    if count0 == 0
        resize!(h.slots, newsz)
        fill!(h.slots, 0)
        resize!(h.keys, 0)
        resize!(h.vals, 0)
        resize!(h.live, 0)
        h.ndel = 0
        h.firstlive = 1
        h.lastlive = 0
        return h
    end

    slots = zeros(Int32, newsz)
    maxprobe = 0

    if h.ndel > 0
        ndel0 = h.ndel
        to = 1
        # TODO: to get the best performance we need to avoid reallocating these.
        # This algorithm actually works in place, unless the dict is modified
        # due to GC during this process.
        newkeys = similar(keys, count0)
        newvals = similar(vals, count0)
        @inbounds for from = 1:length(keys)
            # `live` is the source of truth for which entries are deleted holes;
            # a live entry is always assigned, so reading `keys[from]` is safe.
            if h.live[from]
                k = keys[from]
                index0 = index = hashindex(k, newsz)
                while slots[index] != 0
                    index = (index & (newsz-1)) + 1
                end
                probe = (index - index0) & (newsz-1)
                probe > maxprobe && (maxprobe = probe)
                slots[index] = to
                newkeys[to] = k
                newvals[to] = vals[from]
                to += 1
            end
            if h.ndel != ndel0
                # if items are removed by finalizers, retry
                return rehash!(h, newsz)
            end
        end
        h.keys = newkeys
        h.vals = newvals
        resize!(h.live, length(newkeys))
        fill!(h.live, true)
        h.ndel = 0
    else
        @inbounds for i = 1:count0
            k = keys[i]
            index0 = index = hashindex(k, newsz)
            while slots[index] != 0
                index = (index & (newsz-1)) + 1
            end
            probe = (index - index0) & (newsz-1)
            probe > maxprobe && (maxprobe = probe)
            slots[index] = i
            if h.ndel > 0
                # if items are removed by finalizers, retry
                return rehash!(h, newsz)
            end
        end
    end

    h.slots = slots
    h.maxprobe = maxprobe
    # after compaction there are no holes
    h.firstlive = 1
    h.lastlive = length(h.keys)
    return h
end

function sizehint!(d::OrderedDict, newsz::Integer)
    slotsz = (newsz*3)>>1
    oldsz = length(d.slots)
    if slotsz <= oldsz
        # todo: shrink
        # be careful: rehash!() assumes everything fits. it was only designed
        # for growing.
        return d
    end
    # grow at least 25%
    slotsz = max(slotsz, (oldsz*5)>>2)
    rehash!(d, slotsz)
end

function empty!(h::OrderedDict{K,V}) where {K,V}
    fill!(h.slots, 0)
    empty!(h.keys)
    empty!(h.vals)
    empty!(h.live)
    h.ndel = 0
    h.firstlive = 1
    h.lastlive = 0
    h.dirty = true
    return h
end

# get the index where a key is stored, or -1 if not present
function ht_keyindex(h::OrderedDict{K,V}, key, direct) where {K,V}
    slots = h.slots
    sz = length(slots)
    iter = 0
    maxprobe = h.maxprobe
    index = hashindex(key, sz)
    keys = h.keys

    @inbounds while true
        si = slots[index]
        isslotempty(si) && break
        if isslotfilled(si) && isequal(key, keys[si])
            return ifelse(direct, oftype(index, si), index)
        end

        index = (index & (sz-1)) + 1
        iter += 1
        iter > maxprobe && break
    end

    return -1
end

# get the index where a key is stored, or -pos if not present
# and the key would be inserted at pos
# This version is for use by setindex! and get!
function ht_keyindex2(h::OrderedDict{K,V}, key) where {K,V}
    slots = h.slots
    sz = length(slots)
    iter = 0
    maxprobe = h.maxprobe
    index = hashindex(key, sz)
    keys = h.keys
    avail = 0

    @inbounds while true
        si = slots[index]
        if isslotempty(si)
            avail < 0 && return avail
            return -index
        end

        if isslotmissing(si)
            avail == 0 && (avail = -index)
        elseif key === keys[si] || isequal(key, keys[si])
            return oftype(index, si)
        end

        index = (index & (sz-1)) + 1
        iter += 1
        iter > maxprobe && break
    end

    avail < 0 && return avail

    # If key is not present, may need to keep searching to find slot
    maxallowed = max(maxallowedprobe, sz>>maxprobeshift)
    @inbounds while iter < maxallowed
        if !isslotfilled(slots[index])
            h.maxprobe = iter
            return -index
        end
        index = (index & (sz-1)) + 1
        iter += 1
    end

    rehash!(h, length(h) > 64000 ? sz*2 : sz*4)

    return ht_keyindex2(h, key)
end

function _setindex!(h::OrderedDict, v, key, index)
    hk, hv = h.keys, h.vals
    push!(hk, key)
    push!(hv, v)
    push!(h.live, true)
    nk = length(hk)
    @inbounds h.slots[index] = nk
    h.lastlive = nk
    h.dirty = true

    sz = length(h.slots)
    cnt = nk - h.ndel
    # Rehash now if necessary
    if h.ndel >= ((3*nk)>>2) > 4 || cnt*3 > sz*2
        # > 3/4 deleted or > 2/3 full
        rehash!(h, cnt > 64000 ? cnt*2 : cnt*4)
    end
end

function setindex!(h::OrderedDict{K,V}, v0, key0) where {K,V}
    key = convert(K, key0)
    if !isequal(key, key0)
        throw(ArgumentError("$key0 is not a valid key for type $K"))
    end
    v = convert(V, v0)

    index = ht_keyindex2(h, key)

    if index > 0
        @inbounds h.keys[index] = key
        @inbounds h.vals[index] = v
    else
        _setindex!(h, v, key, -index)
    end

    return h
end

function get!(h::OrderedDict{K,V}, key0, default) where {K,V}
    key = convert(K, key0)
    if !isequal(key, key0)
        throw(ArgumentError("$key0 is not a valid key for type $K"))
    end

    index = ht_keyindex2(h, key)

    index > 0 && return h.vals[index]

    v = convert(V,  default)
    _setindex!(h, v, key, -index)
    return v
end

function get!(default::Base.Callable, h::OrderedDict{K,V}, key0) where {K,V}
    key = convert(K, key0)
    if !isequal(key, key0)
        throw(ArgumentError("$key0 is not a valid key for type $K"))
    end

    index = ht_keyindex2(h, key)

    index > 0 && return h.vals[index]

    h.dirty = false
    v = convert(V,  default())
    if h.dirty  # calling default could have dirtied h
        index = ht_keyindex2(h, key)
    end
    if index > 0
        h.keys[index] = key
        h.vals[index] = v
    else
        _setindex!(h, v, key, -index)
    end
    return v
end

function getindex(h::OrderedDict{K,V}, key) where {K,V}
    index = ht_keyindex(h, key, true)
    return (index<0) ? throw(KeyError(key)) : h.vals[index]::V
end

function get(h::OrderedDict{K,V}, key, default) where {K,V}
    index = ht_keyindex(h, key, true)
    return (index<0) ? default : h.vals[index]::V
end

function get(default::Base.Callable, h::OrderedDict{K,V}, key) where {K,V}
    index = ht_keyindex(h, key, true)
    return (index<0) ? default() : h.vals[index]::V
end

haskey(h::OrderedDict, key) = (ht_keyindex(h, key, true) >= 0)
in(key, v::Base.KeySet{K,T}) where {K,T<:OrderedDict{K}} = (ht_keyindex(v.dict, key, true) >= 0)

function getkey(h::OrderedDict{K,V}, key, default) where {K,V}
    index = ht_keyindex(h, key, true)
    return (index<0) ? default : h.keys[index]::K
end

function _pop!(h::OrderedDict, index)
    @inbounds val = h.vals[h.slots[index]]
    _delete!(h, index)
    return val
end

function _lastlive(h::OrderedDict)
    i = h.lastlive
    @inbounds while i >= 1 && !h.live[i]
        i -= 1
    end
    return i
end
function _firstlive(h::OrderedDict)
    n = length(h.keys)
    i = h.firstlive
    @inbounds while i <= n && !h.live[i]
        i += 1
    end
    return i > n ? 0 : i
end

function pop!(h::OrderedDict)
    i = _lastlive(h)
    i == 0 && throw(ArgumentError("dict must be non-empty"))
    h.lastlive = i
    key = @inbounds h.keys[i]
    index = ht_keyindex(h, key, false)
    return key => _pop!(h, index)
end

function popfirst!(h::OrderedDict)
    i = _firstlive(h)
    i == 0 && throw(ArgumentError("dict must be non-empty"))
    h.firstlive = i
    key = @inbounds h.keys[i]
    index = ht_keyindex(h, key, false)
    return key => _pop!(h, index)
end

function pop!(h::OrderedDict, key)
    index = ht_keyindex(h, key, false)
    index > 0 ? _pop!(h, index) : throw(KeyError(key))
end

function pop!(h::OrderedDict, key, default)
    index = ht_keyindex(h, key, false)
    index > 0 ? _pop!(h, index) : default
end

function _delete!(h::OrderedDict, index)
    @inbounds ki = h.slots[index]
    @inbounds h.slots[index] = -ki
    @inbounds h.live[ki] = false
    @inbounds Base._unsetindex!(h.keys, Int(ki))
    @inbounds Base._unsetindex!(h.vals, Int(ki))
    h.ndel += 1
    h.dirty = true
    return h
end

function delete!(h::OrderedDict, key)
    index = ht_keyindex(h, key, false)
    if index > 0; _delete!(h, index); end
    return h
end

function iterate(t::OrderedDict{K,V}, i::Int = 1) where {K,V}
    n = length(t.keys)
    @inbounds while i <= n
        t.live[i] && return (Pair{K,V}(t.keys[i], t.vals[i]), i + 1)
        i += 1
    end
    return nothing
end

# lazy reverse iteration
function iterate(rt::Iterators.Reverse{<:OrderedDict{K,V}}, i::Int = length(rt.itr.keys)) where {K,V}
    t = rt.itr
    @inbounds while i >= 1
        t.live[i] && return (Pair{K,V}(t.keys[i], t.vals[i]), i - 1)
        i -= 1
    end
    return nothing
end


function _merge_kvtypes(d, others...)
    K, V = keytype(d), valtype(d)
    for other in others
        K = promote_type(K, keytype(other))
        V = promote_type(V, valtype(other))
    end
    return (K,V)
end

function merge(d::OrderedDict, others::AbstractDict...)
    K,V = _merge_kvtypes(d, others...)
    merge!(OrderedDict{K,V}(), d, others...)
end

function mergewith(combine, d::OrderedDict, others::AbstractDict...)
    K,V = _merge_kvtypes(d, others...)
    mergewith!(combine, OrderedDict{K,V}(), d, others...)
end

merge(combine::Function, d::OrderedDict, others::AbstractDict...) = mergewith(combine, d, others...)

function Base.map!(f, iter::Base.ValueIterator{<:OrderedDict})
    dict = iter.dict
    vals = dict.vals
    live = dict.live
    @inbounds for i in 1:length(vals)
        live[i] && (vals[i] = f(vals[i]))
    end
    return iter
end

function last(h::OrderedDict)
    i = _lastlive(h)
    i == 0 && throw(ArgumentError("collection must be non-empty"))
    @inbounds return h.keys[i] => h.vals[i]
end
