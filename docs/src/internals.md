# How Revise works

Revise is based on the fact that you can change functions even when
they are defined in other modules.
Here's an example showing how you do that manually (without using Revise):

```julia
julia> convert(Float64, π)
3.141592653589793

julia> # That's too hard, let's make life easier for students

julia> @eval Base convert(::Type{Float64}, x::Irrational{:π}) = 3.0
convert (generic function with 714 methods)

julia> convert(Float64, π)
3.0
```

Revise removes some of the tedium of manually copying and pasting code
into `@eval` statements.
To decrease the amount of re-JITting
required, Revise avoids reloading entire modules; instead, it takes care
to `eval` only the *changes* in your package(s), much as you would if you were
doing it manually.
Importantly, changes are detected in a manner that is independent of the specific
line numbers in your code, so that you don't have to re-evaluate just
because code moves around within the same file.
(However, one unfortunate side effect is that
[line numbers may become inaccurate in backtraces](https://github.com/timholy/Revise.jl/issues/51).)

To accomplish this, Revise uses the following overall strategy:

- add callbacks to Base so that Revise gets notified when new
  packages are loaded or new files `include`d
- prepare source-code caches for every new file. These caches
  will allow Revise to detect changes when files are updated. For precompiled
  packages this happens on an as-needed basis, using the cached
  source in the `*.ji` file. For non-precompiled packages, Revise parses
  the source for each `include`d file immediately so that the initial state is
  known and changes can be detected.
- monitor the file system for changes to any of the dependent files;
  it immediately appends any updates to a list of file names that need future
  processing
- intercept the REPL's backend to ensure that the list of
  files-to-be-revised gets processed each time you execute a new
  command at the REPL
- when a revision is triggered, the source file(s) are re-parsed, and
  a diff between the cached version and the new version is
  created. `eval` the diff in the appropriate module(s).
- replace the cached version of each source file with the new version, so that
  further changes are `diff`ed against the most recent update.

## The structure of Revise's internal representation

Revise bridges between text files (your source code) and compiled code.
Revise consequently maintains data structures that parallel Julia's own internal
processing of code.
When dealing with a source-code file, you start with strings, parse them to obtain Julia
expressions, evaluate them to obtain Julia objects, and (where appropriate,
e.g., for methods) compile them to machine code.
This will be called the *forward workflow*.
Revise sets up a few key structures that allow it to progress from files to modules
to Julia expressions and types.

Revise also sets up a *backward workflow*, proceeding from compiled code to Julia
types back to Julia expressions.
This workflow is useful, for example, when dealing with errors: the stack traces
displayed by Julia link from the compiled code back to the source files.
To make this possible, Julia builds "breadcrumbs" into compiled code that store the
filename and line number at which each expression was found.
However, these links are static, meaning they are set up once (when the code is compiled)
and are not updated when the source file changes.
Because trivial manipulations to source files (e.g., the insertion of blank lines
and/or comments) can change the line number of an expression without necessitating
its recompilation, Revise implements a way of correcting these line numbers before
they are displayed to the user.
This capability requires that Revise proceed backward from the compiled objects to
something resembling the original text file.

### Terminology

A few convenience terms are used throughout: *definition*,
*signature-expression*, and *signature-type*.
These terms are illustrated using the following example:

```@raw html
<p><pre><code class="language-julia">function <mark>print_item(io::IO, item, ntimes::Integer=1, pre::String="")</mark>
    print(io, pre)
    for i = 1:ntimes
        print(io, item)
    end
end</code></pre></p>
```

This represents the *definition* of a method.
Definitions are stored as expressions, using a [`Revise.RelocatableExpr`](@ref).
The highlighted portion is the *signature-expression*, specifying the name, argument names
and their types, and (if applicable) type-parameters of the method.

From the signature-expression we can generate one or more *signature-types*.
Since this function has two default arguments, this signature-expression generates
three signature-types, each corresponding to a different valid way of calling
this method:

```julia
Tuple{typeof(print_item),IO,Any}                    # print_item(io, item)
Tuple{typeof(print_item),IO,Any,Integer}            # print_item(io, item, 2)
Tuple{typeof(print_item),IO,Any,Integer,String}     # print_item(io, item, 2, "  ")
```

In Revise's internal code, a definition is often represented with a variable `def`,
a signature-expression with `sigex`, and a signature-type with `sigt`.

### Core data structures and representations

Two "maps" are central to Revise's inner workings: the `DefMap` links
definition=>signature-types (the forward workflow), while the `SigtMap` links from
signature-type=>definition (the backward workflow).
Concretely, `SigtMap` is just a `Dict` mapping `sigt=>def`.
Of note, a stack frame typically contains a link to a method, which stores the equivalent
of `sigt`; consequently, this information allows one to look up the corresponding `def`.

The `DefMap` is a bit more complex and has important constraints:

- For expressions that do not define a method, it is just `def=>nothing`
- For expressions that do define a method, it is `def=>([sigt1, ...], lineoffset)`.
  `[sigt1, ...]` is the list of signature-types generated from `def` (often just one,
  but more in the case of methods with default arguments).
  `lineoffset` is the correction to be added to the currently-compiled code's internal
  line numbers needed to make them match the current state of the source file.
- `DefMap` is represented as an `OrderedDict` so as to preserve the sequence in which expressions
  occur in the file.
  This can be important particularly for updating macro definitions, which affect the
  expansion of later code.
  The order is maintained so as to match the current ordering of the source-file,
  which is not necessarily the same as the ordering when these expressions were last
  `eval`ed.
- Each key in the `DefMap` (the definition `RelocatableExpr`) is the most recently
  `eval`ed version of the expression.
  This has an important consequence: the line numbers in the `def` (which are still present,
  even though not used for equality comparisons) correspond to the ones in compiled code.
  If the file is parsed again, comparing the line numbers embedded in two "equal" `def`
  exprs (the original and the new one) allows us to accurately determine the current value
  of `lineoffset`.

Importantly, modules can be "reconstructed" from the keys of `DefMap` (or collection of
`DefMaps`, if the module involves multiple files or has sub-modules), since they hold
the complete ordered set of expressions that would be `eval`ed to define the module.

The `DefMap` and `SigtMap` are grouped in a [`Revise.FMMaps`](@ref), which are then
organized by the file in which they occur and their module
of evaluation.

### An example

Consider a module, `Items`, defined by the following two source files:

`Items.jl`:

```julia
__precompile__(false)

module Items

include("indents.jl")

function print_item(io::IO, item, ntimes::Integer=1, pre::String=indent(item))
    print(io, pre)
    for i = 1:ntimes
        print(io, item)
    end
end

end
```

`indents.jl`:

```julia
indent(::UInt16) = 2
indent(::UInt8)  = 4
```

`indents.jl` is particularly simple: Revise represents it as `"indents.jl"=>Dict(Items=>fmm1)`,
specifying the filename, module(s) into which its code is `eval`ed, and corresponding `FMMaps`.
Because `indents.jl` only contains code from a single module (`Items`), the `Dict` has just
one entry.
`fmm1` looks like this:

```julia
fmm1 = FMMaps(DefMap(:(indent(::UInt16) = 2) => ([Tuple{typeof(indent),UInt16}], 0),
                     :(indent(::UInt8) = 4)  => ([Tuple{typeof(indent),UInt8}], 0)
                     ),
              SigtMap(Tuple{typeof(indent),UInt16} => :(indent(::UInt16) = 2),
                      Tuple{typeof(indent),UInt8}  => :(indent(::UInt8) = 4)
                      ))
```
The `lineoffset`s are initially set to 0 when the code is first compiled, but these
may be updated if the source file is changed.

`Items.jl` is represented with a bit more complexity,
`"Items.jl"=>Dict(Main=>fmm2, Main.Items=>fmm3)`.
This is because `Items.jl` contains one expression (the `__precompile__` statement)
that is `eval`ed in `Main`,
and other expressions that are `eval`ed in `Items`.
Concretely,

```julia
fmm2 = FMMaps(DefMap(:(__precompile__(false)) => nothing),
              SigtMap())
fmm3 = FMMaps(DefMap(:(include("indents.jl")) => nothing,
                     def => ([Tuple{typeof(print_item),IO,Any},
                              Tuple{typeof(print_item),IO,Any,Integer},
                              Tuple{typeof(print_item),IO,Any,Integer,String}], 0)),
              SigtMap(Tuple{typeof(print_item),IO,Any} => def,
                      Tuple{typeof(print_item),IO,Any,Integer} => def,
                      Tuple{typeof(print_item),IO,Any,Integer,String} => def))
```

where here `def` is the expression defining `print_item`.

### Revisions and computing diffs

When the file system notifies Revise that a file has been modified, Revise re-parses
the file and assigns the expressions to the appropriate modules, creating a
[`Revise.FileModules`](@ref) `fmnew`.
It then compares `fmnew` against `fmref`, the reference object that is synchronized to
code as it was `eval`ed.
The following actions are taken:

- if a `def` entry in `fmref` is equal to one `fmnew`, the expression is "unchanged"
  except possibly for line number. The `lineoffset` in `fmref` is updated as needed.
- if a `def` entry in `fmref` is not present in `fmnew`, that entry is deleted and
  any corresponding methods are also deleted.
- if a `def` entry in `fmnew` is not present in `fmref`, it is `eval`ed and then added to
  `fmref`.

Technically, a new `fmref` is generated every time to ensure that the expressions are
ordered as in `fmnew`; however, conceptually this is better thought of as an updating of
`fmref`, after which `fmnew` is discarded.

### Internal API

You can find more detail about Revise's inner workings in the [Developer reference](@ref).
