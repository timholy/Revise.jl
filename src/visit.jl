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

# Every type reachable as `subtypes(Any)` recursively is the
# canonical binding of some name in some loaded module. Enumerate them in a
# single pass over module bindings, rather than issuing one `subtypes` query per
# type: `subtypes(T)` rescans every loaded module's names on each call, so the
# recursive walk costs one full system-wide name scan per abstract parent
# (O(#abstract-types × #names)), whereas one binding sweep is O(#names).
function all_named_types(world::UInt=Base.get_world_counter())
    types = Base.IdSet{Type}()
    seen = Base.IdSet{Module}()
    work = Base.loaded_modules_array()
    while !isempty(work)
        m = pop!(work)
        m in seen && continue
        push!(seen, m)
        # `unsorted_names` skips the per-module name sort that `names` does; since
        #  the result is an unordered set, order is irrelevant here.
        for s in Base.unsorted_names(m; all=true)
            # Read bindings at `world` (the revision's pre-deletion snapshot). With Revise's own
            # dispatch pinned to its frozen init world (issue #552), a plain access would miss or
            # stale-read types defined or redefined after Revise initialized.
            (!Base.isdeprecated(m, s) && Base.invoke_in_world(world, isdefinedglobal, m, s)) || continue
            t = Base.invoke_in_world(world, getglobal, m, s)
            if t isa Type
                dt = Base.unwrap_unionall(t)
                # Keep only the canonical binding (a type's home module/name)
                # so re-exports and imports don't enter the set more than once.
                if dt isa DataType && dt.name.name === s && dt.name.module === m && t !== Any
                    push!(types, t)
                end
            elseif t isa Module && nameof(t) === s && parentmodule(t) === m && t !== m && t !== Base
                push!(work, t)
            end
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

function is_typeeq(@nospecialize(typlike))
    @static if isdefined(Core, :TypeEq)
        return typlike isa Core.TypeEq
    else
        return false
    end
end

function typeeq_parameter(@nospecialize(typlike))
    @static if isdefined(Base, :type_parameter)
        return Base.type_parameter(typlike)
    else
        return getfield(typlike, :T)
    end
end

function is_with_oldtypename(@nospecialize(typlike), oldtypename::Core.TypeName)
    if typlike isa DataType
        typlike.name == oldtypename && return true
        for i = 1:length(typlike.parameters)
            if is_with_oldtypename(typlike.parameters[i], oldtypename)
                return true
            end
        end
    elseif is_typeeq(typlike)
        return is_with_oldtypename(typeeq_parameter(typlike), oldtypename)
    elseif typlike isa UnionAll
        return is_with_oldtypename(typlike.body, oldtypename)
    elseif typlike isa Union
        return is_with_oldtypename(typlike.a, oldtypename) || is_with_oldtypename(typlike.b, oldtypename)
    elseif typlike isa TypeVar
        return is_with_oldtypename(typlike.lb, oldtypename) || is_with_oldtypename(typlike.ub, oldtypename)
    end
    return false
end
