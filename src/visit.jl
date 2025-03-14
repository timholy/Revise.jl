function methods_with(@nospecialize(T::Type), world::UInt = Base.get_world_counter())
    methods = Method[]
    visited = Set{Module}()
    for mod in Base.loaded_modules_array()
        methods_with!(methods, T, world, mod, visited)
    end
    return methods
end

function methods_with!(methods, @nospecialize(T::Type), world, mod::Module, visited::Set{Module})
    mod in visited && return
    push!(visited, mod)
    # Traverse submodules
    for name in names(mod; all=true, imported=false)
        isdefined(mod, name) || continue
        obj = getglobal(mod, name)
        if isa(obj, Module)
            methods_with!(methods, T, world, obj, visited)
        end
    end
    Base.foreach_module_mtable(mod, world) do mt::Core.MethodTable
        for method in Base.MethodList(mt)
            hastype(method.sig, T) && push!(methods, method)
        end
        return true
    end
    return methods
end

function hastype(@nospecialize(S), @nospecialize(T))
    isa(S, Type) || return false
    S = Base.unwrap_unionall(S)
    isa(S, Core.TypeofBottom) && return false
    if isa(S, Union)
        return hastype(S.a, T) | hastype(S.b, T)
    end
    Base.isvarargtype(S) && return hastype(S.T, T)
    S === T && return true
    for P in S.parameters
        hastype(P, T) && return true
    end
    return false
end
