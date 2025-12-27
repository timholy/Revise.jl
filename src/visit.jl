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

collect_all_subtypes(@nospecialize(parent_typ::Type)) = _collect_all_subtypes!(parent_typ, Base.IdSet{Type}())

function _collect_all_subtypes!(@nospecialize(parent_typ::Type), types::Base.IdSet{Type})
    for Ty in InteractiveUtils.subtypes(parent_typ)
        if Ty in types
            continue
        else
            push!(types, Ty)
            _collect_all_subtypes!(Ty, types)
        end
    end
    return types
end

# TODO Use fixed sized FIFO cache?
const types_cache = IdDict{Type,Union{Nothing,Vector{Any}}}()
const types_cache_lock = ReentrantLock()

function old_types_with(oldtypename::Core.TypeName, alltypes::Base.IdSet{Type})
    related_types = nothing
    @lock types_cache_lock for type in alltypes
        if haskey(types_cache, type)
            types = types_cache[type]
        else
            nflds = Base.Compiler.fieldcount_noerror(type)
            if nflds !== nothing && nflds > 0
                types = collect(Any, fieldtypes(type))
            else
                types = nothing
            end
            types_cache[type] = types
        end
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
