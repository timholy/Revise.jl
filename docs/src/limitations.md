# Limitations

## Struct revision

### Struct revision  is supported on Julia 1.12+

Starting with Julia 1.12, Revise can handle changes to struct definitions. When you modify
a struct, Revise will automatically re-evaluate the struct definition and any methods or
types that depend on it. For example:

```julia
struct Inner
    value::Int
end

struct Outer
    inner::Inner
end

print_value(o::Outer) = println(o.inner.value)
```

If you change it to:

```julia
struct Inner
    value::Float64
    name::String
end
```

Revise will redefine `Inner`, and also re-evaluate `Outer` (which uses `Inner`
as a field type) and `print_value` (which references `Outer` in its signature).

On versions of Julia older than 1.12, Revise does not support changes to
`struct` definitions. These require you to restart your session.

### Workaround for the struct revision issue before Julia 1.12

On Julia versions prior to 1.12, struct definitions cannot be revised. During early stages of development, 
it's quite common to want to change type definitions. 
You can work around Julia's/Revise's limitations by temporary renaming. 
We'll illustrate this below, using `write` to be explicit about when updates to the file happen. 
But in ordinary usage, these are changes you'd likely make with your editor.

```julia-repl
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
       struct FooStruct2 <: AbstractFooStruct # change version number
           bar::Float64 # change type of the field
       end
       FooStruct = FooStruct2 # update alias reference
       function processFoo(foo::AbstractFooStruct)
           @info foo.bar
       end

       end
       """);

julia> FooStruct # make sure FooStruct refers to FooStruct2
MyPkg.FooStruct2

julia> processFoo(FooStruct(3.5))
[ Info: 3.5
```

Here, note that we made two changes: we updated the "version number" of FooStruct when we changed something about its fields, and we also re-assigned FooStruct to alias the new version. We did not change the definition of any methods that have been typed AbstractFooStruct.

This works as long as the new type name doesn't conflict with an existing name; within a session you need to change the name each time you change the definition.

Once your development has converged on a solution, it's best to switch to the "permanent" name: in the example above, `FooStruct` is a non-constant global variable, and if used internally in a function there will be consequent performance penalties. Switching to the permanent name will force you to restart your session.

```julia-repl
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
       """);

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

### Toplevel binding changes do not propagate

While struct revision is supported, some forms of "binding revision" do not work.
Specifically, Revise does not track implicit dependencies between top-level bindings.

For example:

```julia
MyVecType{T} = Vector{T}  # changing this to AbstractVector{T} won't update A
struct MyVec{T}
    v::MyVecType{T}
end
```

If you change `MyVecType{T}` from `Vector{T}` to `AbstractVector{T}`, the struct `A` will
**not** be automatically re-evaluated because Revise does not track the dependency edge
from `MyVecType` to `MyVec`. The same applies to `const` bindings and other global bindings
that are referenced in type definitions.

Supporting this would require tracking implicit binding edges across all
top-level code, which involves significant interpreter enhancements and may
never happen. See the related case of [code that depends on data](@ref data)
below.

As a workaround, you can manually call [`revise`](@ref) to force re-evaluation of all definitions in `MyModule`, which will pick up the new bindings.

## Other limitations

In addition, some situations may require special handling:

### [Macros and generated functions](@id other-limitations/macros-and-generated-functions)

If you change a macro definition or methods that get called by `@generated` functions
outside their `quote` block, these changes will not be propagated to functions that have
already evaluated the macro or generated function.

You may explicitly call `revise(MyModule)` to force reevaluating every definition in module
`MyModule`.
Note that when a macro changes, you have to revise all of the modules that *use* it.

### [Code that depends on data](@id data)

Revise does not track dependencies on "data." For example, if your source code
looks like

```julia
tf = true
if tf
    f() = 1
else
    f() = 2
end
```

and you change `tf` to `false`, Revise will not update the definition of `f`.
This is because there is no record of the fact that `f` depends on the value of `tf`.

This limitation does not affect code like this:

```julia
if true
    f() = 1
else
    f() = 2
end
```

In this case, changing `true` to `false` will redefine `f`, but only because
it's part of the same expression and Revise will re-evaluate the expression.

The maintainers have no intention of ever "fixing" this limitation, as it would
require adding enormous bloat to every session for very little actual benefit.

### [Code already running in a task (including `Threads.@spawn`)](@id world-age-tasks)

Revise installs revised methods as *new* definitions, which take effect in a new
[world age](https://docs.julialang.org/en/v1/manual/methods/#Redefining-Methods).
A task observes only the methods that existed when it *started running*: calls
made from within the task dispatch at the task's fixed world age. Consequently a
long-running task that began before you edited the source keeps executing the old
definitions, even though Revise has successfully installed the new ones.

This is most surprising with `Threads.@spawn` (or `@async`), because the REPL
returns to the prompt and everything *appears* up to date—a fresh call from the
REPL, or a newly spawned task, sees the revised code—while a background worker
silently keeps running the old code:

```julia
f() = 1
worker = Threads.@spawn while true
    @show f()      # keeps printing 1, even after `f` is revised to return 2
    sleep(1)
end
```

The same limitation can also surface as an outright error rather than silent
staleness. If a task pinned to an older world age dispatches a method or closure
that was *created* after the task started, Julia raises a world-age error like

```
MethodError: no method matching f()
The applicable method may be too new: running in world age 27916, while current world is 27952.
```

Examples that can trigger this include reactive or event-loop frameworks with
runner Tasks.

This is a consequence of Julia's world-age semantics, not something Revise can
change: Revise cannot retroactively advance the world age of a task that is
already running. There are two workarounds:

- restart the task after revising, so the new task picks up the current world age; or
- route the calls that should track revisions through
  [`Base.invokelatest`](https://docs.julialang.org/en/v1/base/base/#Base.invokelatest),
  which dispatches at the latest world age:

```julia
worker = Threads.@spawn while true
    @show Base.invokelatest(f)   # picks up revisions to `f`
    sleep(1)
end
```

The same caveat applies to any long-lived loop started before a revision,
including a `while true` loop running directly at the REPL; see also
[Editing code that defines REPL](@ref editREPL).

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

### `include(mapexpr, filename)` is not supported

Julia supports the ability to modify source code after parsing and before evaluation.
Supporting this is a TODO item but is not yet implemented.
