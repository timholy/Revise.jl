function traverse(predicate, action)
    visiting=Set{Module}()
    for mod in Base.loaded_modules_array()
        traverse(predicate, action, mod, visiting)
    end
    return nothing
end

function traverse(predicate, action, mod::Module, visiting=Set{Module}())
    push!(visiting, mod)
    for nm in names(mod; all=true)
        if isdefined(mod, nm)
            obj = getfield(mod, nm)
            if isa(obj, Module)
                obj in visiting && continue
                traverse(predicate, action, obj, visiting)
            else
                traverse(predicate, action, obj)
            end
        end
    end
    return nothing
end

function traverse(predicate, action, f::Function)
    Base.visit(methods(f).mt) do m
        traverse(predicate, action, m)
    end
    return nothing
end

function traverse(predicate, action, m::Method)
    # Look to see if the method is specialized for one of the types detected by predicate
    if predicate(m.sig)
        action(m)
        return true
    end
    # Determine whether any compiled specializations use one of the types
    for fn in (:specializations, :invokes)
        if isdefined(m, fn)
            spec = getfield(m, fn)
            if spec === nothing
            elseif isa(spec, Core.TypeMapEntry) || isa(spec, Core.TypeMapLevel)
                Base.visit(spec) do m
                    traverse(predicate, action, m)
                end
            else
                error("unhandled type ", typeof(spec))
            end
        end
    end
    return false
end

function traverse(predicate, action, mi::Core.MethodInstance)
    if isdefined(mi, :cache)
        traverse(predicate, action, mi.cache)
    end
    return nothing
end

function traverse(predicate, action, ci::Core.CodeInstance)
    inf = ci.inferred
    ret = predicate(ci.rettype)
    if !ret && isdefined(ci, :rettype_const)
        rt = ci.rettype_const
        if rt !== nothing
            if isa(rt, Type)
                ret |= predicate(rt)
            else
                ret |= predicate(typeof(rt))
            end
        end
    end
    if !ret
        ret = if isa(inf, Core.CodeInfo)
            predicate(inf)
        elseif isa(inf, Vector{UInt8})
            inf = Core.Compiler._uncompressed_ast(ci, inf)
            predicate(inf)
        elseif isa(inf, Nothing)
            false
        else
            error("unhandled type ", typeof(inf))
        end
    end
    if ret
        action(ci)
    end
    return ret
end

traverse(predicate, action, x) = nothing

## Code below here is used to define `predicate`

function typesmatch(types, src::Core.CodeInfo)
    vt = src.ssavaluetypes
    if isa(vt, Vector{Any})
        for typ in vt
            # performance hotspot, use manual dispatch
            ret = if isa(typ, TypeVar)
                typesmatch(types, typ)
            elseif isa(typ, Core.TypeofBottom)
                false
            elseif isa(typ, Union)
                typesmatch(types, typ)
            elseif isa(typ, UnionAll)
                typesmatch(types, Base.unwrap_unionall(typ))
            elseif isa(typ, DataType)
                typesmatch(types, typ)
            end
            ret && return true
        end
    end
    # Also check the code itself in case it's attempting to create the object
    # but it fails due to a TypeError or MethodError
    for stmt in src.code
        if isexpr(stmt, :call) && isa(stmt.args[1], Type)
            typesmatch(types, stmt.args[1]) && return true
        end
    end
    return false
end

function typesmatch(types, @nospecialize(typ::Type))
    typ = Base.unwrap_unionall(typ)
    typ === Union{} && return false
    if isa(typ, DataType)
        issubtype(typ, types) && return true
        for p in typ.parameters
            if isa(p, Type)
                p === Union{} && continue
                issubtype(p, types) && return true
            end
        end
    elseif isa(typ, Union)
        typesmatch(types, typ.a) && return true
        typesmatch(types, typ.b) && return true
    else
        error("unhandled type ", typeof(typ))
    end
    return false
end

function typesmatch(types, tv::TypeVar)
    typesmatch(types, tv.lb) && return true
    typesmatch(types, tv.ub) && return true
    return false
end

issubtype(@nospecialize(typ::Type), @nospecialize(T::Type)) = typ <: T
issubtype(@nospecialize(typ::Type), @nospecialize(tt::Tuple))          = any(T->issubtype(typ, T), tt)
issubtype(@nospecialize(typ::Type), @nospecialize(tv::AbstractVector)) = any(T->issubtype(typ, T), tt)
issubtype(@nospecialize(typ::Type), @nospecialize(ts::Base.IdSet))     = any(T->issubtype(typ, T), ts)
