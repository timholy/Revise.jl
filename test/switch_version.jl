using Revise, Pkg, Test

if isdefined(Core, :var"@latestworld")
    import Core: @latestworld
else
    # In older Julia versions, there were more implicit
    # world age increments, so the macro is generally not
    # required.
    macro latestworld()
        nothing
    end
end

mktempdir() do thisdir
    Pkg.activate(thisdir)

    Pkg.develop(path = joinpath(dirname(@__FILE__), "pkgs", "PkgChange_v1"))

    # This is only needed on Pkg versions that don't notify
    Revise.active_project_watcher()

    # Back to toplevel
    @eval begin
        using PkgChange
        @test_throws UndefVarError somemethod()   # not present in v1
        # From a different process, switch the active version of ExponentialUtilities
        v2_cmd = """using Pkg; Pkg.activate("."); Pkg.develop(path = joinpath("$(escape_string(dirname(@__FILE__)))", "pkgs", "PkgChange_v2"))"""
        t = @async run(pipeline(Cmd(`$(Base.julia_cmd()) -e $v2_cmd`; dir=$thisdir); stderr, stdout))
        isdefined(Base, :errormonitor) && Base.errormonitor(t)
        wait(Revise.revision_event)
        revise()
        @latestworld
        @test somemethod() === 1   # present in v2
        # ...and then switch back (check that it's bidirectional and also to reset state)
        v1_cmd = """using Pkg; Pkg.activate("."); Pkg.develop(path = joinpath("$(escape_string(dirname(@__FILE__)))", "pkgs", "PkgChange_v1"))"""
        t = @async run(pipeline(Cmd(`$(Base.julia_cmd()) -e $v1_cmd`; dir=$thisdir); stderr, stdout))
        isdefined(Base, :errormonitor) && Base.errormonitor(t)
        wait(Revise.revision_event)
        revise()
        @latestworld
        @test_throws MethodError somemethod() # not present in v1
    end
end
