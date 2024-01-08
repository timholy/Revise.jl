# Limitations

There are some kinds of changes that Revise (or often, Julia itself) cannot incorporate into a running Julia session:

- changes to type definitions or `const`s
- conflicts between variables and functions sharing the same name
- removal of `export`s

These kinds of changes require that you restart your Julia session.

During early stages of development, it's quite common to want to change type definitions. You can work around Julia's/Revise's limitations by temporary renaming. We'll illustrate this below, using `write` to be explicit about when updates to the file happen. But in ordinary usage, these are changes you'd likely make with your editor.

```julia
julia> using Pkg, Revise

julia> Pkg.generate("MyPkg")
  Generating  project MyPkg:
    MyPkg/Project.toml
    MyPkg/src/MyPkg.jl
Dict{String, Base.UUID} with 1 entry:
  "MyPkg" => UUID("69940cda-0c72-4a1a-ae0b-fd3109336fe8")

julia> cd("MyPkg")

julia> write("src/MyPkg.jl","""
       module MyPkg

       export FooStruct, processFoo

       abstract type AbstractFooStruct end
       struct FooStruct1 <: AbstractFooStruct
           bar::Int
       end
       FooStruct = FooStruct1
       function processFoo(foo::AbstractFooStruct)
           @info foo.bar
       end

       end
       """)
230

julia> Pkg.activate(".")
  Activating project at `~/blah/MyPkg`

julia> using MyPkg
  No Changes to `~/blah/MyPkg/Project.toml`
  No Changes to `~/blah/MyPkg/Manifest.toml`
Precompiling MyPkg
  1 dependency successfully precompiled in 2 seconds

julia> processFoo(FooStruct(1))
[ Info: 1

julia> write("src/MyPkg.jl","""
       module MyPkg

       export FooStruct, processFoo

       abstract type AbstractFooStruct end
       struct FooStruct2 <: AbstractFooStruct # change version nuumber
           bar::Float64 # change type of the field
       end
       FooStruct = FooStruct2 # update alias reference
       function processFoo(foo::AbstractFooStruct)
           @info foo.bar
       end

       end
       """)
234

julia> FooStruct # make sure FooStruct refers to FooStruct2
MyPkg.FooStruct2

julia> processFoo(FooStruct(3.5))
[ Info: 3.5
```

Here, note that we made two changes: we updated the "version number" of FooStruct when we changed something about its fields, and we also re-assigned FooStruct to alias the new version. We did not change the definition of any methods that have been typed AbstractFooStruct.

This works as long as the new type name doesn't conflict with an existing name; within a session you need to change the name each time you change the definition.

Once your development has converged on a solution, it's best to switch to the "permanent" name: in the example above, `FooStruct` is a non-constant global variable, and if used internally in a function there will be consequent performance penalties. Switching to the permanent name will force you to restart your session.

```julia
julia> isconst(MyPkg, :FooStruct)
true

julia> write("src/MyPkg.jl","""
       module MyPkg

       export FooStruct, processFoo

       abstract type AbstractFooStruct end # this could be removed
       struct FooStruct <: AbstractFooStruct # change to just FooStruct
           bar::Float64
       end

       function processFoo(foo::AbstractFooStruct) # consider changing to FooStruct
           @info foo.bar
       end

       end
       """)

julia> run(Base.julia_cmd()) # start a new Julia session, alternatively exit() and restart julia


julia> using Pkg, Revise # NEW Julia Session

julia> Pkg.activate(".")
  Activating project at `~/blah/MyPkg`

julia> using MyPkg
Precompiling MyPkg
  1 dependency successfully precompiled in 2 seconds

julia> isconst(MyPkg, :FooStruct)
true

```

In addition, some situations may require special handling:

### Macros and generated functions

If you change a macro definition or methods that get called by `@generated` functions
outside their `quote` block, these changes will not be propagated to functions that have
already evaluated the macro or generated function.

You may explicitly call `revise(MyModule)` to force reevaluating every definition in module
`MyModule`.
Note that when a macro changes, you have to revise all of the modules that *use* it.

### Distributed computing (multiple workers) and anonymous functions

Revise supports changes to code in worker processes.
The code must be loaded in the main process in which Revise is running.

Revise cannot handle changes in anonymous functions used in `remotecall`s.
Consider the following module definition:

```julia
module ParReviseExample
using Distributed

greet(x) = println("Hello, ", x)

foo() = for p in workers()
    remotecall_fetch(() -> greet("Bar"), p)
end

end # module
```

Changing the remotecall to `remotecall_fetch((x) -> greet("Bar"), p, 1)` will fail,
because the new anonymous function is not defined on all workers.
The workaround is to write the code to use named functions, e.g.,

```julia
module ParReviseExample
using Distributed

greet(x) = println("Hello, ", x)
greetcaller() = greet("Bar")

foo() = for p in workers()
    remotecall_fetch(greetcaller, p)
end

end # module
```

and the corresponding edit to the code would be to modify it to `greetcaller(x) = greet("Bar")`
and `remotecall_fetch(greetcaller, p, 1)`.
