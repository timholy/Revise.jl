# Limitations

Revise (really, Julia itself) can handle many kinds of code changes, but a few may require special treatment:

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

### Changes that Revise cannot handle

Finally, there are some kinds of changes that Revise cannot incorporate into a running Julia session:

- changes to type definitions
- file or module renames
- adding new source files to packages
- conflicts between variables and functions sharing the same name

These kinds of changes require that you restart your Julia session.
