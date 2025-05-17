struct FileInfo{Attrs}
    modexsigs::ModuleExprsSigs
    __attrs::Attrs
    FileInfo{Attrs}(modexsigs::ModuleExprsSigs, attrs::Attrs) where Attrs =
        new{Attrs}(modexsigs, attrs)
end

function Base.getproperty(fi::FileInfo, name::Symbol)
    if name == :modexsigs
        return getfield(fi, :modexsigs)
    elseif name == :__attrs
        return getfield(fi, :__attrs)
    else
        return getfield(getfield(fi, :__attrs), name)
    end
end
function Base.propertynames(::Type{FileInfo{Attrs}}) where Attrs
    return (:modexsigs, :__attrs, propertynames(Attrs)...)
end
function Base.setproperty!(fi::FileInfo, name::Symbol, value)
    if name == :__attrs
        setproperty!(getfield(fi, :__attrs), name, value)
    else
        error(lazy"invalid attribute name: $name")
    end
end

FileInfo{Attrs}(mod::Module, attrs::Attrs) where Attrs =
    FileInfo{Attrs}(ModuleExprsSigs(mod), attrs)

function FileInfo{Attrs}(modexsigs::ModuleExprsSigs, fi::FileInfo{Attrs}) where Attrs
    FileInfo{Attrs}(modexsigs, copy(fi.__attrs__))
end

function Base.show(io::IO, fi::FileInfo)
    print(io, "FileInfo(")
    for (mod, exsigs) in fi.modexsigs
        show(io, mod)
        print(io, "=>")
        show(io, exsigs)
        print(io, ", ")
    end
    show(io, fi.__attrs)
    print(io, ')')
end
