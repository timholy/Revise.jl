#     old_methods_with(oldtypename::Core.TypeName) -> Union{Nothing, Set{Method}}
#
# Find all methods whose signature references `oldtypename`.
#
# When a type is redefined, methods that reference the old type in their signature
# need to be re-evaluated. This function traverses the global method table and
# collects all methods that have `oldtypename` in any of their signature parameters.
#
# For example, if `OldType` is being redefined and there exists a method
# `foo(x::OldType)`, that method will be included in the returned set.
#
# See also [`old_types_with`](@ref).
function old_methods_with(oldtypename::Core.TypeName)
    meths = Ref{Union{Nothing,Set{Method}}}(nothing)
    methodtable = @static isdefinedglobal(Core, :methodtable) ? Core.methodtable : Core.GlobalMethods
    Base.visit(methodtable) do method
        sigt = Base.unwrap_unionall(method.sig)
        if sigt isa DataType
            for i = 1:length(sigt.parameters)
                if is_with_oldtypename(sigt.parameters[i], oldtypename)
                    if meths[] === nothing
                        meths[] = Set{Method}()
                    end
                    push!(meths[]::Set{Method}, method)
                    break
                end
            end
        end
    end
    return meths[]
end

function collect_all_subtypes(@nospecialize(parent_typ::Type))
    return _foreach_subtype!(Returns(nothing), parent_typ, Base.IdSet{Type}())
end

function foreach_subtype(f::Function, @nospecialize(parent_typ::Type))
    _foreach_subtype!(f, parent_typ, Base.IdSet{Type}())
    return nothing
end

function _foreach_subtype!(f::Function, @nospecialize(parent_typ::Type), types::Base.IdSet{Type})
    # TODO: for Ty in InteractiveUtils.subtypes(parent_typ; max_world=Base.tls_world_age())
    for Ty in InteractiveUtils.subtypes(parent_typ)
        if Ty in types
            continue
        else
            f(Ty)
            push!(types, Ty)
            _foreach_subtype!(f, Ty, types)
        end
    end
    return types
end

# TODO Use fixed sized FIFO cache?
const types_cache = IdDict{Type,Union{Nothing,Vector{Any}}}()
const types_cache_lock = ReentrantLock()

function fieldtypes_cached(@nospecialize(type))
    # This function is called from the cache thread during __init__ so we need the lock here
    @lock types_cache_lock begin
        # the equivalent `get!(types_cache, type) do ... end` form is not used because on 1.12 it triggers recompilation
        cache = get(types_cache, type, missing)
        cache !== missing && return cache
        types_cache[type] = ftypes = fieldtypes_array(type)
        return ftypes
    end
end

function fieldtypes_array(@nospecialize(type))
    nflds = Base.Compiler.fieldcount_noerror(type)
    if nflds !== nothing && nflds > 0
        ftypes = Vector{Any}(undef, nflds)
        for i in 1:nflds
            ftypes[i] = fieldtype(type, i)
        end
    else
        ftypes = nothing
    end
    return ftypes
end

#     old_types_with(oldtypename::Core.TypeName, alltypes::Base.IdSet{Type}) -> Union{Nothing, Base.IdSet{Type}}
#
# Find all types whose field types reference `oldtypename`.
#
# When a type is redefined, other types that use it as a field type also need to
# be re-evaluated. This function traverses all known types and collects those that
# have `oldtypename` in any of their field types.
#
# For example, if `Inner` is being redefined and there exists
# `struct Outer; x::Inner; end`, then `Outer` will be included in the returned set.
#
# See also [`old_methods_with`](@ref).
function old_types_with(oldtypename::Core.TypeName, alltypes::Base.IdSet{Type})
    related_types = nothing
    for type in alltypes
        types = fieldtypes_cached(type)
        if types !== nothing
            for ft in types
                if is_with_oldtypename(ft, oldtypename)
                    if related_types === nothing
                        related_types = Base.IdSet{Type}()
                    end
                    push!(related_types, type)
                    break
                end
            end
        end
    end
    return related_types
end

# Compute a structural fingerprint of a type for equality comparison ignoring
# `Core.TypeName` identity (i.e., without distinguishing two binding partitions
# of "the same" type definition). Returns `nothing` if the type cannot be
# fingerprinted (e.g., a partially-constructed `DataType` with no `super` set).
#
# `fieldtypes_arg`, when supplied, is a `svec` of field types used in place of
# `inner.types`. This handles the partial `DataType` produced by
# `Core._structtype` before `Core._typebody!` installs field types: at that
# point `inner.types` is undef, but the field-types `svec` is the third
# argument to the `_typebody!` call.
#
# The fingerprint is a `(typepart, scalarpart)` pair. `typepart` is a
# `Tuple`-type wrapped in the same `UnionAll` layers as the input, so type
# equality (`==`) handles `TypeVar` renaming. `scalarpart` carries
# mutability + name + module + field names, which `Tuple`-type equality
# cannot represent.
function type_fingerprint(@nospecialize(T::Type), fieldtypes_arg::Union{Nothing,Core.SimpleVector}=nothing)
    Tw = T
    inner = Base.unwrap_unionall(Tw)
    inner isa DataType || return nothing
    isdefined(inner, :super) || return nothing
    ftypes = fieldtypes_arg === nothing ? (isdefined(inner, :types) ? inner.types : nothing) : fieldtypes_arg
    ftypes === nothing && return nothing
    typepart = Tuple{inner.parameters..., ftypes..., inner.super}
    while Tw isa UnionAll
        typepart = UnionAll(Tw.var, typepart)
        Tw = Tw.body
    end
    scalarpart = (ismutabletype(inner), inner.name.module, inner.name.name, Tuple(inner.name.names))
    return (typepart, scalarpart)
end

# `structurally_equivalent(T1, T2, fieldtypes_1=nothing, fieldtypes_2=nothing) -> Bool`
#
# Return `true` if two types have the same structure: identical name + module,
# mutability, parameters, supertype, field names, and field types (modulo
# `TypeVar` renaming).
#
# Used by Revise to decide whether a struct revision would actually change the
# type. When the answer is `true`, the existing binding can be reused and the
# expensive subtype-tree walk in `handle_type_deletion!` can be skipped.
#
# `fieldtypes_1` / `fieldtypes_2` may be a `Core.SimpleVector` of field types
# to use in place of `T.types`. This is needed when comparing against the
# partial `DataType` produced by `Core._structtype` before `Core._typebody!`
# installs field types.
function structurally_equivalent(@nospecialize(T1::Type), @nospecialize(T2::Type),
                                 fieldtypes_1::Union{Nothing,Core.SimpleVector}=nothing,
                                 fieldtypes_2::Union{Nothing,Core.SimpleVector}=nothing)
    f1 = type_fingerprint(T1, fieldtypes_1)
    f1 === nothing && return false
    f2 = type_fingerprint(T2, fieldtypes_2)
    f2 === nothing && return false
    return f1 == f2
end

function is_with_oldtypename(@nospecialize(typlike), oldtypename::Core.TypeName)
    if typlike isa DataType
        typlike.name == oldtypename && return true
        for i = 1:length(typlike.parameters)
            if is_with_oldtypename(typlike.parameters[i], oldtypename)
                return true
            end
        end
    elseif typlike isa UnionAll
        return is_with_oldtypename(typlike.body, oldtypename)
    elseif typlike isa TypeVar
        return is_with_oldtypename(typlike.lb, oldtypename) || is_with_oldtypename(typlike.ub, oldtypename)
    end
    return false
end
