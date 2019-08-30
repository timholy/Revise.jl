var documenterSearchIndex = {"docs": [

{
    "location": "#",
    "page": "Home",
    "title": "Home",
    "category": "page",
    "text": ""
},

{
    "location": "#Introduction-to-Revise-1",
    "page": "Home",
    "title": "Introduction to Revise",
    "category": "section",
    "text": "Revise.jl may help you keep your Julia sessions running longer, reducing the need to restart when you make changes to code. With Revise, you can be in the middle of a session and then edit source code, update packages, switch git branches, and/or stash/unstash code; typically, the changes will be incorporated into the very next command you issue from the REPL. This can save you the overhead of restarting, loading packages, and waiting for code to JIT-compile.note: Automatically loading Revise\nMany users automatically load Revise on startup. This is slightly more involved than just adding using Revise to .julia/config/startup.jl: see Using Revise by default for details."
},

{
    "location": "#Installation-1",
    "page": "Home",
    "title": "Installation",
    "category": "section",
    "text": "You can obtain Revise using Julia\'s Pkg REPL-mode (hitting ] as the first character of the command prompt):(v1.0) pkg> add Reviseor with using Pkg; Pkg.add(\"Revise\")."
},

{
    "location": "#Usage-example-1",
    "page": "Home",
    "title": "Usage example",
    "category": "section",
    "text": "(v1.0) pkg> dev Example\n[...output related to installation...]\n\njulia> using Revise        # importantly, this must come before `using Example`\n\njulia> using Example\n\njulia> hello(\"world\")\n\"Hello, world\"Now we\'re going to test that the Example module lacks a function named f:julia> Example.f()\nERROR: UndefVarError: f not definedBut we really want f, so let\'s add it. You can either navigate to the source code (at .julia/dev/Example/src/Example.jl) in an editor manually, or you can use Julia to open it for you:julia> edit(hello)   # opens Example.jl in the editor you have configuredNow, add a function f() = π and save the file. Go back to the REPL (the same REPL, don\'t restart Julia) and try this:julia> Example.f()\nπ = 3.1415926535897...Now suppose we realize we\'ve made a horrible mistake: that f method will ruin everything. No problem, just delete f in your editor, save the file, and you\'re back to this:julia> Example.f()\nERROR: UndefVarError: f not definedall without restarting Julia.If you need more examples, see Revise usage: a cookbook."
},

{
    "location": "#Other-key-features-of-Revise-1",
    "page": "Home",
    "title": "Other key features of Revise",
    "category": "section",
    "text": "Revise updates its internal paths when you change versions of a package. To try this yourself, first re-insert that definition of f in the dev version of Example and save the file. Now try toggling back and forth between the dev and released versions of Example:(v1.0) pkg> free Example   # switch to the released version of Example\n\njulia> Example.f()\nERROR: UndefVarError: f not defined\n\n(v1.0) pkg> dev Example\n\njulia> Example.f()\nπ = 3.1415926535897...Revise is not tied to any particular editor. (The EDITOR or JULIA_EDITOR environment variables can be used to specify your preference for which editor gets launched by Julia\'s edit function.)If you don\'t want to have to remember to say using Revise each time you start Julia, see Using Revise by default."
},

{
    "location": "#What-Revise-can-track-1",
    "page": "Home",
    "title": "What Revise can track",
    "category": "section",
    "text": "Revise is fairly ambitious: if all is working you should be able to track changes toany package that you load with import or using\nany script you load with includet\nany file defining Base julia itself (with Revise.track(Base))\nany of Julia\'s standard libraries (with, e.g., using Unicode; Revise.track(Unicode))\nany file defining Core.Compiler (with Revise.track(Core.Compiler))The last one requires that you clone Julia and build it yourself from source."
},

{
    "location": "#Secrets-of-Revise-\"wizards\"-1",
    "page": "Home",
    "title": "Secrets of Revise \"wizards\"",
    "category": "section",
    "text": "Revise can assist with methodologies like test-driven development. While it\'s often desirable to write the test first, sometimes when fixing a bug it\'s very difficult to write a good test until you understand the bug better. Often that means basically fixing the bug before your write the test. With Revise, you canfix the bug while simultaneously developing a high-quality test\nverify that your test passes with the fixed code\ngit stash your fix and check that your new test fails on the old code, thus verifying that your test captures the essence of the former bug (if it doesn\'t fail, you need a better test!)\ngit stash pop, test again, commit, and submitall without restarting your Julia session."
},

{
    "location": "#Other-Revise-workflows-1",
    "page": "Home",
    "title": "Other Revise workflows",
    "category": "section",
    "text": "Revise can be used to perform work when files update. For example, let\'s say you want to regenerate a set of web pages whenever your code changes. Suppose you\'ve placed your Julia code in a package called MyWebCode, and the pages depend on \"file1.css\" and \"file2.js\"; thenentr([\"file1.css\", \"file2.js\"], [MyWebCode]) do\n    build_webpages(args...)\nendwill execute build_webpages(args...) whenever you save updates to the listed files or MyWebCode."
},

{
    "location": "#What-else-do-I-need-to-know?-1",
    "page": "Home",
    "title": "What else do I need to know?",
    "category": "section",
    "text": "Except in cases of problems (see below), that\'s it! Revise is a tool that runs in the background, and when all is well it should be essentially invisible, except that you don\'t have to restart Julia so often.Revise can also be used as a \"library\" by developers who want to add other new capabilities to Julia; the sections How Revise works and Developer reference are particularly relevant for them."
},

{
    "location": "#If-Revise-doesn\'t-work-as-expected-1",
    "page": "Home",
    "title": "If Revise doesn\'t work as expected",
    "category": "section",
    "text": "If Revise isn\'t working for you, here are some steps to try:See Configuration for information on customization options. In particular, some file systems (like NFS) might require special options.\nRevise can\'t handle all kinds of code changes; for more information, see the section on Limitations.\nTry running test Revise from the Pkg REPL-mode. If tests pass, check the documentation to make sure you understand how Revise should work. If they fail (especially if it mirrors functionality that you need and isn\'t working), see Fixing a broken or partially-working installation for some suggestions.If you still encounter problems, please file an issue. Especially if you think Revise is making mistakes in adding or deleting methods, please see the page on Debugging Revise for information about how to attach logs to your bug report."
},

{
    "location": "config/#",
    "page": "Configuration",
    "title": "Configuration",
    "category": "page",
    "text": ""
},

{
    "location": "config/#Configuration-1",
    "page": "Configuration",
    "title": "Configuration",
    "category": "section",
    "text": ""
},

{
    "location": "config/#Using-Revise-by-default-1",
    "page": "Configuration",
    "title": "Using Revise by default",
    "category": "section",
    "text": "If you like Revise, you can ensure that every Julia session uses it by adding the following to your .julia/config/startup.jl file:atreplinit() do repl\n    try\n        @eval using Revise\n        @async Revise.wait_steal_repl_backend()\n    catch\n    end\nendIf you want Revise to launch automatically within IJulia, then you should also create a .julia/config/startup_ijulia.jl file with the contentstry\n    @eval using Revise\ncatch\nend"
},

{
    "location": "config/#System-configuration-1",
    "page": "Configuration",
    "title": "System configuration",
    "category": "section",
    "text": "note: Linux-specific configuration\nRevise needs to be notified by your filesystem about changes to your code, which means that the files that define your modules need to be watched for updates. Some systems impose limits on the number of files and directories that can be watched simultaneously; if this limit is hit, on Linux this can result in a fairly cryptic error likeERROR: start_watching (File Monitor): no space left on device (ENOSPC)The cure is to increase the number of files that can be watched, by executingecho 65536 | sudo tee -a /proc/sys/fs/inotify/max_user_watchesat the Linux prompt. (The maximum value is 524288, which will allocate half a gigabyte of RAM to file-watching). For more information see issue #26.Changing the value this way may not last through the next reboot, but you can also change it permanently."
},

{
    "location": "config/#Configuration-options-1",
    "page": "Configuration",
    "title": "Configuration options",
    "category": "section",
    "text": "Revise can be configured by setting environment variables. These variables have to be set before you execute using Revise, because these environment variables are parsed only during execution of Revise\'s __init__ function.There are several ways to set these environment variables:If you are Using Revise by default then you can include statements like ENV[\"JULIA_REVISE\"] = \"manual\" in your .julia/config/startup.jl file prior to the line @eval using Revise.\nOn Unix systems, you can set variables in your shell initialization script (e.g., put lines like export JULIA_REVISE=manual in your .bashrc file if you use bash).\nOn Unix systems, you can launch Julia from the Unix prompt as $ JULIA_REVISE=manual julia to set options for just that session.The function of specific environment variables is described below."
},

{
    "location": "config/#Manual-revision:-JULIA_REVISE-1",
    "page": "Configuration",
    "title": "Manual revision: JULIA_REVISE",
    "category": "section",
    "text": "By default, Revise processes any modified source files every time you enter a command at the REPL. However, there might be times where you\'d prefer to exert manual control over the timing of revisions. Revise looks for an environment variable JULIA_REVISE, and if it is set to anything other than \"auto\" it will require that you manually call revise() to update code.Alternatively, you can omit the call to Revise.async_steal_repl_backend() from your startup.jl file (see Using Revise by default)."
},

{
    "location": "config/#Polling-and-NFS-mounted-code-directories:-JULIA_REVISE_POLL-1",
    "page": "Configuration",
    "title": "Polling and NFS-mounted code directories: JULIA_REVISE_POLL",
    "category": "section",
    "text": "Revise works by scanning your filesystem for changes to the files that define your code. Different operating systems and file systems offer differing levels of support for this feature. Because NFS doesn\'t support inotify, if your code is stored on an NFS-mounted volume you should force Revise to use polling: Revise will periodically (every 5s) scan the modification times of each dependent file. You turn on polling by setting the environment variable JULIA_REVISE_POLL to the string \"1\" (e.g., JULIA_REVISE_POLL=1 in a bash script).If you\'re using polling, you may have to wait several seconds before changes take effect. Consequently polling is not recommended unless you have no other alternative."
},

{
    "location": "config/#User-scripts:-JULIA_REVISE_INCLUDE-1",
    "page": "Configuration",
    "title": "User scripts: JULIA_REVISE_INCLUDE",
    "category": "section",
    "text": "By default, Revise only tracks files that have been required as a consequence of a using or import statement; files loaded by include are not tracked, unless you explicitly use Revise.track(filename). However, you can turn on automatic tracking by setting the environment variable JULIA_REVISE_INCLUDE to the string \"1\" (e.g., JULIA_REVISE_INCLUDE=1 in a bash script)."
},

{
    "location": "config/#Fixing-a-broken-or-partially-working-installation-1",
    "page": "Configuration",
    "title": "Fixing a broken or partially-working installation",
    "category": "section",
    "text": "During certain types of usage you might receive messages likeWarning: /some/system/path/stdlib/v1.0/SHA/src is not an existing directory, Revise is not watchingand this indicates that some of Revise\'s functionality is broken.Revise\'s test suite covers a broad swath of functionality, and so if something is broken a good first start towards resolving the problem is to run pkg> test Revise. Note that some test failures may not really matter to you personally: if, for example, you don\'t plan on hacking on Julia\'s compiler then you may not be concerned about failures related to Revise.track(Core.Compiler). However, because Revise is used by Rebugger and it is common to step into Base methods while debugging, there may be more cases than you might otherwise expect in which you might wish for Revise\'s more \"advanced\" functionality.In the majority of cases, failures come down to Revise having trouble locating source code on your drive. This problem should be fixable, because Revise includes functionality to update its links to source files, as long as it knows what to do.Here are some possible test warnings and errors, and steps you might take to fix them:Error: Package Example not found in current path: This (tiny) package is only used for testing purposes, and gets installed automatically if you do pkg> test Revise, but not if you include(\"runtests.jl\") from inside Revise\'s test/ directory. You can prevent the error with pkg> add Example.\nBase & stdlib file paths: Test Failed at /some/path...  Expression: isfile(Revise.basesrccache) This failure is quite serious, and indicates that you will be unable to access code in Base. To fix this, look for a file called \"base.cache\" somewhere in your Julia install or build directory (for the author, it is at /home/tim/src/julia-1.0/usr/share/julia/base.cache). Now compare this with the value of Revise.basesrccache. (If you\'re getting this failure, presumably they are different.) An important \"top level\" directory is Sys.BINDIR; if they differ already at this level, consider adding a symbolic link from the location pointed at by Sys.BINDIR to the corresponding top-level directory in your actual Julia installation. You\'ll know you\'ve succeeded in specifying it correctly when, after restarting Julia, Revise.basesrccache points to the correct file and Revise.juliadir points to the directory that contains base/. If this workaround is not possible or does not succeed, please file an issue with a description of why you can\'t use it and/or\ndetails from versioninfo and information about how you obtained your Julia installation;\nthe values of Revise.basesrccache and Revise.juliadir, and the actual paths to base.cache and the directory containing the running Julia\'s base/;\nwhat you attempted when trying to fix the problem;\nif possible, your best understanding of why this failed to fix it.\nskipping Core.Compiler tests due to lack of git repo: this likely indicates that you downloaded a Julia binary rather than building Julia from source. While Revise should be able to access the code in Base and standard libraries, at the current time it is not possible for Revise to access julia\'s Core.Compiler module unless you clone Julia\'s repository and build it from source.\nskipping git tests because Revise is not under development: this warning should be harmless. Revise has built-in functionality for extracting source code using git, and it uses itself (i.e., its own git repository) for testing purposes. These tests run only if you have checked out Revise for development (pkg> dev Revise) or on the continuous integration servers (Travis and Appveyor)."
},

{
    "location": "cookbook/#",
    "page": "Revise usage: a cookbook",
    "title": "Revise usage: a cookbook",
    "category": "page",
    "text": ""
},

{
    "location": "cookbook/#Revise-usage:-a-cookbook-1",
    "page": "Revise usage: a cookbook",
    "title": "Revise usage: a cookbook",
    "category": "section",
    "text": ""
},

{
    "location": "cookbook/#Package-centric-usage-1",
    "page": "Revise usage: a cookbook",
    "title": "Package-centric usage",
    "category": "section",
    "text": "For code that might be useful more than once, it\'s often a good idea to put it in a package. For creating packages, the author recommends PkgTemplates.jl. A fallback is to use \"plain\" Pkg commands. Both options are described below."
},

{
    "location": "cookbook/#PkgTemplates-1",
    "page": "Revise usage: a cookbook",
    "title": "PkgTemplates",
    "category": "section",
    "text": "note: Note\nBecause PkgTemplates integrates nicely with git, this approach might require you to do some configuration. (Once you get things set up, you shouldn\'t have to do this part ever again.) PkgTemplates needs you to configure your git user name and email. Some instructions on configuration are here and here. It\'s also helpful to sign up for a GitHub account and set git\'s github.user variable. The PkgTemplates documentation may also be useful.If you struggle with this part, consider trying the \"plain\" Pkg variant below.note: Note\nIf the current directory in your Julia session is itself a package folder, PkgTemplates will use it as the parent environment (project) for your new package. To reduce confusion, before trying the commands below it may help to first ensure you\'re in a a \"neutral\" directory, for example by typing cd() at the Julia prompt.Let\'s create a new package, MyPkg, to play with.julia> using PkgTemplates\n\njulia> t = Template()\nTemplate:\n  → User: timholy\n  → Host: github.com\n  → License: MIT (Tim Holy <tim.holy@gmail.com> 2019)\n  → Package directory: ~/.julia/dev\n  → Minimum Julia version: v1.0\n  → SSH remote: No\n  → Add packages to main environment: Yes\n  → Commit Manifest.toml: No\n  → Plugins: None\n\njulia> generate(\"MyPkg\", t)\nGenerating project MyPkg:\n    /home/tim/.julia/dev/MyPkg/Project.toml\n    /home/tim/.julia/dev/MyPkg/src/MyPkg.jl\n[lots more output suppressed]In the first few lines you can see the location of your new package, here the directory /home/tim/.julia/dev/MyPkg.Before doing anything else, let\'s try it out:julia> using Revise   # you must do this before loading any revisable packages\n\njulia> using MyPkg\n[ Info: Precompiling MyPkg [102b5b08-597c-4d40-b98a-e9249f4d01f4]\n\njulia> MyPkg.greet()\nHello World!(It\'s perfectly fine if you see a different string of digits and letters after the \"Precompiling MyPkg\" message.) You\'ll note that Julia found your package without you having to take any extra steps.Without quitting this Julia session, open the MyPkg.jl file in an editor. You might be able to open it withjulia> edit(pathof(MyPkg))although that might require configuring your EDITOR environment variable.You should see something like this:module MyPkg\n\ngreet() = print(\"Hello World!\")\n\nend # moduleThis is the basic package created by PkgTemplates. Let\'s modify greet to return a different message:module MyPkg\n\ngreet() = print(\"Hello, revised World!\")\n\nend # moduleNow go back to that same Julia session, and try calling greet again. After a pause (the code of Revise and its dependencies is compiling), you should seejulia> MyPkg.greet()\nHello, revised World!From this point forward, revisions should be fast. You can modify MyPkg.jl quite extensively without quitting the Julia session, although there are some Limitations."
},

{
    "location": "cookbook/#Using-Pkg-1",
    "page": "Revise usage: a cookbook",
    "title": "Using Pkg",
    "category": "section",
    "text": "Pkg works similarly to PkgTemplates, but requires less configuration while also doing less on your behalf. Let\'s create a blank MyPkg using Pkg. (If you tried the PkgTemplates version above, you might first have to delete the package with Pkg.rm(\"MyPkg\") following by a complete removal from your dev directory.)julia> using Pkg\n\njulia> cd(Pkg.devdir())   # take us to the standard \"development directory\"\n\n(v1.2) pkg> generate MyPkg\nGenerating project MyPkg:\n    MyPkg/Project.toml\n    MyPkg/src/MyPkg.jl\n\n(v1.2) pkg> dev MyPkg\n[ Info: resolving package identifier `MyPkg` as a directory at `~/.julia/dev/MyPkg`.\n...For the line starting (v1.2) pkg>, hit the ] key at the beginning of the line, then type generate MyPkg. The next line, dev MyPkg, is necessary to tell Pkg about the existence of this new package.Now you can do the following:julia> using MyPkg\n[ Info: Precompiling MyPkg [efe7ebfe-4313-4388-9b6c-3590daf47143]\n\njulia> edit(pathof(MyPkg))and the rest should be similar to what\'s above under PkgTemplates. Note that with this approach, MyPkg has not been set up for version control."
},

{
    "location": "cookbook/#includet-usage-1",
    "page": "Revise usage: a cookbook",
    "title": "includet usage",
    "category": "section",
    "text": "The alternative to creating packages is to manually load individual source files. This approach is intended for quick-and-dirty development; if you want to track multiple files and/or have some files include other files, you should consider switching to the package style above.Open your editor and create a file like this:mygreeting() = \"Hello, world!\"Save it as mygreet.jl in some directory. Here we will assume it\'s being saved in /tmp/.Now load the code with includet, which stands for \"include and track\":julia> using Revise\n\njulia> includet(\"/tmp/mygreet.jl\")\n\njulia> mygreeting()\n\"Hello, world!\"Now, in your editor modify mygreeting to do this:mygreeting() = \"Hello, revised world!\"and then try it in the same session:julia> mygreeting()\n\"Hello, revised world!\"As described above, the first revision you make may be very slow, but later revisions should be fast."
},

{
    "location": "limitations/#",
    "page": "Limitations",
    "title": "Limitations",
    "category": "page",
    "text": ""
},

{
    "location": "limitations/#Limitations-1",
    "page": "Limitations",
    "title": "Limitations",
    "category": "section",
    "text": "There are some kinds of changes that Revise (or often, Julia itself) cannot incorporate into a running Julia session:changes to type definitions\nadding new source files to packages, or file/module renames\nconflicts between variables and functions sharing the same nameThese kinds of changes require that you restart your Julia session.In addition, some situations may require special handling:"
},

{
    "location": "limitations/#Macros-and-generated-functions-1",
    "page": "Limitations",
    "title": "Macros and generated functions",
    "category": "section",
    "text": "If you change a macro definition or methods that get called by @generated functions outside their quote block, these changes will not be propagated to functions that have already evaluated the macro or generated function.You may explicitly call revise(MyModule) to force reevaluating every definition in module MyModule. Note that when a macro changes, you have to revise all of the modules that use it."
},

{
    "location": "limitations/#Distributed-computing-(multiple-workers)-and-anonymous-functions-1",
    "page": "Limitations",
    "title": "Distributed computing (multiple workers) and anonymous functions",
    "category": "section",
    "text": "Revise supports changes to code in worker processes. The code must be loaded in the main process in which Revise is running.Revise cannot handle changes in anonymous functions used in remotecalls. Consider the following module definition:module ParReviseExample\nusing Distributed\n\ngreet(x) = println(\"Hello, \", x)\n\nfoo() = for p in workers()\n    remotecall_fetch(() -> greet(\"Bar\"), p)\nend\n\nend # moduleChanging the remotecall to remotecall_fetch((x) -> greet(\"Bar\"), p, 1) will fail, because the new anonymous function is not defined on all workers. The workaround is to write the code to use named functions, e.g.,module ParReviseExample\nusing Distributed\n\ngreet(x) = println(\"Hello, \", x)\ngreetcaller() = greet(\"Bar\")\n\nfoo() = for p in workers()\n    remotecall_fetch(greetcaller, p)\nend\n\nend # moduleand the corresponding edit to the code would be to modify it to greetcaller(x) = greet(\"Bar\") and remotecall_fetch(greetcaller, p, 1)."
},

{
    "location": "debugging/#",
    "page": "Debugging Revise",
    "title": "Debugging Revise",
    "category": "page",
    "text": ""
},

{
    "location": "debugging/#Debugging-Revise-1",
    "page": "Debugging Revise",
    "title": "Debugging Revise",
    "category": "section",
    "text": "If Revise isn\'t behaving the way you expect it to, it can be useful to examine the decisions it made. Revise supports Julia\'s Logging framework and can optionally record its decisions in a format suitable for later inspection. What follows is a simple series of steps you can use to turn on logging, capture messages, and then submit them with a bug report. Alternatively, more advanced developers may want to examine the logs themselves to determine the source of Revise\'s error, and for such users a few tips about interpreting the log messages are also provided below."
},

{
    "location": "debugging/#Turning-on-logging-1",
    "page": "Debugging Revise",
    "title": "Turning on logging",
    "category": "section",
    "text": "Currently, the best way to turn on logging is within a running Julia session:julia> rlogger = Revise.debug_logger()\nRevise.ReviseLogger(Revise.LogRecord[], Debug)You\'ll use rlogger at the end to retrieve the logs.Now carry out the series of julia commands and code edits that reproduces the problem."
},

{
    "location": "debugging/#Capturing-the-logs-and-submitting-them-with-your-bug-report-1",
    "page": "Debugging Revise",
    "title": "Capturing the logs and submitting them with your bug report",
    "category": "section",
    "text": "Once all the revisions have been triggered and the mistake has been reproduced, it\'s time to capture the logs. To capture all the logs, usejulia> using Base.CoreLogging: Debug\n\njulia> logs = filter(r->r.level==Debug, rlogger.logs);You can capture just the changes that Revise made to running code withjulia> logs = Revise.actions(rlogger)You can either let these print to the console and copy/paste the text output into the issue, or if they are extensive you can save logs to a file:open(\"/tmp/revise.logs\", \"w\") do io\n    for log in logs\n        println(io, log)\n    end\nendThen you can upload the logs somewhere (e.g., https://gist.github.com/) and link the url in your bug report. To assist in the resolution of the bug, please also specify additional relevant information such as the name of the function that was misbehaving after revision and/or any error messages that your received.See also A complete debugging demo below."
},

{
    "location": "debugging/#Logging-by-default-1",
    "page": "Debugging Revise",
    "title": "Logging by default",
    "category": "section",
    "text": "If you suspect a bug in Revise but have difficulty isolating it, you can include the lines    # Turn on logging\n    Revise.debug_logger()within the Revise block of your ~/.julia/config/startup.jl file. This will ensure that you always log Revise\'s actions. Then carry out your normal Julia development. If a Revise-related problem arises, executing these linesrlogger = Revise.debug_logger()\nusing Base.CoreLogging: Debug\nlogs = filter(r->r.level==Debug, rlogger.logs)\nopen(\"/tmp/revise.logs\", \"w\") do io\n    for log in logs\n        println(io, log)\n    end\nendwithin the same session will generate the /tmp/revise.logs file that you can submit with your bug report. (What makes this possible is that a second call to Revise.debug_logger() returns the same logger object created by the first call–it is not necessary to hold on to rlogger.)"
},

{
    "location": "debugging/#The-structure-of-the-logs-1",
    "page": "Debugging Revise",
    "title": "The structure of the logs",
    "category": "section",
    "text": "For those who want to do a little investigating on their own, it may be helpful to know that Revise\'s core decisions are captured in the group called \"Action,\" and they come in three flavors:log entries with message \"Eval\" signify a call to eval; for these events, keyword :deltainfo has value (mod, expr) where mod is the module of evaluation and expr is a Revise.RelocatableExpr containing the expression that was evaluated.\nlog entries with message \"DeleteMethod\" signify a method deletion; for these events, keyword :deltainfo has value (sigt, methsummary) where sigt is the signature of the method that Revise intended to delete and methsummary is a MethodSummary of the method that Revise actually found to delete.\nlog entries with message \"LineOffset\" correspond to updates to Revise\'s own internal estimates of how far a given method has become displaced from the line number it occupied when it was last evaluated. For these events, :deltainfo has value (sigt, newlineno, oldoffset=>newoffset).If you\'re debugging mistakes in method creation/deletion, the \"LineOffset\" events may be distracting; by default Revise.actions excludes these events.Note that Revise records the time of each revision, which can sometimes be useful in determining which revisions occur in conjunction with which user actions. If you want to make use of this, it can be handy to capture the start time with tstart = time() before commencing on a session.See Revise.debug_logger for information on groups besides \"Action.\""
},

{
    "location": "debugging/#A-complete-debugging-demo-1",
    "page": "Debugging Revise",
    "title": "A complete debugging demo",
    "category": "section",
    "text": "From within Revise\'s test/ directory, try the following:julia> rlogger = Revise.debug_logger();\n\nshell> cp revisetest.jl /tmp/\n\njulia> includet(\"/tmp/revisetest.jl\")\n\njulia> ReviseTest.cube(3)\n81\n\nshell> cp revisetest_revised.jl /tmp/revisetest.jl\n\njulia> ReviseTest.cube(3)\n27\n\njulia> rlogger.logs\njulia> rlogger.logs\n9-element Array{Revise.LogRecord,1}:\n Revise.LogRecord(Debug, DeleteMethod, Action, Revise_4ac0f476, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 226, (time=1.557996459055345e9, deltainfo=(Tuple{typeof(Main.ReviseTest.cube),Any}, MethodSummary(:cube, :ReviseTest, Symbol(\"/tmp/revisetest.jl\"), 7, Tuple{typeof(Main.ReviseTest.cube),Any}))))\n Revise.LogRecord(Debug, DeleteMethod, Action, Revise_4ac0f476, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 226, (time=1.557996459167895e9, deltainfo=(Tuple{typeof(Main.ReviseTest.Internal.mult3),Any}, MethodSummary(:mult3, :Internal, Symbol(\"/tmp/revisetest.jl\"), 12, Tuple{typeof(Main.ReviseTest.Internal.mult3),Any}))))\n Revise.LogRecord(Debug, DeleteMethod, Action, Revise_4ac0f476, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 226, (time=1.557996459167956e9, deltainfo=(Tuple{typeof(Main.ReviseTest.Internal.mult4),Any}, MethodSummary(:mult4, :Internal, Symbol(\"/tmp/revisetest.jl\"), 13, Tuple{typeof(Main.ReviseTest.Internal.mult4),Any}))))\n Revise.LogRecord(Debug, Eval, Action, Revise_9147188b, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 276, (time=1.557996459259605e9, deltainfo=(Main.ReviseTest, :(cube(x) = begin\n          #= /tmp/revisetest.jl:7 =#\n          x ^ 3\n      end))))\n Revise.LogRecord(Debug, Eval, Action, Revise_9147188b, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 276, (time=1.557996459330512e9, deltainfo=(Main.ReviseTest, :(fourth(x) = begin\n          #= /tmp/revisetest.jl:9 =#\n          x ^ 4\n      end))))\n Revise.LogRecord(Debug, LineOffset, Action, Revise_fb38a7f7, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 296, (time=1.557996459331061e9, deltainfo=(Any[Tuple{typeof(mult2),Any}], :(#= /tmp/revisetest.jl:11 =#) => :(#= /tmp/revisetest.jl:13 =#))))\n Revise.LogRecord(Debug, Eval, Action, Revise_9147188b, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 276, (time=1.557996459391182e9, deltainfo=(Main.ReviseTest.Internal, :(mult3(x) = begin\n          #= /tmp/revisetest.jl:14 =#\n          3x\n      end))))\n Revise.LogRecord(Debug, LineOffset, Action, Revise_fb38a7f7, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 296, (time=1.557996459391642e9, deltainfo=(Any[Tuple{typeof(unchanged),Any}], :(#= /tmp/revisetest.jl:18 =#) => :(#= /tmp/revisetest.jl:19 =#))))\n Revise.LogRecord(Debug, LineOffset, Action, Revise_fb38a7f7, \"/home/tim/.julia/dev/Revise/src/Revise.jl\", 296, (time=1.557996459391695e9, deltainfo=(Any[Tuple{typeof(unchanged2),Any}], :(#= /tmp/revisetest.jl:20 =#) => :(#= /tmp/revisetest.jl:21 =#))))You can see that Revise started by deleting three methods, followed by evaluating three new versions of those methods. Interspersed are various changes to the line numbering.In rare cases it might be helpful to independently record the sequence of edits to the file. You can make copies cp editedfile.jl > /tmp/version1.jl, edit code, cp editedfile.jl > /tmp/version2.jl, etc. diff version1.jl version2.jl can be used to capture a compact summary of the changes and pasted into the bug report."
},

{
    "location": "internals/#",
    "page": "How Revise works",
    "title": "How Revise works",
    "category": "page",
    "text": ""
},

{
    "location": "internals/#How-Revise-works-1",
    "page": "How Revise works",
    "title": "How Revise works",
    "category": "section",
    "text": "Revise is based on the fact that you can change functions even when they are defined in other modules. Here\'s an example showing how you do that manually (without using Revise):julia> convert(Float64, π)\n3.141592653589793\n\njulia> # That\'s too hard, let\'s make life easier for students\n\njulia> @eval Base convert(::Type{Float64}, x::Irrational{:π}) = 3.0\nconvert (generic function with 714 methods)\n\njulia> convert(Float64, π)\n3.0Revise removes some of the tedium of manually copying and pasting code into @eval statements. To decrease the amount of re-JITting required, Revise avoids reloading entire modules; instead, it takes care to eval only the changes in your package(s), much as you would if you were doing it manually. Importantly, changes are detected in a manner that is independent of the specific line numbers in your code, so that you don\'t have to re-evaluate just because code moves around within the same file. (One unfortunate side effect is that line numbers may become inaccurate in backtraces, but Revise takes pains to correct these, see below.)To accomplish this, Revise uses the following overall strategy:add callbacks to Base so that Revise gets notified when new packages are loaded or new files included\nprepare source-code caches for every new file. These caches will allow Revise to detect changes when files are updated. For precompiled packages this happens on an as-needed basis, using the cached source in the *.ji file. For non-precompiled packages, Revise parses the source for each included file immediately so that the initial state is known and changes can be detected.\nmonitor the file system for changes to any of the dependent files; it immediately appends any updates to a list of file names that need future processing\nintercept the REPL\'s backend to ensure that the list of files-to-be-revised gets processed each time you execute a new command at the REPL\nwhen a revision is triggered, the source file(s) are re-parsed, and a diff between the cached version and the new version is created. eval the diff in the appropriate module(s).\nreplace the cached version of each source file with the new version, so that further changes are diffed against the most recent update."
},

{
    "location": "internals/#The-structure-of-Revise\'s-internal-representation-1",
    "page": "How Revise works",
    "title": "The structure of Revise\'s internal representation",
    "category": "section",
    "text": "(Image: diagram)Figure notes: Nodes represent primary objects in Julia\'s compilation pipeline. Arrows and their labels represent functions or data structures that allow you to move from one node to another. Red (\"destructive\") paths force recompilation of dependent functions.Revise bridges between text files (your source code) and compiled code. Revise consequently maintains data structures that parallel Julia\'s own internal processing of code. When dealing with a source-code file, you start with strings, parse them to obtain Julia expressions, evaluate them to obtain Julia objects, and (where appropriate, e.g., for methods) compile them to machine code. This will be called the forward workflow. Revise sets up a few key structures that allow it to progress from files to modules to Julia expressions and types.Revise also sets up a backward workflow, proceeding from compiled code to Julia types back to Julia expressions. This workflow is useful, for example, when dealing with errors: the stack traces displayed by Julia link from the compiled code back to the source files. To make this possible, Julia builds \"breadcrumbs\" into compiled code that store the filename and line number at which each expression was found. However, these links are static, meaning they are set up once (when the code is compiled) and are not updated when the source file changes. Because trivial manipulations to source files (e.g., the insertion of blank lines and/or comments) can change the line number of an expression without necessitating its recompilation, Revise implements a way of correcting these line numbers before they are displayed to the user. This capability requires that Revise proceed backward from the compiled objects to something resembling the original text file."
},

{
    "location": "internals/#Terminology-1",
    "page": "How Revise works",
    "title": "Terminology",
    "category": "section",
    "text": "A few convenience terms are used throughout: definition, signature-expression, and signature-type. These terms are illustrated using the following example:<p><pre><code class=\"language-julia\">function <mark>print_item(io::IO, item, ntimes::Integer=1, pre::String=\"\")</mark>\n    print(io, pre)\n    for i = 1:ntimes\n        print(io, item)\n    end\nend</code></pre></p>This represents the definition of a method. Definitions are stored as expressions, using a Revise.RelocatableExpr. The highlighted portion is the signature-expression, specifying the name, argument names and their types, and (if applicable) type-parameters of the method.From the signature-expression we can generate one or more signature-types. Since this function has two default arguments, this signature-expression generates three signature-types, each corresponding to a different valid way of calling this method:Tuple{typeof(print_item),IO,Any}                    # print_item(io, item)\nTuple{typeof(print_item),IO,Any,Integer}            # print_item(io, item, 2)\nTuple{typeof(print_item),IO,Any,Integer,String}     # print_item(io, item, 2, \"  \")In Revise\'s internal code, a definition is often represented with a variable def, a signature-expression with sigex, and a signature-type with sigt."
},

{
    "location": "internals/#Core-data-structures-and-representations-1",
    "page": "How Revise works",
    "title": "Core data structures and representations",
    "category": "section",
    "text": "Two \"maps\" are central to Revise\'s inner workings: ExprsSigs maps link definition=>signature-types (the forward workflow), while CodeTracking (specifically, its internal variable method_info) links from signature-type=>definition (the backward workflow). Concretely, CodeTracking.method_info is just an IdDict mapping sigt=>(locationinfo, def). Of note, a stack frame typically contains a link to a method, which stores the equivalent of sigt; consequently, this information allows one to look up the corresponding locationinfo and def. (When methods move, the location information stored by CodeTracking gets updated by Revise.)Some additional notes about Revise\'s ExprsSigs maps:For expressions that do not define a method, it is just def=>nothing\nFor expressions that do define a method, it is def=>[sigt1, ...]. [sigt1, ...] is the list of signature-types generated from def (often just one, but more in the case of methods with default arguments or keyword arguments).\nThey are represented as an OrderedDict so as to preserve the sequence in which expressions occur in the file. This can be important particularly for updating macro definitions, which affect the expansion of later code. The order is maintained so as to match the current ordering of the source-file, which is not necessarily the same as the ordering when these expressions were last evaled.\nEach key in the map (the definition RelocatableExpr) is the most recently evaled version of the expression. This has an important consequence: the line numbers in the def (which are still present, even though not used for equality comparisons) correspond to the ones in compiled code. Any discrepancy with the current line numbers in the file is handled through updates to the location information stored by CodeTracking.ExprsSigs are organized by module and then file, so that one can map filename=>module=>def=>sigts. Importantly, single-file modules can be \"reconstructed\" from the keys of the corresponding ExprsSigs (and multi-file modules from a collection of such items), since they hold the complete ordered set of expressions that would be evaled to define the module.The global variable that holds all this information is Revise.pkgdatas, organized into a dictionary of Revise.PkgData objects indexed by Base Julia\'s PkgId (a unique identifier for packages)."
},

{
    "location": "internals/#An-example-1",
    "page": "How Revise works",
    "title": "An example",
    "category": "section",
    "text": "Consider a module, Items, defined by the following two source files:Items.jl:__precompile__(false)\n\nmodule Items\n\ninclude(\"indents.jl\")\n\nfunction print_item(io::IO, item, ntimes::Integer=1, pre::String=indent(item))\n    print(io, pre)\n    for i = 1:ntimes\n        print(io, item)\n    end\nend\n\nendindents.jl:indent(::UInt16) = 2\nindent(::UInt8)  = 4If you create this as a mini-package and then say using Revise, Items, you can start examining internal variables in the following manner:julia> id = Base.PkgId(Items)\nItems [b24a5932-55ed-11e9-2a88-e52f99e65a0d]\n\njulia> pkgdata = Revise.pkgdatas[id]\nPkgData(Items [b24a5932-55ed-11e9-2a88-e52f99e65a0d]:\n  \"src/Items.jl\": FileInfo(Main=>ExprsSigs(<1 expressions>, <0 signatures>), Items=>ExprsSigs(<2 expressions>, <3 signatures>), )\n  \"src/indents.jl\": FileInfo(Items=>ExprsSigs(<2 expressions>, <2 signatures>), )(Your specific UUID may differ.)Path information is stored in pkgdata.info:julia> pkgdata.info\nPkgFiles(Items [b24a5932-55ed-11e9-2a88-e52f99e65a0d]):\n  basedir: \"/tmp/pkgs/Items\"\n  files: [\"src/Items.jl\", \"src/indents.jl\"]basedir is the only part using absolute paths; everything else is encoded relative to that location. This facilitates, e.g., switching between develop and add mode in the package manager.src/indents.jl is particularly simple:julia> pkgdata.fileinfos[2]\nFileInfo(Items=>ExprsSigs with the following expressions:\n  :(indent(::UInt16) = begin\n          2\n      end)\n  :(indent(::UInt8) = begin\n          4\n      end), )This is just a summary; to see the actual def=>sigts map, do the following:julia> pkgdata.fileinfos[2].modexsigs[Items]\nOrderedCollections.OrderedDict{Revise.RelocatableExpr,Union{Nothing, Array{Any,1}}} with 2 entries:\n  :(indent(::UInt16) = begin…                       => Any[Tuple{typeof(indent),UInt16}]\n  :(indent(::UInt8) = begin…                        => Any[Tuple{typeof(indent),UInt8}]These are populated now because we specified __precompile__(false), which forces Revise to defensively parse all expressions in the package in case revisions are made at some future point. For precompiled packages, each pkgdata.fileinfos[i] can instead rely on the cachefile (another field stored in the Revise.FileInfo) as a record of the state of the file at the time the package was loaded; as a consequence, Revise can defer parsing the source file(s) until they are updated.Items.jl is represented with a bit more complexity, \"Items.jl\"=>Dict(Main=>map1, Items=>map2). This is because Items.jl contains one expression (the __precompile__ statement) that is evaled in Main, and other expressions that are evaled in Items."
},

{
    "location": "internals/#Revisions-and-computing-diffs-1",
    "page": "How Revise works",
    "title": "Revisions and computing diffs",
    "category": "section",
    "text": "When the file system notifies Revise that a file has been modified, Revise re-parses the file and assigns the expressions to the appropriate modules, creating a Revise.ModuleExprsSigs mexsnew. It then compares mexsnew against mexsref, the reference object that is synchronized to code as it was evaled. The following actions are taken:if a def entry in mexsref is equal to one in mexsnew, the expression is \"unchanged\" except possibly for line number. The locationinfo in CodeTracking is updated as needed.\nif a def entry in mexsref is not present in mexsnew, that entry is deleted and any corresponding methods are also deleted.\nif a def entry in mexsnew is not present in mexsref, it is evaled and then added to mexsref.Technically, a new mexsref is generated every time to ensure that the expressions are ordered as in mexsnew; however, conceptually this is better thought of as an updating of mexsref, after which mexsnew is discarded.Note that one consequence is that modifying a method causes two actions, the deletion of the original followed by evaling a new version. During revision, all method deletions are performed first, followed by all the new evaled methods. This ensures that if a method gets moved from fileB.jl to fileA.jl, Revise doesn\'t mistakenly redefine and then delete the method simply because fileA.jl got processed before fileB.jl."
},

{
    "location": "internals/#Internal-API-1",
    "page": "How Revise works",
    "title": "Internal API",
    "category": "section",
    "text": "You can find more detail about Revise\'s inner workings in the Developer reference."
},

{
    "location": "user_reference/#",
    "page": "User reference",
    "title": "User reference",
    "category": "page",
    "text": ""
},

{
    "location": "user_reference/#Revise.revise",
    "page": "User reference",
    "title": "Revise.revise",
    "category": "function",
    "text": "revise()\n\neval any changes in the revision queue. See Revise.revision_queue.\n\n\n\n\n\nrevise(mod::Module)\n\nReevaluate every definition in mod, whether it was changed or not. This is useful to propagate an updated macro definition, or to force recompiling generated functions.\n\n\n\n\n\n"
},

{
    "location": "user_reference/#Revise.track",
    "page": "User reference",
    "title": "Revise.track",
    "category": "function",
    "text": "Revise.track(Base)\nRevise.track(Core.Compiler)\nRevise.track(stdlib)\n\nTrack updates to the code in Julia\'s base directory, base/compiler, or one of its standard libraries.\n\n\n\n\n\nRevise.track(mod::Module, file::AbstractString)\nRevise.track(file::AbstractString)\n\nWatch file for updates and revise loaded code with any changes. mod is the module into which file is evaluated; if omitted, it defaults to Main.\n\nIf this produces many errors, check that you specified mod correctly.\n\n\n\n\n\n"
},

{
    "location": "user_reference/#Revise.includet",
    "page": "User reference",
    "title": "Revise.includet",
    "category": "function",
    "text": "includet(filename)\n\nLoad filename and track any future changes to it. includet is essentially shorthand for\n\nRevise.track(Main, filename; define=true, skip_include=false)\n\nincludet is intended for \"user scripts,\" e.g., a file you use locally for a specific purpose such as loading a specific data set or performing a particular analysis. Do not use includet for packages, as those should be handled by using or import. (If you\'re working with code in Base or one of Julia\'s standard libraries, use Revise.track(mod) instead, where mod is the module.) If using and import aren\'t working, you may have packages in a non-standard location; try fixing it with something like push!(LOAD_PATH, \"/path/to/my/private/repos\").\n\nincludet is deliberately non-recursive, so if filename loads any other files, they will not be automatically tracked. (See Revise.track to set it up manually.)\n\n\n\n\n\n"
},

{
    "location": "user_reference/#Revise.entr",
    "page": "User reference",
    "title": "Revise.entr",
    "category": "function",
    "text": "entr(f, files; postpone=false, pause=0.02)\nentr(f, files, modules; postpone=false, pause=0.02)\n\nExecute f() whenever files listed in files, or code in modules, updates. entr will process updates (and block your command line) until you press Ctrl-C. Unless postpone is true, f() will be executed also when calling entr, regardless of file changes. The pause is the period (in seconds) that entr will wait between being triggered and actually calling f(), to handle clusters of modifications, such as those produced by saving files in certain text editors.\n\nExample\n\nentr([\"/tmp/watched.txt\"], [Pkg1, Pkg2]) do\n    println(\"update\")\nend\n\nThis will print \"update\" every time \"/tmp/watched.txt\" or any of the code defining Pkg1 or Pkg2 gets updated.\n\n\n\n\n\n"
},

{
    "location": "user_reference/#User-reference-1",
    "page": "User reference",
    "title": "User reference",
    "category": "section",
    "text": "There are really only four functions that a user would be expected to call manually: revise, includet, Revise.track, and entr. Other user-level constructs might apply if you want to debug Revise or prevent it from watching specific packages.revise\nRevise.track\nincludet\nentr"
},

{
    "location": "user_reference/#Revise.debug_logger",
    "page": "User reference",
    "title": "Revise.debug_logger",
    "category": "function",
    "text": "logger = Revise.debug_logger(; min_level=Debug)\n\nTurn on debug logging (if min_level is set to Debug or better) and return the logger object. logger.logs contains a list of the logged events. The items in this list are of type Revise.LogRecord, with the following relevant fields:\n\ngroup: the event category. Revise currently uses the following groups:\n\"Action\": a change was implemented, of type described in the message field.\n\"Parsing\": a \"significant\" event in parsing. For these, examine the message field for more information.\n\"Watching\": an indication that Revise determined that a particular file needed to be examined for possible code changes. This is typically done on the basis of mtime, the modification time of the file, and does not necessarily indicate that there were any changes.\nmessage: a string containing more information. Some examples:\nFor entries in the \"Action\" group, message can be \"Eval\" when modifying old methods or defining new ones, \"DeleteMethod\" when deleting a method, and \"LineOffset\" to indicate that the line offset for a method was updated (the last only affects the printing of stacktraces upon error, it does not change how code runs)\nItems with group \"Parsing\" and message \"Diff\" contain sets :newexprs and :oldexprs that contain the expression unique to post- or pre-revision, respectively.\nkwargs: a pairs list of any other data. This is usually specific to particular group/message combinations.\n\nSee also Revise.actions and Revise.diffs.\n\n\n\n\n\n"
},

{
    "location": "user_reference/#Revise.actions",
    "page": "User reference",
    "title": "Revise.actions",
    "category": "function",
    "text": "actions(logger; line=false)\n\nReturn a vector of all log events in the \"Action\" group. \"LineOffset\" events are returned only if line=true; by default the returned items are the events that modified methods in your session.\n\n\n\n\n\n"
},

{
    "location": "user_reference/#Revise.diffs",
    "page": "User reference",
    "title": "Revise.diffs",
    "category": "function",
    "text": "diffs(logger)\n\nReturn a vector of all log events that encode a (non-empty) diff between two versions of a file.\n\n\n\n\n\n"
},

{
    "location": "user_reference/#Revise-logs-(debugging-Revise)-1",
    "page": "User reference",
    "title": "Revise logs (debugging Revise)",
    "category": "section",
    "text": "Revise.debug_logger\nRevise.actions\nRevise.diffs"
},

{
    "location": "user_reference/#Revise.dont_watch_pkgs",
    "page": "User reference",
    "title": "Revise.dont_watch_pkgs",
    "category": "constant",
    "text": "Revise.dont_watch_pkgs\n\nGlobal variable, use push!(Revise.dont_watch_pkgs, :MyPackage) to prevent Revise from tracking changes to MyPackage. You can do this from the REPL or from your .julia/config/startup.jl file.\n\nSee also Revise.silence.\n\n\n\n\n\n"
},

{
    "location": "user_reference/#Revise.silence",
    "page": "User reference",
    "title": "Revise.silence",
    "category": "function",
    "text": "Revise.silence(pkg)\n\nSilence warnings about not tracking changes to package pkg.\n\n\n\n\n\n"
},

{
    "location": "user_reference/#Prevent-Revise-from-watching-specific-packages-1",
    "page": "User reference",
    "title": "Prevent Revise from watching specific packages",
    "category": "section",
    "text": "Revise.dont_watch_pkgs\nRevise.silence"
},

{
    "location": "dev_reference/#",
    "page": "Developer reference",
    "title": "Developer reference",
    "category": "page",
    "text": ""
},

{
    "location": "dev_reference/#Developer-reference-1",
    "page": "Developer reference",
    "title": "Developer reference",
    "category": "section",
    "text": ""
},

{
    "location": "dev_reference/#Internal-global-variables-1",
    "page": "Developer reference",
    "title": "Internal global variables",
    "category": "section",
    "text": ""
},

{
    "location": "dev_reference/#Revise.watching_files",
    "page": "Developer reference",
    "title": "Revise.watching_files",
    "category": "constant",
    "text": "Revise.watching_files[]\n\nReturns true if we watch files rather than their containing directory. FreeBSD and NFS-mounted systems should watch files, otherwise we prefer to watch directories.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.polling_files",
    "page": "Developer reference",
    "title": "Revise.polling_files",
    "category": "constant",
    "text": "Revise.polling_files[]\n\nReturns true if we should poll the filesystem for changes to the files that define loaded code. It is preferable to avoid polling, instead relying on operating system notifications via FileWatching.watch_file. However, NFS-mounted filesystems (and perhaps others) do not support file-watching, so for code stored on such filesystems you should turn polling on.\n\nSee the documentation for the JULIA_REVISE_POLL environment variable.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.tracking_Main_includes",
    "page": "Developer reference",
    "title": "Revise.tracking_Main_includes",
    "category": "constant",
    "text": "Revise.tracking_Main_includes[]\n\nReturns true if files directly included from the REPL should be tracked. The default is false. See the documentation regarding the JULIA_REVISE_INCLUDE environment variable to customize it.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Configuration-related-variables-1",
    "page": "Developer reference",
    "title": "Configuration-related variables",
    "category": "section",
    "text": "These are set during execution of Revise\'s __init__ function.Revise.watching_files\nRevise.polling_files\nRevise.tracking_Main_includes"
},

{
    "location": "dev_reference/#Revise.juliadir",
    "page": "Developer reference",
    "title": "Revise.juliadir",
    "category": "constant",
    "text": "Revise.juliadir\n\nConstant specifying full path to julia top-level source directory. This should be reliable even for local builds, cross-builds, and binary installs.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.basesrccache",
    "page": "Developer reference",
    "title": "Revise.basesrccache",
    "category": "constant",
    "text": "Revise.basesrccache\n\nFull path to the running Julia\'s cache of source code defining Base.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.basebuilddir",
    "page": "Developer reference",
    "title": "Revise.basebuilddir",
    "category": "constant",
    "text": "Revise.basebuilddir\n\nJulia\'s top-level directory when Julia was built, as recorded by the entries in Base._included_files.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Path-related-variables-1",
    "page": "Developer reference",
    "title": "Path-related variables",
    "category": "section",
    "text": "Revise.juliadir\nRevise.basesrccache\nRevise.basebuilddir"
},

{
    "location": "dev_reference/#Revise.pkgdatas",
    "page": "Developer reference",
    "title": "Revise.pkgdatas",
    "category": "constant",
    "text": "Revise.pkgdatas\n\npkgdatas is the core information that tracks the relationship between source code and julia objects, and allows re-evaluation of code in the proper module scope. It is a dictionary indexed by PkgId: pkgdatas[id] returns a value of type Revise.PkgData.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.watched_files",
    "page": "Developer reference",
    "title": "Revise.watched_files",
    "category": "constant",
    "text": "Revise.watched_files\n\nGlobal variable, watched_files[dirname] returns the collection of files in dirname that we\'re monitoring for changes. The returned value has type Revise.WatchList.\n\nThis variable allows us to watch directories rather than files, reducing the burden on the OS.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.revision_queue",
    "page": "Developer reference",
    "title": "Revise.revision_queue",
    "category": "constant",
    "text": "Revise.revision_queue\n\nGlobal variable, revision_queue holds (pkgdata,filename) pairs that we need to revise, meaning that these files have changed since we last processed a revision. This list gets populated by callbacks that watch directories for updates.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.included_files",
    "page": "Developer reference",
    "title": "Revise.included_files",
    "category": "constant",
    "text": "Revise.included_files\n\nGlobal variable, included_files gets populated by callbacks we register with include. It\'s used to track non-precompiled packages and, optionally, user scripts (see docs on JULIA_REVISE_INCLUDE).\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Internal-state-management-1",
    "page": "Developer reference",
    "title": "Internal state management",
    "category": "section",
    "text": "Revise.pkgdatas\nRevise.watched_files\nRevise.revision_queue\nRevise.included_files"
},

{
    "location": "dev_reference/#Revise.RelocatableExpr",
    "page": "Developer reference",
    "title": "Revise.RelocatableExpr",
    "category": "type",
    "text": "A RelocatableExpr wraps an Expr to ensure that comparisons between RelocatableExprs ignore line numbering information. This allows one to detect that two expressions are the same no matter where they appear in a file.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.ModuleExprsSigs",
    "page": "Developer reference",
    "title": "Revise.ModuleExprsSigs",
    "category": "type",
    "text": "ModuleExprsSigs\n\nFor a particular source file, the corresponding ModuleExprsSigs is a mapping mod=>exprs=>sigs of the expressions exprs found in mod and the signatures sigs that arise from them. Specifically, if mes is a ModuleExprsSigs, then mes[mod][ex] is a list of signatures that result from evaluating ex in mod. It is possible that this returns nothing, which can mean either that ex does not define any methods or that the signatures have not yet been cached.\n\nThe first mod key is guaranteed to be the module into which this file was included.\n\nTo create a ModuleExprsSigs from a source file, see Revise.parse_source.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.FileInfo",
    "page": "Developer reference",
    "title": "Revise.FileInfo",
    "category": "type",
    "text": "FileInfo(mexs::ModuleExprsSigs, cachefile=\"\")\n\nStructure to hold the per-module expressions found when parsing a single file. mexs holds the Revise.ModuleExprsSigs for the file.\n\nOptionally, a FileInfo can also record the path to a cache file holding the original source code. This is applicable only for precompiled modules and Base. (This cache file is distinct from the original source file that might be edited by the developer, and it will always hold the state of the code when the package was precompiled or Julia\'s Base was built.) When a cache is available, mexs will be empty until the file gets edited: the original source code gets parsed only when a revision needs to be made.\n\nSource cache files greatly reduce the overhead of using Revise.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.PkgData",
    "page": "Developer reference",
    "title": "Revise.PkgData",
    "category": "type",
    "text": "PkgData(id, path, fileinfos::Dict{String,FileInfo})\n\nA structure holding the data required to handle a particular package. path is the top-level directory defining the package, and fileinfos holds the Revise.FileInfo for each file defining the package.\n\nFor the PkgData associated with Main (e.g., for files loaded with includet), the corresponding path entry will be empty.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.WatchList",
    "page": "Developer reference",
    "title": "Revise.WatchList",
    "category": "type",
    "text": "Revise.WatchList\n\nA struct for holding files that live inside a directory. Some platforms (OSX) have trouble watching too many files. So we watch parent directories, and keep track of which files in them should be tracked.\n\nFields:\n\ntimestamp: mtime of last update\ntrackedfiles: Set of filenames, generally expressed as a relative path\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.Rescheduler",
    "page": "Developer reference",
    "title": "Revise.Rescheduler",
    "category": "type",
    "text": "Rescheduler(f, args)\n\nTo facilitate precompilation and reduce latency, we replace\n\nfunction watch_manifest(mfile)\n    wait_changed(mfile)\n    # stuff\n    @async watch_manifest(mfile)\nend\n\n@async watch_manifest(mfile)\n\nwith a rescheduling type:\n\nfresched = Rescheduler(watch_manifest, (mfile,))\nschedule(Task(fresched))\n\nwhere now watch_manifest(mfile) should return true if the task should be rescheduled after completion, and false otherwise.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.MethodSummary",
    "page": "Developer reference",
    "title": "Revise.MethodSummary",
    "category": "type",
    "text": "MethodSummary(method)\n\nCreate a portable summary of a method. In particular, a MethodSummary can be saved to a JLD2 file.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Types-1",
    "page": "Developer reference",
    "title": "Types",
    "category": "section",
    "text": "Revise.RelocatableExpr\nRevise.ModuleExprsSigs\nRevise.FileInfo\nRevise.PkgData\nRevise.WatchList\nRevise.Rescheduler\nMethodSummary"
},

{
    "location": "dev_reference/#Function-reference-1",
    "page": "Developer reference",
    "title": "Function reference",
    "category": "section",
    "text": ""
},

{
    "location": "dev_reference/#Revise.async_steal_repl_backend",
    "page": "Developer reference",
    "title": "Revise.async_steal_repl_backend",
    "category": "function",
    "text": "Revise.async_steal_repl_backend()\n\nWait for the REPL to complete its initialization, and then call Revise.steal_repl_backend. This is necessary because code registered with atreplinit runs before the REPL is initialized, and there is no corresponding way to register code to run after it is complete.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.steal_repl_backend",
    "page": "Developer reference",
    "title": "Revise.steal_repl_backend",
    "category": "function",
    "text": "steal_repl_backend(backend = Base.active_repl_backend)\n\nReplace the REPL\'s normal backend with one that calls revise before executing any REPL input.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Functions-called-during-initialization-of-Revise-1",
    "page": "Developer reference",
    "title": "Functions called during initialization of Revise",
    "category": "section",
    "text": "Revise.async_steal_repl_backend\nRevise.steal_repl_backend"
},

{
    "location": "dev_reference/#Revise.watch_package",
    "page": "Developer reference",
    "title": "Revise.watch_package",
    "category": "function",
    "text": "watch_package(id::Base.PkgId)\n\nStart watching a package for changes to the files that define it. This function gets called via a callback registered with Base.require, at the completion of module-loading by using or import.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.parse_pkg_files",
    "page": "Developer reference",
    "title": "Revise.parse_pkg_files",
    "category": "function",
    "text": "parse_pkg_files(id::PkgId)\n\nThis function gets called by watch_package and runs when a package is first loaded. Its job is to organize the files and expressions defining the module so that later we can detect and process revisions.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.init_watching",
    "page": "Developer reference",
    "title": "Revise.init_watching",
    "category": "function",
    "text": "Revise.init_watching(files)\nRevise.init_watching(pkgdata::PkgData, files)\n\nFor every filename in files, monitor the filesystem for updates. When the file is updated, either Revise.revise_dir_queued or Revise.revise_file_queued will be called.\n\nUse the pkgdata version if the files are supplied using relative paths.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Functions-called-when-you-load-a-new-package-1",
    "page": "Developer reference",
    "title": "Functions called when you load a new package",
    "category": "section",
    "text": "Revise.watch_package\nRevise.parse_pkg_files\nRevise.init_watching"
},

{
    "location": "dev_reference/#Revise.revise_dir_queued",
    "page": "Developer reference",
    "title": "Revise.revise_dir_queued",
    "category": "function",
    "text": "revise_dir_queued(dirname)\n\nWait for one or more of the files registered in Revise.watched_files[dirname] to be modified, and then queue the corresponding files on Revise.revision_queue. This is generally called via a Revise.Rescheduler.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.revise_file_queued",
    "page": "Developer reference",
    "title": "Revise.revise_file_queued",
    "category": "function",
    "text": "revise_file_queued(pkgdata::PkgData, filename)\n\nWait for modifications to filename, and then queue the corresponding files on Revise.revision_queue. This is generally called via a Revise.Rescheduler.\n\nThis is used only on platforms (like BSD) which cannot use Revise.revise_dir_queued.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Monitoring-for-changes-1",
    "page": "Developer reference",
    "title": "Monitoring for changes",
    "category": "section",
    "text": "These functions get called on each directory or file that you monitor for revisions. These block execution until the file(s) are updated, so you should only call them from within an @async block. They work recursively: once an update has been detected and execution resumes, they schedule a revision (see Revise.revision_queue) and then call themselves on the same directory or file to wait for the next set of changes.Revise.revise_dir_queued\nRevise.revise_file_queued"
},

{
    "location": "dev_reference/#Revise.revise_file_now",
    "page": "Developer reference",
    "title": "Revise.revise_file_now",
    "category": "function",
    "text": "Revise.revise_file_now(pkgdata::PkgData, file)\n\nProcess revisions to file. This parses file and computes an expression-level diff between the current state of the file and its most recently evaluated state. It then deletes any removed methods and re-evaluates any changed expressions. Note that generally it is better to use revise as it properly handles methods that move from one file to another.\n\nid must be a key in Revise.pkgdatas, and file a key in Revise.pkgdatas[id].fileinfos.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Evaluating-changes-(revising)-and-computing-diffs-1",
    "page": "Developer reference",
    "title": "Evaluating changes (revising) and computing diffs",
    "category": "section",
    "text": "revise is the primary entry point for implementing changes. Additionally,Revise.revise_file_now"
},

{
    "location": "dev_reference/#Revise.get_method",
    "page": "Developer reference",
    "title": "Revise.get_method",
    "category": "function",
    "text": "method = get_method(sigt)\n\nGet the method method with signature-type sigt. This is used to provide the method to Base.delete_method.\n\nIf sigt does not correspond to a method, returns nothing.\n\nExamples\n\njulia> mymethod(::Int) = 1\nmymethod (generic function with 1 method)\n\njulia> mymethod(::AbstractFloat) = 2\nmymethod (generic function with 2 methods)\n\njulia> Revise.get_method(Tuple{typeof(mymethod), Int})\nmymethod(::Int64) in Main at REPL[0]:1\n\njulia> Revise.get_method(Tuple{typeof(mymethod), Float64})\nmymethod(::AbstractFloat) in Main at REPL[1]:1\n\njulia> Revise.get_method(Tuple{typeof(mymethod), Number})\n\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.get_def",
    "page": "Developer reference",
    "title": "Revise.get_def",
    "category": "function",
    "text": "success = get_def(method::Method)\n\nAs needed, load the source file necessary for extracting the code defining method. The source-file defining method must be tracked. If it is in Base, this will execute track(Base) if necessary.\n\nThis is a callback function used by CodeTracking.jl\'s definition.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Interchange-between-methods-and-signatures-1",
    "page": "Developer reference",
    "title": "Interchange between methods and signatures",
    "category": "section",
    "text": "Revise.get_method\nRevise.get_def"
},

{
    "location": "dev_reference/#Revise.parse_source",
    "page": "Developer reference",
    "title": "Revise.parse_source",
    "category": "function",
    "text": "mexs = parse_source(filename::AbstractString, mod::Module)\n\nParse the source filename, returning a ModuleExprsSigs mexs. mod is the \"parent\" module for the file (i.e., the one that included the file); if filename defines more module(s) then these will all have separate entries in mexs.\n\nIf parsing filename fails, nothing is returned.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.parse_source!",
    "page": "Developer reference",
    "title": "Revise.parse_source!",
    "category": "function",
    "text": "parse_source!(mexs::ModuleExprsSigs, filename, mod::Module)\n\nTop-level parsing of filename as included into module mod. Successfully-parsed expressions will be added to mexs. Returns mexs if parsing finished successfully, otherwise nothing is returned.\n\nSee also Revise.parse_source.\n\n\n\n\n\nsuccess = parse_source!(mod_exprs_sigs::ModuleExprsSigs, src::AbstractString, filename::AbstractString, mod::Module)\n\nParse a string src obtained by reading file as a single string. pos is the 1-based byte offset from which to begin parsing src.\n\nSee also Revise.parse_source.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Parsing-source-code-1",
    "page": "Developer reference",
    "title": "Parsing source code",
    "category": "section",
    "text": "Revise.parse_source\nRevise.parse_source!"
},

{
    "location": "dev_reference/#Revise.modulefiles",
    "page": "Developer reference",
    "title": "Revise.modulefiles",
    "category": "function",
    "text": "parentfile, included_files = modulefiles(mod::Module)\n\nReturn the parentfile in which mod was defined, as well as a list of any other files that were included to define mod. If this operation is unsuccessful, (nothing, nothing) is returned.\n\nAll files are returned as absolute paths.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Modules-and-paths-1",
    "page": "Developer reference",
    "title": "Modules and paths",
    "category": "section",
    "text": "Revise.modulefiles"
},

{
    "location": "dev_reference/#Revise.git_source",
    "page": "Developer reference",
    "title": "Revise.git_source",
    "category": "function",
    "text": "Revise.git_source(file::AbstractString, reference)\n\nRead the source-text for file from a git commit reference. The reference may be a string, Symbol, or LibGit2.Tree.\n\nExample:\n\nRevise.git_source(\"/path/to/myfile.jl\", \"HEAD\")\nRevise.git_source(\"/path/to/myfile.jl\", :abcd1234)  # by commit SHA\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.git_files",
    "page": "Developer reference",
    "title": "Revise.git_files",
    "category": "function",
    "text": "files = git_files(repo)\n\nReturn the list of files checked into repo.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Revise.git_repo",
    "page": "Developer reference",
    "title": "Revise.git_repo",
    "category": "function",
    "text": "repo, repo_path = git_repo(path::AbstractString)\n\nReturn the repo::LibGit2.GitRepo containing the file or directory path. path does not necessarily need to be the top-level directory of the repository. Also returns the repo_path of the top-level directory for the repository.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Git-integration-1",
    "page": "Developer reference",
    "title": "Git integration",
    "category": "section",
    "text": "Revise.git_source\nRevise.git_files\nRevise.git_repo"
},

{
    "location": "dev_reference/#Revise.init_worker",
    "page": "Developer reference",
    "title": "Revise.init_worker",
    "category": "function",
    "text": "Revise.init_worker(p)\n\nDefine methods on worker p that Revise needs in order to perform revisions on p. Revise itself does not need to be running on p.\n\n\n\n\n\n"
},

{
    "location": "dev_reference/#Distributed-computing-1",
    "page": "Developer reference",
    "title": "Distributed computing",
    "category": "section",
    "text": "Revise.init_worker"
},

]}
