# Limitations

Revise (really, Julia itself) can handle many kinds of code changes, but a few may require special treatment:

### Method deletion

Sometimes you might wish to change a method's type signature or number of arguments,
or remove a method specialized for specific types.
To prevent "stale" methods
from being called by dispatch, Revise automatically accommodates
method deletion, for example:

```julia
f(x) = 1
f(x::Int) = 2 # delete this method
```
If you save the file, the next time you call `f(5)` from the REPL you will get 1.

However, Revise needs to be able to parse the signature of the deleted method.
As a consequence, methods generated with code:
```julia
for T in (Int, Float64)
    @eval mytypeof(x::$T) = $T  # delete this line
end
```
will not disappear from the method lists until you restart, or manually call
`Base.delete_method(m::Method)`. You can use `m = @which ...` to obtain a method.

### Macros and generated functions

If you change a macro definition or methods that get called by `@generated` functions
outside their `quote` block, these changes will not be propagated to functions that have
already evaluated the macro or generated function.

You may explicitly call `revise(MyModule)` to force reevaluating every definition in module
`MyModule`.
Note that when a macro changes, you have to revise all of the modules that *use* it.

### Distributed computing (multiple workers)

Revise supports changes to code in worker processes.
The code must be loaded in the main process in which Revise is running, and you must use
`@everywhere using Revise`.

### Changes that Revise cannot handle

Finally, there are some kinds of changes that Revise cannot incorporate into a running Julia session:

- changes to type definitions
- file or module renames
- conflicts between variables and functions sharing the same name

These kinds of changes require that you restart your Julia session.
