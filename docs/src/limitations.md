# Limitations

There are some kinds of changes that Revise (or often, Julia itself) cannot incorporate into a running Julia session:

- changes to type definitions or `const`s
- conflicts between variables and functions sharing the same name
- removal of `export`s

These kinds of changes require that you restart your Julia session.

During early stages of development, it's quite common to want to change type definitions. You can work around Julia's/Revise's limitations by temporary renaming:

```julia
# 1st version
struct FooStruct1
    bar::Int
end
FooStruct = FooStruct1
function processFoo(foo::FooStruct)
    @info foo.bar
end
```
and then the type can be updated like
```julia
# 2nd version
struct FooStruct2  # change version here
    bar::Int
    str::String
end
FooStruct = FooStruct2   # change version here
function processFoo(foo::FooStruct)  # no need to change this
    @info foo.bar
end
```
This works as long as the new type name doesn't conflict with an existing name; within a session you need to change the name each time you change the definition.

Once your development has converged on a solution, it's best to switch to the "permanent" name: in the example above, `FooStruct` is a non-constant global variable, and if used internally in a function there will be consequent performance penalties. Switching to the permanent name will force you to restart your session.

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
