# Debugging Revise

If Revise isn't behaving the way you expect it to, it can be useful to examine the
decisions it made.
Revise supports Julia's [Logging framework](https://docs.julialang.org/en/stable/stdlib/Logging/)
and can optionally record its decisions in a format suitable for later inspection.
What follows is a simple series of steps you can use to turn on logging, capture messages,
and then submit them with a bug report.
Alternatively, more advanced developers may want to examine the logs themselves to determine
the source of Revise's error, and for such users a few tips about interpreting the log
messages are also provided below.

## Turning on logging

Currently, the best way to turn on logging is within a running Julia session:

```jldoctest; setup=(using Revise)
julia> rlogger = Revise.debug_logger()
Test.TestLogger(Test.LogRecord[], Debug, false, nothing)
```
Hold on to `rlogger`; you're going to use it at the end to retrieve the logs.

!!! note

    This replaces the global logger; in rare circumstances this may have consequences for other code.

Now carry out the series of julia commands and code edits that reproduces the problem.

## Capturing the logs and submitting them with your bug report

Once all the revisions have been triggered and the mistake has been reproduced,
it's time to capture the logs:

```julia
julia> logs = filter(r->r.level==Debug && r._module==Revise, rlogger.logs);
```

You can either let these print to the console and copy/paste the text output into the
issue, or if they are extensive you can save `logs` to a file (e.g., in JLD2 format)
and upload the file somewhere.

See also [A complete debugging demo](@ref) below.

## The structure of the logs

For those who want to do a little investigating on their own, it may be helpful to
know that Revise's core decisions are captured in the group called "Action," and they come in three
flavors:

- log entries with message `"Eval"` signify a call to `eval`; for these events,
  keyword `:deltainfo` has value `(mod, expr)` where `mod` is the module of evaluation
  and `expr` is a [`Revise.RelocatableExpr`](@ref) containing the expression
  that was evaluated.
- log entries with message `"DeleteMethod"` signify a method deletion; for these events,
  keyword `:deltainfo` has value `(sigt, methsummary)` where `sigt` is the signature of the
  method that Revise *intended* to delete and `methsummary` is a [`MethodSummary`](@ref) of the
  method that Revise actually found to delete.
- log entries with message `"LineOffset"` correspond to updates to Revise's own internal
  estimates of how far a given method has become displaced from the line number it
  occupied when it was last evaluated. For these events, `:deltainfo` has value
  `(sigt, newlineno, oldoffset=>newoffset)`.

If you're debugging mistakes in method creation/deletion, the `"LineOffset"` events
may be distracting; you can remove them by additionally filtering on
`r.message ∈ ("Eval", "DeleteMethod")`.

Note that Revise records the time of each revision, which can sometimes be useful in
determining which revisions occur in conjunction with which user actions.
If you want to make use of this, it can be handy to capture the start time with `tstart = time()`
before commencing on a session.

See [`Revise.debug_logger`](@ref) for information on groups besides "Action."

## A complete debugging demo

From within Revise's `test/` directory, try the following:

```julia
julia> rlogger = Revise.debug_logger();

shell> cp revisetest.jl /tmp/

julia> includet("/tmp/revisetest.jl")

julia> ReviseTest.cube(3)
81

shell> cp revisetest_revised.jl /tmp/revisetest.jl

julia> ReviseTest.cube(3)
27

julia> rlogger.logs
5-element Array{Test.LogRecord,1}:
 Test.LogRecord(Debug, "Eval", Revise, "Action", :Revise_443cc0b6, "/home/tim/.julia/dev/Revise/src/Revise.jl", 266, Base.Iterators.Pairs{Symbol,Any,Tuple{Symbol,Symbol},NamedTuple{(:time, :deltainfo),Tuple{Float64,Tuple{Module,Revise.RelocatableExpr}}}}(:time=>1.5347e9,:deltainfo=>(Main.ReviseTest, :(cube(x) = begin
          x ^ 3
      end))))
 Test.LogRecord(Debug, "Eval", Revise, "Action", :Revise_443cc0b7, "/home/tim/.julia/dev/Revise/src/Revise.jl", 266, Base.Iterators.Pairs{Symbol,Any,Tuple{Symbol,Symbol},NamedTuple{(:time, :deltainfo),Tuple{Float64,Tuple{Module,Revise.RelocatableExpr}}}}(:time=>1.5347e9,:deltainfo=>(Main.ReviseTest, :(fourth(x) = begin
          x ^ 4
      end))))
 Test.LogRecord(Debug, "LineOffset", Revise, "Action", :Revise_3e9f6659, "/home/tim/.julia/dev/Revise/src/Revise.jl", 226, Base.Iterators.Pairs{Symbol,Any,Tuple{Symbol,Symbol},NamedTuple{(:time, :deltainfo),Tuple{Float64,Tuple{Array{Any,1},Int64,Pair{Int64,Int64}}}}}(:time=>1.5347e9,:deltainfo=>(Any[Tuple{typeof(mult2),Any}], 13, 0=>2)))
 Test.LogRecord(Debug, "Eval", Revise, "Action", :Revise_443cc0b8, "/home/tim/.julia/dev/Revise/src/Revise.jl", 266, Base.Iterators.Pairs{Symbol,Any,Tuple{Symbol,Symbol},NamedTuple{(:time, :deltainfo),Tuple{Float64,Tuple{Module,Revise.RelocatableExpr}}}}(:time=>1.5347e9,:deltainfo=>(Main.ReviseTest.Internal, :(mult3(x) = begin
          3x
      end))))
 Test.LogRecord(Debug, "DeleteMethod", Revise, "Action", :Revise_04f4de6f, "/home/tim/.julia/dev/Revise/src/Revise.jl", 248, Base.Iterators.Pairs{Symbol,Any,Tuple{Symbol,Symbol},NamedTuple{(:time, :deltainfo),Tuple{Float64,Tuple{DataType,MethodSummary}}}}(:time=>1.5347e9,:deltainfo=>(Tuple{typeof(mult4),Any}, MethodSummary(:mult4, :Internal, Symbol("/tmp/revisetest.jl"), 13, Tuple{typeof(mult4),Any}))))
```

Note that in some cases it can also be helpful to independently record the sequence of edits to the file.
You can make copies `cp editedfile.jl > /tmp/version1.jl`, edit code, `cp editedfile.jl > /tmp/version2.jl`,
etc.
`diff version1.jl version2.jl` can be used to capture a compact summary of the changes
and pasted into the bug report.
