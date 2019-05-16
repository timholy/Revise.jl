# Debugging Revise

If Revise isn't behaving the way you expect it to, it can be useful to examine the
decisions it made.
Revise supports Julia's [Logging framework](https://docs.julialang.org/en/latest/stdlib/Logging/)
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
Revise.ReviseLogger(Revise.LogRecord[], Debug)
```
You'll use `rlogger` at the end to retrieve the logs.

Now carry out the series of julia commands and code edits that reproduces the problem.

## Capturing the logs and submitting them with your bug report

Once all the revisions have been triggered and the mistake has been reproduced,
it's time to capture the logs.
To capture all the logs, use

```julia
julia> using Base.CoreLogging: Debug

julia> logs = filter(r->r.level==Debug, rlogger.logs);
```

You can capture just the changes that Revise made to running code with

```julia
julia> logs = Revise.actions(rlogger)
```

You can either let these print to the console and copy/paste the text output into the
issue, or if they are extensive you can save `logs` to a file:

```julia
open("/tmp/revise.logs", "w") do io
    for log in logs
        println(io, log)
    end
end
```

Then you can upload the logs somewhere (e.g., https://gist.github.com/) and link the url in your bug report.
To assist in the resolution of the bug, please also specify additional relevant information such as the name of the function that was misbehaving after revision and/or any error messages that your received.

See also [A complete debugging demo](@ref) below.

## Logging by default

If you suspect a bug in Revise but have difficulty isolating it, you can include the lines

```julia
    # Turn on logging
    Revise.debug_logger()
```

within the `Revise` block of your `~/.julia/config/startup.jl` file.
This will ensure that you always log Revise's actions.
Then carry out your normal Julia development.
If a Revise-related problem arises, executing these lines

```julia
rlogger = Revise.debug_logger()
using Base.CoreLogging: Debug
logs = filter(r->r.level==Debug, rlogger.logs)
open("/tmp/revise.logs", "w") do io
    for log in logs
        println(io, log)
    end
end
```

within the same session will generate the `/tmp/revise.logs` file that
you can submit with your bug report.
(What makes this possible is that a second call to `Revise.debug_logger()` returns
the same logger object created by the first call--it is not necessary to hold
on to `rlogger`.)

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
may be distracting; by default [`Revise.actions`](@ref) excludes these events.

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
julia> rlogger.logs
9-element Array{Revise.LogRecord,1}:
 Revise.LogRecord(Debug, DeleteMethod, Action, Revise_4ac0f476, "/home/tim/.julia/dev/Revise/src/Revise.jl", 226, (time=1.557996459055345e9, deltainfo=(Tuple{typeof(Main.ReviseTest.cube),Any}, MethodSummary(:cube, :ReviseTest, Symbol("/tmp/revisetest.jl"), 7, Tuple{typeof(Main.ReviseTest.cube),Any}))))
 Revise.LogRecord(Debug, DeleteMethod, Action, Revise_4ac0f476, "/home/tim/.julia/dev/Revise/src/Revise.jl", 226, (time=1.557996459167895e9, deltainfo=(Tuple{typeof(Main.ReviseTest.Internal.mult3),Any}, MethodSummary(:mult3, :Internal, Symbol("/tmp/revisetest.jl"), 12, Tuple{typeof(Main.ReviseTest.Internal.mult3),Any}))))
 Revise.LogRecord(Debug, DeleteMethod, Action, Revise_4ac0f476, "/home/tim/.julia/dev/Revise/src/Revise.jl", 226, (time=1.557996459167956e9, deltainfo=(Tuple{typeof(Main.ReviseTest.Internal.mult4),Any}, MethodSummary(:mult4, :Internal, Symbol("/tmp/revisetest.jl"), 13, Tuple{typeof(Main.ReviseTest.Internal.mult4),Any}))))
 Revise.LogRecord(Debug, Eval, Action, Revise_9147188b, "/home/tim/.julia/dev/Revise/src/Revise.jl", 276, (time=1.557996459259605e9, deltainfo=(Main.ReviseTest, :(cube(x) = begin
          #= /tmp/revisetest.jl:7 =#
          x ^ 3
      end))))
 Revise.LogRecord(Debug, Eval, Action, Revise_9147188b, "/home/tim/.julia/dev/Revise/src/Revise.jl", 276, (time=1.557996459330512e9, deltainfo=(Main.ReviseTest, :(fourth(x) = begin
          #= /tmp/revisetest.jl:9 =#
          x ^ 4
      end))))
 Revise.LogRecord(Debug, LineOffset, Action, Revise_fb38a7f7, "/home/tim/.julia/dev/Revise/src/Revise.jl", 296, (time=1.557996459331061e9, deltainfo=(Any[Tuple{typeof(mult2),Any}], :(#= /tmp/revisetest.jl:11 =#) => :(#= /tmp/revisetest.jl:13 =#))))
 Revise.LogRecord(Debug, Eval, Action, Revise_9147188b, "/home/tim/.julia/dev/Revise/src/Revise.jl", 276, (time=1.557996459391182e9, deltainfo=(Main.ReviseTest.Internal, :(mult3(x) = begin
          #= /tmp/revisetest.jl:14 =#
          3x
      end))))
 Revise.LogRecord(Debug, LineOffset, Action, Revise_fb38a7f7, "/home/tim/.julia/dev/Revise/src/Revise.jl", 296, (time=1.557996459391642e9, deltainfo=(Any[Tuple{typeof(unchanged),Any}], :(#= /tmp/revisetest.jl:18 =#) => :(#= /tmp/revisetest.jl:19 =#))))
 Revise.LogRecord(Debug, LineOffset, Action, Revise_fb38a7f7, "/home/tim/.julia/dev/Revise/src/Revise.jl", 296, (time=1.557996459391695e9, deltainfo=(Any[Tuple{typeof(unchanged2),Any}], :(#= /tmp/revisetest.jl:20 =#) => :(#= /tmp/revisetest.jl:21 =#))))
```

You can see that Revise started by deleting three methods, followed by evaluating three new versions of those methods. Interspersed are various changes to the line numbering.

In rare cases it might be helpful to independently record the sequence of edits to the file.
You can make copies `cp editedfile.jl > /tmp/version1.jl`, edit code, `cp editedfile.jl > /tmp/version2.jl`,
etc.
`diff version1.jl version2.jl` can be used to capture a compact summary of the changes
and pasted into the bug report.
