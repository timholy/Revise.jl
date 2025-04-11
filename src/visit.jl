function methods_with(@nospecialize(T::Type), world::UInt = Base.get_world_counter())
    meths = Method[]
    visited = Set{Module}()
    for mod in Base.loaded_modules_array()
        methods_with!(meths, T, world, mod, visited)
    end
    # Also handle the methods defined for Type
    mt = methods(Type).mt
    T = Base.unwrap_unionall(T)
    Tname = T.name
    for method in Base.MethodList(mt)
        method.module === Tname.module && method.name === Tname.name && continue  # skip constructor
        hastype(method.sig, T) && push!(meths, method)
    end
    return meths
end

function methods_with!(meths, @nospecialize(T::Type), world, mod::Module, visited::Set{Module})
    mod in visited && return
    push!(visited, mod)
    # Traverse submodules
    for name in names(mod; all=true, imported=false)
        isdefined(mod, name) || continue
        obj = getglobal(mod, name)
        if isa(obj, Module)
            methods_with!(meths, T, world, obj, visited)
        end
    end
    Base.foreach_module_mtable(mod, world) do mt::Core.MethodTable
        for method in Base.MethodList(mt)
            hastype(method.sig, T) && push!(meths, method)
        end
        return true
    end
    return meths
end

function hastype(@nospecialize(S), @nospecialize(T))
    isa(S, TypeVar) && return hassubtype(S.ub, T)
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

function hassubtype(@nospecialize(S), @nospecialize(T))
    isa(S, TypeVar) && return hassubtype(S.ub, T)
    isa(S, Type) || return false
    S = Base.unwrap_unionall(S)
    isa(S, Core.TypeofBottom) && return false
    if isa(S, Union)
        return hassubtype(S.a, T) | hassubtype(S.b, T)
    end
    Base.isvarargtype(S) && return hassubtype(S.T, T)
    S <: T && return true
    for P in S.parameters
        hassubtype(P, T) && return true
    end
    return false
end
