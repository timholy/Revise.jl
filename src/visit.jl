function methods_with(@nospecialize(T::Type))
    meths = Set{Method}()
    T = Base.unwrap_unionall(T)
    Tname = T.name
    methodtable = @static isdefinedglobal(Core, :methodtable) ? Core.methodtable : Core.GlobalMethods
    Base.visit(methodtable) do method
        # condition commented out due to https://github.com/timholy/Revise.jl/pull/894#issuecomment-3274102493
        # see the "MoreConstructors" test case in test/runtests.jl
        # if method.module !== Tname.module || method.name !== Tname.name  # skip constructor
            if hastype(method.sig, T) || hastype_by_name(method.sig, Tname)
                push!(meths, method)
            end
        # end
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

# Check if a type signature S contains a reference to a type with the given TypeName
# This is useful for finding methods that reference old world-age versions of a type
function hastype_by_name(@nospecialize(S), Tname::Core.TypeName)
    isa(S, TypeVar) && return hastype_by_name(S.ub, Tname)
    isa(S, Type) || return false
    S_unwrapped = Base.unwrap_unionall(S)
    isa(S_unwrapped, Core.TypeofBottom) && return false
    if isa(S_unwrapped, Union)
        return hastype_by_name(S_unwrapped.a, Tname) | hastype_by_name(S_unwrapped.b, Tname)
    end
    Base.isvarargtype(S_unwrapped) && return hastype_by_name(S_unwrapped.T, Tname)
    if isa(S_unwrapped, DataType)
        # Compare TypeNames by their module and name, not by identity (===)
        # This is necessary because different world-age versions of a type have different TypeName objects
        if S_unwrapped.name.module === Tname.module && S_unwrapped.name.name === Tname.name
            return true
        end
        for P in S_unwrapped.parameters
            hastype_by_name(P, Tname) && return true
        end
    end
    return false
end
