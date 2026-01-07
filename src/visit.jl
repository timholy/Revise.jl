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
    meths = nothing
    methodtable = @static isdefinedglobal(Core, :methodtable) ? Core.methodtable : Core.GlobalMethods
    Base.visit(methodtable) do method
        sigt = Base.unwrap_unionall(method.sig)
        if sigt isa DataType
            for i = 1:length(sigt.parameters)
                if is_with_oldtypename(sigt.parameters[i], oldtypename)
                    if meths === nothing
                        meths = Set{Method}()
                    end
                    push!(meths, method)
                    break
                end
            end
        end
    end
    return meths
end

function collect_all_subtypes(@nospecialize(parent_typ::Type))
    return _foreach_subtype!(Returns(nothing), parent_typ, Base.IdSet{Type}())
end

function foreach_subtype(f::Function, @nospecialize(parent_typ::Type))
    _foreach_subtype!(f, parent_typ, Base.IdSet{Type}())
    return nothing
end

function _foreach_subtype!(f::Function, @nospecialize(parent_typ::Type), types::Base.IdSet{Type})
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
        return get!(types_cache, type) do
            nflds = Base.Compiler.fieldcount_noerror(type)
            if nflds !== nothing && nflds > 0
                ftypes = collect(Any, fieldtypes(type))
            else
                ftypes = nothing
            end
            ftypes
        end
    end
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
