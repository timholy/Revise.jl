function old_methods_with(oldtypename::Core.TypeName)
    meths = Set{Method}()
    methodtable = @static isdefinedglobal(Core, :methodtable) ? Core.methodtable : Core.GlobalMethods
    Base.visit(methodtable) do method
        sigt = Base.unwrap_unionall(method.sig)
        if sigt isa DataType
            for i = 1:length(sigt.parameters)
                if is_with_oldtypename(sigt.parameters[i], oldtypename)
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

function old_types_with(oldtypename::Core.TypeName)
    alltypes = collect_all_subtypes(Any)
    types = IdSet{Type}()
    for type in alltypes
        nflds = Base.Compiler.fieldcount_noerror(type)
        if nflds !== nothing && nflds > 0
            for ft in fieldtypes(type)
                if is_with_oldtypename(ft, oldtypename)
                    push!(types, type)
                    break
                end
            end
        end
    end
    return types
end

function is_with_oldtypename(@nospecialize(ft), oldtypename::Core.TypeName)
    if ft isa DataType
        ft.name == oldtypename && return true
        for i = 1:length(ft.parameters)
            if is_with_oldtypename(ft.parameters[i], oldtypename)
                return true
            end
        end
    elseif ft isa UnionAll
        return is_with_oldtypename(ft.body, oldtypename)
    elseif ft isa TypeVar
        return is_with_oldtypename(ft.lb, oldtypename) || is_with_oldtypename(ft.ub, oldtypename)
    end
    return false
end
