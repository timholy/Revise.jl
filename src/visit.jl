function methods_with(@nospecialize(T::Type))
    meths = Set{Method}()
    T = Base.unwrap_unionall(T)
    Tname = T.name
    methodtable = @static isdefinedglobal(Core, :methodtable) ? Core.methodtable : Core.GlobalMethods
    Base.visit(methodtable) do method
        # condition commented out due to https://github.com/timholy/Revise.jl/pull/894#issuecomment-3274102493
        # see the "MoreConstructors" test case in test/runtests.jl
        # if method.module !== Tname.module || method.name !== Tname.name  # skip constructor
            hastype(method.sig, T) && push!(meths, method)
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
