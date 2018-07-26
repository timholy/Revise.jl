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

If you save the file, the next time you call `f(5)` from the REPL you will get 1,
and `methods(f)` will show a single method.
Revise even handles more complex situations, such as functions with default arguments: the
definition

```julia
defaultargs(x, y=0, z=1.0f0) = x + y + z
```

generates 3 different methods (with one, two, and three arguments respectively),
and editing this definition to

```julia
defaultargs(x, yz=(0,1.0f0)) = x + yz[1] + yz[2]
```

requires that we delete all 3 of the original methods and replace them with two new methods.

However, to find the right method(s) to delete, Revise needs to be able to parse source code
to extract the signature of the to-be-deleted method(s).
Unfortunately, a few valid constructs are quite difficult to parse properly.
For example, methods generated with code:

```julia
for T in (Int, Float64, String)   # edit this line to `for T in (Int, Float64)`
    @eval mytypeof(x::$T) = $T
end
```

will not disappear from the method lists until you restart.

!!! note

    To delete a method manually, you can use `m = @which foo(args...)` to obtain a method,
    and then call `Base.delete_method(m)`.

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
