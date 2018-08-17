var documenterSearchIndex = {"docs": [

{
    "location": "index.html#",
    "page": "Home",
    "title": "Home",
    "category": "page",
    "text": ""
},

{
    "location": "index.html#Introduction-to-Revise-1",
    "page": "Home",
    "title": "Introduction to Revise",
    "category": "section",
    "text": "Revise.jl may help you keep your Julia sessions running longer, reducing the need to restart when you make changes to code. With Revise, you can be in the middle of a session and then update packages, switch git branches or stash/unstash code, and/or edit the source code; typically, the changes will be incorporated into the very next command you issue from the REPL. This can save you the overhead of restarting, loading packages, and waiting for code to JIT-compile."
},

{
    "location": "index.html#Installation-1",
    "page": "Home",
    "title": "Installation",
    "category": "section",
    "text": "You can obtain Revise using Julia\'s Pkg REPL-mode (hitting ] as the first character of the command prompt):(v0.7) pkg> add Reviseor with using Pkg; Pkg.add(\"Revise\")."
},

{
    "location": "index.html#Usage-example-1",
    "page": "Home",
    "title": "Usage example",
    "category": "section",
    "text": "(v0.7) pkg> dev Example\n[...output related to installation...]\n\njulia> using Revise        # importantly, this must come before `using Example`\n\njulia> using Example\n\njulia> hello(\"world\")\n\"Hello, world\"\n\njulia> Example.f()\nERROR: UndefVarError: f not defined\n\njulia> edit(hello)   # opens Example.jl in the editor you have configured\n\n# Now, add a function `f() = π` and save the file\n\njulia> Example.f()\nπ = 3.1415926535897...Revise is not tied to any particular editor. (The EDITOR or JULIA_EDITOR environment variables can be used to specify your preference.)It\'s even possible to use Revise on code in Julia\'s Base module or its standard libraries: just say Revise.track(Base) or using Pkg; Revise.track(Pkg). For Base, any changes that you\'ve made since you last built Julia will be automatically incorporated; for the stdlibs, any changes since the last git commit will be incorporated.See Using Revise by default if you want Revise to be available every time you start julia."
},

{
    "location": "index.html#What-Revise-can-track-1",
    "page": "Home",
    "title": "What Revise can track",
    "category": "section",
    "text": "Revise is fairly ambitious: if all is working you should be able to track changes toany package that you load with import or using\nany script you load with includet\nany file defining Base julia itself (with Revise.track(Base))\nany file defining Core.Compiler (with Revise.track(Core.Compiler))\nany of Julia\'s standard libraries (with, e.g., using Unicode; Revise.track(Unicode))The last two require that you clone Julia and build it yourself from source."
},

{
    "location": "index.html#If-Revise-doesn\'t-work-as-expected-1",
    "page": "Home",
    "title": "If Revise doesn\'t work as expected",
    "category": "section",
    "text": "If Revise isn\'t working for you, here are some steps to try:See Configuration for information on customization options. In particular, some file systems (like NFS) might require special options.\nRevise can\'t handle all kinds of code changes; for more information, see the section on Limitations.\nTry running test Revise from the Pkg REPL-mode. If tests pass, check the documentation to make sure you understand how Revise should work. If they fail (especially if it mirrors functionality that you need and isn\'t working), see Fixing a broken or partially-working installation for some suggestions.If you still encounter problems, please file an issue."
},

{
    "location": "config.html#",
    "page": "Configuration",
    "title": "Configuration",
    "category": "page",
    "text": ""
},

{
    "location": "config.html#Configuration-1",
    "page": "Configuration",
    "title": "Configuration",
    "category": "section",
    "text": ""
},

{
    "location": "config.html#Using-Revise-by-default-1",
    "page": "Configuration",
    "title": "Using Revise by default",
    "category": "section",
    "text": "If you like Revise, you can ensure that every Julia session uses it by adding the following to your .julia/config/startup.jl file:try\n    @eval using Revise\n    # Turn on Revise\'s automatic-evaluation behavior\n    Revise.async_steal_repl_backend()\ncatch err\n    @warn \"Could not load Revise.\"\nend"
},

{
    "location": "config.html#System-configuration-1",
    "page": "Configuration",
    "title": "System configuration",
    "category": "section",
    "text": "note: Linux-specific configuration\nRevise needs to be notified by your filesystem about changes to your code, which means that the files that define your modules need to be watched for updates. Some systems impose limits on the number of files and directories that can be watched simultaneously; if this limit is hit, on Linux this can result in a fairly cryptic error likeERROR: start_watching (File Monitor): no space left on device (ENOSPC)The cure is to increase the number of files that can be watched, by executingecho 65536 | sudo tee -a /proc/sys/fs/inotify/max_user_watchesat the Linux prompt. This should be done automatically by Revise\'s deps/build.jl script, but if you encounter the above error consider increasing it further (e.g., to 524288, which will allocate half a gigabyte of RAM to file-watching). For more information see issue #26.You can prevent the build script from trying to increase the number of watched files by creating an empty file /path/to/Revise/deps/user_watches. For example, from the Linux prompt use touch /path/to/Revise/deps/user_watches. This will prevent Revise from prompting you for your password every time the build script runs (e.g., when a new version of Revise is installed)."
},

{
    "location": "config.html#Configuration-options-1",
    "page": "Configuration",
    "title": "Configuration options",
    "category": "section",
    "text": "Revise can be configured by setting environment variables. These variables have to be set before you execute using Revise, because these environment variables are parsed only during execution of Revise\'s __init__ function.There are several ways to set these environment variables:If you are Using Revise by default then you can include statements like ENV[\"JULIA_REVISE\"] = \"manual\" in your .julia/config/startup.jl file prior to the line @eval using Revise.\nOn Unix systems, you can set variables in your shell initialization script (e.g., put lines like export JULIA_REVISE=manual in your .bashrc file if you use bash).\nOn Unix systems, you can launch Julia from the Unix prompt as $ JULIA_REVISE=manual julia to set options for just that session.The function of specific environment variables is described below."
},

{
    "location": "config.html#Manual-revision:-JULIA_REVISE-1",
    "page": "Configuration",
    "title": "Manual revision: JULIA_REVISE",
    "category": "section",
    "text": "By default, Revise processes any modified source files every time you enter a command at the REPL. However, there might be times where you\'d prefer to exert manual control over the timing of revisions. Revise looks for an environment variable JULIA_REVISE, and if it is set to anything other than \"auto\" it will require that you manually call revise() to update code.Alternatively, you can omit the call to Revise.async_steal_repl_backend() from your startup.jl file (see Using Revise by default)."
},

{
    "location": "config.html#Polling-and-NFS-mounted-code-directories:-JULIA_REVISE_POLL-1",
    "page": "Configuration",
    "title": "Polling and NFS-mounted code directories: JULIA_REVISE_POLL",
    "category": "section",
    "text": "Revise works by scanning your filesystem for changes to the files that define your code. Different operating systems and file systems offer differing levels of support for this feature. Because NFS doesn\'t support inotify, if your code is stored on an NFS-mounted volume you should force Revise to use polling: Revise will periodically (every 5s) scan the modification times of each dependent file. You turn on polling by setting the environment variable JULIA_REVISE_POLL to the string \"1\" (e.g., JULIA_REVISE_POLL=1 in a bash script).If you\'re using polling, you may have to wait several seconds before changes take effect. Consequently polling is not recommended unless you have no other alternative."
},

{
    "location": "config.html#User-scripts:-JULIA_REVISE_INCLUDE-1",
    "page": "Configuration",
    "title": "User scripts: JULIA_REVISE_INCLUDE",
    "category": "section",
    "text": "By default, Revise only tracks files that have been required as a consequence of a using or import statement; files loaded by include are not tracked, unless you explicitly use Revise.track(filename). However, you can turn on automatic tracking by setting the environment variable JULIA_REVISE_INCLUDE to the string \"1\" (e.g., JULIA_REVISE_INCLUDE=1 in a bash script)."
},

{
    "location": "config.html#Fixing-a-broken-or-partially-working-installation-1",
    "page": "Configuration",
    "title": "Fixing a broken or partially-working installation",
    "category": "section",
    "text": "During certain types of usage you might receive messages likeWarning: /some/system/path/stdlib/v1.0/SHA/src is not an existing directory, Revise is not watchingand this indicates that some of Revise\'s functionality is broken.Revise\'s test suite covers a broad swath of functionality, and so if something is broken a good first start towards resolving the problem is to run pkg> test Revise. Note that some test failures may not really matter to you personally: if, for example, you don\'t plan on hacking on Julia\'s compiler then you may not be concerned about failures related to Revise.track(Core.Compiler). However, because Revise is used by Rebugger and it is common to step into Base methods while debugging, there may be more cases than you might otherwise expect in which you might wish for Revise\'s more \"advanced\" functionality.In the majority of cases, failures come down to Revise having trouble locating source code on your drive. This problem should be fixable, because Revise includes functionality to update its links to source files, as long as it knows what to do.Here are some possible test warnings and errors, and steps you might take to fix them:Error: Package Example not found in current path: This (tiny) package is only used for testing purposes, and gets installed automatically if you do pkg> test Revise, but not if you include(\"runtests.jl\") from inside Revise\'s test/ directory. You can prevent the error with pkg> add Example.\nBase & stdlib file paths: Test Failed at /some/path...  Expression: isfile(Revise.basesrccache) This failure is quite serious, and indicates that you will be unable to access code in Base. To fix this, look for a file called \"base.cache\" somewhere in your Julia install or build directory (for the author, it is at /home/tim/src/julia-1.0/usr/share/julia/base.cache). Now compare this with the value of Revise.basesrccache. (If you\'re getting this failure, presumably they are different.) An important \"top level\" directory is Sys.BINDIR; if they differ already at this level, consider adding a symbolic link from the location pointed at by Sys.BINDIR to the corresponding top-level directory in your actual Julia installation. You\'ll know you\'ve succeeded in specifying it correctly when, after restarting Julia, Revise.basesrccache points to the correct file and Revise.juliadir points to the directory that contains base/. If this workaround is not possible or does not succeed, please file an issue with a description of why you can\'t use it and/or\ndetails from versioninfo and information about how you obtained your Julia installation;\nthe values of Revise.basesrccache and Revise.juliadir, and the actual paths to base.cache and the directory containing the running Julia\'s base/;\nwhat you attempted when trying to fix the problem;\nif possible, your best understanding of why this failed to fix it.\nskipping Core.Compiler and stdlibs tests due to lack of git repo: this likely indicates that you downloaded a Julia binary rather than building Julia from source. While Revise should be able to access the code in Base, at the current time it is not possible for Revise to access julia\'s stdlibs unless you clone Julia\'s repository and build it from source.\nskipping git tests because Revise is not under development: this warning should be harmless. Revise has built-in functionality for extracting source code using git, and it uses itself (i.e., its own git repository) for testing purposes. These tests run only if you have checked out Revise for development (pkg> dev Revise) or on the continuous integration servers (Travis and Appveyor)."
},

{
    "location": "limitations.html#",
    "page": "Limitations",
    "title": "Limitations",
    "category": "page",
    "text": ""
},

{
    "location": "limitations.html#Limitations-1",
    "page": "Limitations",
    "title": "Limitations",
    "category": "section",
    "text": "Revise (really, Julia itself) can handle many kinds of code changes, but a few may require special treatment:"
},

{
    "location": "limitations.html#Method-deletion-1",
    "page": "Limitations",
    "title": "Method deletion",
    "category": "section",
    "text": "Sometimes you might wish to change a method\'s type signature or number of arguments, or remove a method specialized for specific types. To prevent \"stale\" methods from being called by dispatch, Revise automatically accommodates method deletion, for example:f(x) = 1\nf(x::Int) = 2 # delete this methodIf you save the file, the next time you call f(5) from the REPL you will get 1, and methods(f) will show a single method. Revise even handles more complex situations, such as functions with default arguments: the definitiondefaultargs(x, y=0, z=1.0f0) = x + y + zgenerates 3 different methods (with one, two, and three arguments respectively), and editing this definition todefaultargs(x, yz=(0,1.0f0)) = x + yz[1] + yz[2]requires that we delete all 3 of the original methods and replace them with two new methods.However, to find the right method(s) to delete, Revise needs to be able to parse source code to extract the signature of the to-be-deleted method(s). Unfortunately, a few valid constructs are quite difficult to parse properly. For example, methods generated with code:for T in (Int, Float64, String)   # edit this line to `for T in (Int, Float64)`\n    @eval mytypeof(x::$T) = $T\nendwill not disappear from the method lists until you restart.note: Note\nTo delete a method manually, you can use m = @which foo(args...) to obtain a method, and then call Base.delete_method(m)."
},

{
    "location": "limitations.html#Macros-and-generated-functions-1",
    "page": "Limitations",
    "title": "Macros and generated functions",
    "category": "section",
    "text": "If you change a macro definition or methods that get called by @generated functions outside their quote block, these changes will not be propagated to functions that have already evaluated the macro or generated function.You may explicitly call revise(MyModule) to force reevaluating every definition in module MyModule. Note that when a macro changes, you have to revise all of the modules that use it."
},

{
    "location": "limitations.html#Distributed-computing-(multiple-workers)-1",
    "page": "Limitations",
    "title": "Distributed computing (multiple workers)",
    "category": "section",
    "text": "Revise supports changes to code in worker processes. The code must be loaded in the main process in which Revise is running, and you must use @everywhere using Revise.Revise cannot handle changes in anonymous functions used in remotecalls. Consider the following module definition:module ParReviseExample\nusing Distributed\n\ngreet(x) = println(\"Hello, \", x)\n\nfoo() = for p in workers()\n    remotecall_fetch(() -> greet(\"Bar\"), p)\nend\n\nend # moduleChanging the remotecall to remotecall_fetch((x) -> greet(\"Bar\"), p, 1) will fail, because the new anonymous function is not defined on all workers. The workaround is to write the code to use named functions, e.g.,module ParReviseExample\nusing Distributed\n\ngreet(x) = println(\"Hello, \", x)\ngreetcaller() = greet(\"Bar\")\n\nfoo() = for p in workers()\n    remotecall_fetch(greetcaller, p)\nend\n\nend # moduleand the corresponding edit to the code would be to modify it to greetcaller(x) = greet(\"Bar\") and remotecall_fetch(greetcaller, p, 1)."
},

{
    "location": "limitations.html#Changes-that-Revise-cannot-handle-1",
    "page": "Limitations",
    "title": "Changes that Revise cannot handle",
    "category": "section",
    "text": "Finally, there are some kinds of changes that Revise cannot incorporate into a running Julia session:changes to type definitions\nfile or module renames\nconflicts between variables and functions sharing the same nameThese kinds of changes require that you restart your Julia session."
},

{
    "location": "internals.html#",
    "page": "How Revise works",
    "title": "How Revise works",
    "category": "page",
    "text": ""
},

{
    "location": "internals.html#How-Revise-works-1",
    "page": "How Revise works",
    "title": "How Revise works",
    "category": "section",
    "text": "Revise is based on the fact that you can change functions even when they are defined in other modules. Here\'s an example showing how you do that manually (without using Revise):julia> convert(Float64, π)\n3.141592653589793\n\njulia> # That\'s too hard, let\'s make life easier for students\n\njulia> @eval Base convert(::Type{Float64}, x::Irrational{:π}) = 3.0\nconvert (generic function with 714 methods)\n\njulia> convert(Float64, π)\n3.0Revise removes some of the tedium of manually copying and pasting code into @eval statements. To decrease the amount of re-JITting required, Revise avoids reloading entire modules; instead, it takes care to eval only the changes in your package(s), much as you would if you were doing it manually. Importantly, changes are detected in a manner that is independent of the specific line numbers in your code, so that you don\'t have to re-evaluate just because code moves around within the same file. (One unfortunate side effect is that line numbers may become inaccurate in backtraces, but Revise takes pains to correct these, see below.)To accomplish this, Revise uses the following overall strategy:add callbacks to Base so that Revise gets notified when new packages are loaded or new files included\nprepare source-code caches for every new file. These caches will allow Revise to detect changes when files are updated. For precompiled packages this happens on an as-needed basis, using the cached source in the *.ji file. For non-precompiled packages, Revise parses the source for each included file immediately so that the initial state is known and changes can be detected.\nmonitor the file system for changes to any of the dependent files; it immediately appends any updates to a list of file names that need future processing\nintercept the REPL\'s backend to ensure that the list of files-to-be-revised gets processed each time you execute a new command at the REPL\nwhen a revision is triggered, the source file(s) are re-parsed, and a diff between the cached version and the new version is created. eval the diff in the appropriate module(s).\nreplace the cached version of each source file with the new version, so that further changes are diffed against the most recent update."
},

{
    "location": "internals.html#The-structure-of-Revise\'s-internal-representation-1",
    "page": "How Revise works",
    "title": "The structure of Revise\'s internal representation",
    "category": "section",
    "text": "(Image: diagram)Figure notes: Nodes represent primary objects in Julia\'s compilation pipeline. Arrows and their labels represent functions or data structures that allow you to move from one node to another. Red (\"destructive\") paths force recompilation of dependent functions.Revise bridges between text files (your source code) and compiled code. Revise consequently maintains data structures that parallel Julia\'s own internal processing of code. When dealing with a source-code file, you start with strings, parse them to obtain Julia expressions, evaluate them to obtain Julia objects, and (where appropriate, e.g., for methods) compile them to machine code. This will be called the forward workflow. Revise sets up a few key structures that allow it to progress from files to modules to Julia expressions and types.Revise also sets up a backward workflow, proceeding from compiled code to Julia types back to Julia expressions. This workflow is useful, for example, when dealing with errors: the stack traces displayed by Julia link from the compiled code back to the source files. To make this possible, Julia builds \"breadcrumbs\" into compiled code that store the filename and line number at which each expression was found. However, these links are static, meaning they are set up once (when the code is compiled) and are not updated when the source file changes. Because trivial manipulations to source files (e.g., the insertion of blank lines and/or comments) can change the line number of an expression without necessitating its recompilation, Revise implements a way of correcting these line numbers before they are displayed to the user. This capability requires that Revise proceed backward from the compiled objects to something resembling the original text file."
},

{
    "location": "internals.html#Terminology-1",
    "page": "How Revise works",
    "title": "Terminology",
    "category": "section",
    "text": "A few convenience terms are used throughout: definition, signature-expression, and signature-type. These terms are illustrated using the following example:<p><pre><code class=\"language-julia\">function <mark>print_item(io::IO, item, ntimes::Integer=1, pre::String=\"\")</mark>\n    print(io, pre)\n    for i = 1:ntimes\n        print(io, item)\n    end\nend</code></pre></p>This represents the definition of a method. Definitions are stored as expressions, using a Revise.RelocatableExpr. The highlighted portion is the signature-expression, specifying the name, argument names and their types, and (if applicable) type-parameters of the method.From the signature-expression we can generate one or more signature-types. Since this function has two default arguments, this signature-expression generates three signature-types, each corresponding to a different valid way of calling this method:Tuple{typeof(print_item),IO,Any}                    # print_item(io, item)\nTuple{typeof(print_item),IO,Any,Integer}            # print_item(io, item, 2)\nTuple{typeof(print_item),IO,Any,Integer,String}     # print_item(io, item, 2, \"  \")In Revise\'s internal code, a definition is often represented with a variable def, a signature-expression with sigex, and a signature-type with sigt."
},

{
    "location": "internals.html#Core-data-structures-and-representations-1",
    "page": "How Revise works",
    "title": "Core data structures and representations",
    "category": "section",
    "text": "Two \"maps\" are central to Revise\'s inner workings: the DefMap links definition=>signature-types (the forward workflow), while the SigtMap links from signature-type=>definition (the backward workflow). Concretely, SigtMap is just a Dict mapping sigt=>def. Of note, a stack frame typically contains a link to a method, which stores the equivalent of sigt; consequently, this information allows one to look up the corresponding def.The DefMap is a bit more complex and has important constraints:For expressions that do not define a method, it is just def=>nothing\nFor expressions that do define a method, it is def=>([sigt1, ...], lineoffset). [sigt1, ...] is the list of signature-types generated from def (often just one, but more in the case of methods with default arguments). lineoffset is the correction to be added to the currently-compiled code\'s internal line numbers needed to make them match the current state of the source file.\nDefMap is represented as an OrderedDict so as to preserve the sequence in which expressions occur in the file. This can be important particularly for updating macro definitions, which affect the expansion of later code. The order is maintained so as to match the current ordering of the source-file, which is not necessarily the same as the ordering when these expressions were last evaled.\nEach key in the DefMap (the definition RelocatableExpr) is the most recently evaled version of the expression. This has an important consequence: the line numbers in the def (which are still present, even though not used for equality comparisons) correspond to the ones in compiled code. If the file is parsed again, comparing the line numbers embedded in two \"equal\" def exprs (the original and the new one) allows us to accurately determine the current value of lineoffset.Importantly, modules can be \"reconstructed\" from the keys of DefMap (or collection of DefMaps, if the module involves multiple files or has sub-modules), since they hold the complete ordered set of expressions that would be evaled to define the module.The DefMap and SigtMap are grouped in a Revise.FMMaps, which are then organized by the file in which they occur and their module of evaluation."
},

{
    "location": "internals.html#An-example-1",
    "page": "How Revise works",
    "title": "An example",
    "category": "section",
    "text": "Consider a module, Items, defined by the following two source files:Items.jl:__precompile__(false)\n\nmodule Items\n\ninclude(\"indents.jl\")\n\nfunction print_item(io::IO, item, ntimes::Integer=1, pre::String=indent(item))\n    print(io, pre)\n    for i = 1:ntimes\n        print(io, item)\n    end\nend\n\nendindents.jl:indent(::UInt16) = 2\nindent(::UInt8)  = 4indents.jl is particularly simple: Revise represents it as \"indents.jl\"=>Dict(Items=>fmm1), specifying the filename, module(s) into which its code is evaled, and corresponding FMMaps. Because indents.jl only contains code from a single module (Items), the Dict has just one entry. fmm1 looks like this:fmm1 = FMMaps(DefMap(:(indent(::UInt16) = 2) => ([Tuple{typeof(indent),UInt16}], 0),\n                     :(indent(::UInt8) = 4)  => ([Tuple{typeof(indent),UInt8}], 0)\n                     ),\n              SigtMap(Tuple{typeof(indent),UInt16} => :(indent(::UInt16) = 2),\n                      Tuple{typeof(indent),UInt8}  => :(indent(::UInt8) = 4)\n                      ))The lineoffsets are initially set to 0 when the code is first compiled, but these may be updated if the source file is changed.Items.jl is represented with a bit more complexity, \"Items.jl\"=>Dict(Main=>fmm2, Main.Items=>fmm3). This is because Items.jl contains one expression (the __precompile__ statement) that is evaled in Main, and other expressions that are evaled in Items. Concretely,fmm2 = FMMaps(DefMap(:(__precompile__(false)) => nothing),\n              SigtMap())\nfmm3 = FMMaps(DefMap(:(include(\"indents.jl\")) => nothing,\n                     def => ([Tuple{typeof(print_item),IO,Any},\n                              Tuple{typeof(print_item),IO,Any,Integer},\n                              Tuple{typeof(print_item),IO,Any,Integer,String}], 0)),\n              SigtMap(Tuple{typeof(print_item),IO,Any} => def,\n                      Tuple{typeof(print_item),IO,Any,Integer} => def,\n                      Tuple{typeof(print_item),IO,Any,Integer,String} => def))where here def is the expression defining print_item."
},

{
    "location": "internals.html#Revisions-and-computing-diffs-1",
    "page": "How Revise works",
    "title": "Revisions and computing diffs",
    "category": "section",
    "text": "When the file system notifies Revise that a file has been modified, Revise re-parses the file and assigns the expressions to the appropriate modules, creating a Revise.FileModules fmnew. It then compares fmnew against fmref, the reference object that is synchronized to code as it was evaled. The following actions are taken:if a def entry in fmref is equal to one fmnew, the expression is \"unchanged\" except possibly for line number. The lineoffset in fmref is updated as needed.\nif a def entry in fmref is not present in fmnew, that entry is deleted and any corresponding methods are also deleted.\nif a def entry in fmnew is not present in fmref, it is evaled and then added to fmref.Technically, a new fmref is generated every time to ensure that the expressions are ordered as in fmnew; however, conceptually this is better thought of as an updating of fmref, after which fmnew is discarded."
},

{
    "location": "internals.html#Internal-API-1",
    "page": "How Revise works",
    "title": "Internal API",
    "category": "section",
    "text": "You can find more detail about Revise\'s inner workings in the Developer reference."
},

{
    "location": "user_reference.html#",
    "page": "User reference",
    "title": "User reference",
    "category": "page",
    "text": ""
},

{
    "location": "user_reference.html#Revise.revise",
    "page": "User reference",
    "title": "Revise.revise",
    "category": "function",
    "text": "revise()\n\neval any changes in the revision queue. See Revise.revision_queue.\n\n\n\n\n\nrevise(mod::Module)\n\nReevaluate every definition in mod, whether it was changed or not. This is useful to propagate an updated macro definition, or to force recompiling generated functions.\n\n\n\n\n\n"
},

{
    "location": "user_reference.html#Revise.track",
    "page": "User reference",
    "title": "Revise.track",
    "category": "function",
    "text": "Revise.track(Base)\nRevise.track(Core.Compiler)\nRevise.track(stdlib)\n\nTrack updates to the code in Julia\'s base directory, base/compiler, or one of its standard libraries.\n\n\n\n\n\nRevise.track(mod::Module, file::AbstractString)\nRevise.track(file::AbstractString)\n\nWatch file for updates and revise loaded code with any changes. mod is the module into which file is evaluated; if omitted, it defaults to Main.\n\n\n\n\n\n"
},

{
    "location": "user_reference.html#Revise.includet",
    "page": "User reference",
    "title": "Revise.includet",
    "category": "function",
    "text": "includet(filename)\n\nLoad filename and track any future changes to it. includet is deliberately non-recursive, so if filename loads any other files, they will not be automatically tracked. (See Revise.track to set it up manually.)\n\nincludet is intended for \"user scripts,\" e.g., a file you use locally for a specific purpose such as loading a specific data set or performing some kind of analysis. Do not use includet for packages, as those should be handled by using or import. If using and import aren\'t working, you may have packages in a non-standard location; try fixing it with something like push!(LOAD_PATH, \"/path/to/my/private/repos\").\n\n\n\n\n\n"
},

{
    "location": "user_reference.html#Revise.dont_watch_pkgs",
    "page": "User reference",
    "title": "Revise.dont_watch_pkgs",
    "category": "constant",
    "text": "Revise.dont_watch_pkgs\n\nGlobal variable, use push!(Revise.dont_watch_pkgs, :MyPackage) to prevent Revise from tracking changes to MyPackage. You can do this from the REPL or from your .julia/config/startup.jl file.\n\nSee also Revise.silence.\n\n\n\n\n\n"
},

{
    "location": "user_reference.html#Revise.silence",
    "page": "User reference",
    "title": "Revise.silence",
    "category": "function",
    "text": "Revise.silence(pkg)\n\nSilence warnings about not tracking changes to package pkg.\n\n\n\n\n\n"
},

{
    "location": "user_reference.html#User-reference-1",
    "page": "User reference",
    "title": "User reference",
    "category": "section",
    "text": "There are really only three functions that a user would be expected to call manually: revise, includet, and Revise.track. Other user-level constructs might apply if you want to exclude Revise from watching specific packages.revise\nRevise.track\nincludet\nRevise.dont_watch_pkgs\nRevise.silence"
},

{
    "location": "dev_reference.html#",
    "page": "Developer reference",
    "title": "Developer reference",
    "category": "page",
    "text": ""
},

{
    "location": "dev_reference.html#Developer-reference-1",
    "page": "Developer reference",
    "title": "Developer reference",
    "category": "section",
    "text": ""
},

{
    "location": "dev_reference.html#Internal-global-variables-1",
    "page": "Developer reference",
    "title": "Internal global variables",
    "category": "section",
    "text": ""
},

{
    "location": "dev_reference.html#Revise.watching_files",
    "page": "Developer reference",
    "title": "Revise.watching_files",
    "category": "constant",
    "text": "Revise.watching_files[]\n\nReturns true if we watch files rather than their containing directory. FreeBSD and NFS-mounted systems should watch files, otherwise we prefer to watch directories.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.polling_files",
    "page": "Developer reference",
    "title": "Revise.polling_files",
    "category": "constant",
    "text": "Revise.polling_files[]\n\nReturns true if we should poll the filesystem for changes to the files that define loaded code. It is preferable to avoid polling, instead relying on operating system notifications via FileWatching.watch_file. However, NFS-mounted filesystems (and perhaps others) do not support file-watching, so for code stored on such filesystems you should turn polling on.\n\nSee the documentation for the JULIA_REVISE_POLL environment variable.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.tracking_Main_includes",
    "page": "Developer reference",
    "title": "Revise.tracking_Main_includes",
    "category": "constant",
    "text": "Revise.tracking_Main_includes[]\n\nReturns true if files directly included from the REPL should be tracked. The default is false. See the documentation regarding the JULIA_REVISE_INCLUDE environment variable to customize it.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Configuration-related-variables-1",
    "page": "Developer reference",
    "title": "Configuration-related variables",
    "category": "section",
    "text": "These are set during execution of Revise\'s __init__ function.Revise.watching_files\nRevise.polling_files\nRevise.tracking_Main_includes"
},

{
    "location": "dev_reference.html#Revise.juliadir",
    "page": "Developer reference",
    "title": "Revise.juliadir",
    "category": "constant",
    "text": "Revise.juliadir\n\nConstant specifying full path to julia top-level source directory. This should be reliable even for local builds, cross-builds, and binary installs.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.basesrccache",
    "page": "Developer reference",
    "title": "Revise.basesrccache",
    "category": "constant",
    "text": "Revise.basesrccache\n\nFull path to the running Julia\'s cache of source code defining Base.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.basebuilddir",
    "page": "Developer reference",
    "title": "Revise.basebuilddir",
    "category": "constant",
    "text": "Revise.basebuilddir\n\nJulia\'s top-level directory when Julia was built, as recorded by the entries in Base._included_files.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Path-related-variables-1",
    "page": "Developer reference",
    "title": "Path-related variables",
    "category": "section",
    "text": "Revise.juliadir\nRevise.basesrccache\nRevise.basebuilddir"
},

{
    "location": "dev_reference.html#Revise.watched_files",
    "page": "Developer reference",
    "title": "Revise.watched_files",
    "category": "constant",
    "text": "Revise.watched_files\n\nGlobal variable, watched_files[dirname] returns the collection of files in dirname that we\'re monitoring for changes. The returned value has type WatchList.\n\nThis variable allows us to watch directories rather than files, reducing the burden on the OS.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.revision_queue",
    "page": "Developer reference",
    "title": "Revise.revision_queue",
    "category": "constant",
    "text": "Revise.revision_queue\n\nGlobal variable, revision_queue holds the names of files that we need to revise, meaning that these files have changed since we last processed a revision. This list gets populated by callbacks that watch directories for updates.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.included_files",
    "page": "Developer reference",
    "title": "Revise.included_files",
    "category": "constant",
    "text": "Revise.included_files\n\nGlobal variable, included_files gets populated by callbacks we register with include. It\'s used to track non-precompiled packages and, optionally, user scripts (see docs on JULIA_REVISE_INCLUDE).\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.fileinfos",
    "page": "Developer reference",
    "title": "Revise.fileinfos",
    "category": "constant",
    "text": "Revise.fileinfos\n\nfileinfos is the core information that tracks the relationship between source code and julia objects, and allows re-evaluation of code in the proper module scope. It is a dictionary indexed by absolute paths of files; fileinfos[filename] returns a value of type Revise.FileInfo.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.module2files",
    "page": "Developer reference",
    "title": "Revise.module2files",
    "category": "constant",
    "text": "Revise.module2files\n\nmodule2files holds the list of filenames used to define a particular module. This is only used by revise(MyModule) to \"refresh\" all the definitions in a module.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Internal-state-management-1",
    "page": "Developer reference",
    "title": "Internal state management",
    "category": "section",
    "text": "Revise.watched_files\nRevise.revision_queue\nRevise.included_files\nRevise.fileinfos\nRevise.module2files"
},

{
    "location": "dev_reference.html#Revise.RelocatableExpr",
    "page": "Developer reference",
    "title": "Revise.RelocatableExpr",
    "category": "type",
    "text": "A RelocatableExpr is exactly like an Expr except that comparisons between RelocatableExprs ignore line numbering information. This allows one to detect that two expressions are the same no matter where they appear in a file.\n\nYou can use convert(Expr, rex::RelocatableExpr) to convert to an Expr and convert(RelocatableExpr, ex::Expr) for the converse. Beware that the latter operates in-place and is intended only for internal use.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.DefMap",
    "page": "Developer reference",
    "title": "Revise.DefMap",
    "category": "type",
    "text": "DefMap\n\nMaps def=>nothing or def=>([sigt1,...], lineoffset), where:\n\ndef is an expression\nthe value is nothing if def does not define a method\nif it does define a method, sigt1... are the signature-types and lineoffset is the difference between the line number when the method was compiled and the current state of the source file.\n\nSee the documentation page How Revise works for more information.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.SigtMap",
    "page": "Developer reference",
    "title": "Revise.SigtMap",
    "category": "type",
    "text": "SigtMap\n\nMaps sigt=>def, where sigt is the signature-type of a method and def the expression defining the method.\n\nSee the documentation page How Revise works for more information.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.FMMaps",
    "page": "Developer reference",
    "title": "Revise.FMMaps",
    "category": "type",
    "text": "FMMaps\n\nsource=>sigtypes and sigtypes=>source mappings for a particular file/module combination. See the documentation page How Revise works for more information.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.FileModules",
    "page": "Developer reference",
    "title": "Revise.FileModules",
    "category": "type",
    "text": "FileModules\n\nFor a particular source file, the corresponding FileModules is an OrderedDict(mod1=>fmm1, mod2=>fmm2), mapping the collection of modules \"active\" in the file (the parent module and any submodules it defines) to their corresponding FMMaps.\n\nThe first key is guaranteed to be the module into which this file was included.\n\nTo create a FileModules from a source file, see parse_source.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.FileInfo",
    "page": "Developer reference",
    "title": "Revise.FileInfo",
    "category": "type",
    "text": "FileInfo(fm::FileModules, cachefile=\"\")\n\nStructure to hold the per-module expressions found when parsing a single file. fm holds the FileModules for the file.\n\nOptionally, a FileInfo can also record the path to a cache file holding the original source code. This is applicable only for precompiled modules and Base. (This cache file is distinct from the original source file that might be edited by the developer, and it will always hold the state of the code when the package was precompiled or Julia\'s Base was built.) When a cache is available, fm will be empty until the file gets edited: the original source code gets parsed only when a revision needs to be made.\n\nSource cache files greatly reduce the overhead of using Revise.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.WatchList",
    "page": "Developer reference",
    "title": "Revise.WatchList",
    "category": "type",
    "text": "Revise.WatchList\n\nA struct for holding files that live inside a directory. Some platforms (OSX) have trouble watching too many files. So we watch parent directories, and keep track of which files in them should be tracked.\n\nFields:\n\ntimestamp: mtime of last update\ntrackedfiles: Set of filenames\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Types-1",
    "page": "Developer reference",
    "title": "Types",
    "category": "section",
    "text": "Revise.RelocatableExpr\nRevise.DefMap\nRevise.SigtMap\nRevise.FMMaps\nRevise.FileModules\nRevise.FileInfo\nRevise.WatchList"
},

{
    "location": "dev_reference.html#Function-reference-1",
    "page": "Developer reference",
    "title": "Function reference",
    "category": "section",
    "text": ""
},

{
    "location": "dev_reference.html#Revise.async_steal_repl_backend",
    "page": "Developer reference",
    "title": "Revise.async_steal_repl_backend",
    "category": "function",
    "text": "Revise.async_steal_repl_backend()\n\nWait for the REPL to complete its initialization, and then call steal_repl_backend. This is necessary because code registered with atreplinit runs before the REPL is initialized, and there is no corresponding way to register code to run after it is complete.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.steal_repl_backend",
    "page": "Developer reference",
    "title": "Revise.steal_repl_backend",
    "category": "function",
    "text": "steal_repl_backend(backend = Base.active_repl_backend)\n\nReplace the REPL\'s normal backend with one that calls revise before executing any REPL input.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Functions-called-during-initialization-of-Revise-1",
    "page": "Developer reference",
    "title": "Functions called during initialization of Revise",
    "category": "section",
    "text": "Revise.async_steal_repl_backend\nRevise.steal_repl_backend"
},

{
    "location": "dev_reference.html#Revise.watch_package",
    "page": "Developer reference",
    "title": "Revise.watch_package",
    "category": "function",
    "text": "watch_package(id::Base.PkgId)\n\nStart watching a package for changes to the files that define it. This function gets called via a callback registered with Base.require, at the completion of module-loading by using or import.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.parse_pkg_files",
    "page": "Developer reference",
    "title": "Revise.parse_pkg_files",
    "category": "function",
    "text": "parse_pkg_files(modsym)\n\nThis function gets called by watch_package and runs when a package is first loaded. Its job is to organize the files and expressions defining the module so that later we can detect and process revisions.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.init_watching",
    "page": "Developer reference",
    "title": "Revise.init_watching",
    "category": "function",
    "text": "Revise.init_watching(files)\n\nFor every filename in files, monitor the filesystem for updates. When the file is updated, either revise_dir_queued or revise_file_queued will be called.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Functions-called-when-you-load-a-new-package-1",
    "page": "Developer reference",
    "title": "Functions called when you load a new package",
    "category": "section",
    "text": "Revise.watch_package\nRevise.parse_pkg_files\nRevise.init_watching"
},

{
    "location": "dev_reference.html#Revise.revise_dir_queued",
    "page": "Developer reference",
    "title": "Revise.revise_dir_queued",
    "category": "function",
    "text": "revise_dir_queued(dirname)\n\nWait for one or more of the files registered in Revise.watched_files[dirname] to be modified, and then queue the corresponding files on Revise.revision_queue. This is generally called within an @async.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.revise_file_queued",
    "page": "Developer reference",
    "title": "Revise.revise_file_queued",
    "category": "function",
    "text": "revise_file_queued(filename)\n\nWait for modifications to filename, and then queue the corresponding files on Revise.revision_queue. This is generally called within an @async.\n\nThis is used only on platforms (like BSD) which cannot use revise_dir_queued.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Monitoring-for-changes-1",
    "page": "Developer reference",
    "title": "Monitoring for changes",
    "category": "section",
    "text": "These functions get called on each directory or file that you monitor for revisions. These block execution until the file(s) are updated, so you should only call them from within an @async block. They work recursively: once an update has been detected and execution resumes, they schedule a revision (see Revise.revision_queue) and then call themselves on the same directory or file to wait for the next set of changes.Revise.revise_dir_queued\nRevise.revise_file_queued"
},

{
    "location": "dev_reference.html#Revise.revise_file_now",
    "page": "Developer reference",
    "title": "Revise.revise_file_now",
    "category": "function",
    "text": "Revise.revise_file_now(file)\n\nProcess revisions to file. This parses file and computes an expression-level diff between the current state of the file and its most recently evaluated state. It then deletes any removed methods and re-evaluates any changed expressions.\n\nfile must be a key in Revise.fileinfos\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.eval_revised",
    "page": "Developer reference",
    "title": "Revise.eval_revised",
    "category": "function",
    "text": "fmrep = eval_revised(fmnew::FileModules, fmref::FileModules)\n\nImplement the changes from fmref to fmnew, returning a replacement FileModules fmrep.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Evaluating-changes-(revising)-and-computing-diffs-1",
    "page": "Developer reference",
    "title": "Evaluating changes (revising) and computing diffs",
    "category": "section",
    "text": "Revise.revise_file_now\nRevise.eval_revised"
},

{
    "location": "dev_reference.html#Revise.get_method",
    "page": "Developer reference",
    "title": "Revise.get_method",
    "category": "function",
    "text": "method = get_method(sigt)\n\nGet the method method with signature-type sigt. This is used to provide the method to Base.delete_method. See also get_signature.\n\nIf sigt does not correspond to a method, returns nothing.\n\nExamples\n\njulia> mymethod(::Int) = 1\nmymethod (generic function with 1 method)\n\njulia> mymethod(::AbstractFloat) = 2\nmymethod (generic function with 2 methods)\n\njulia> Revise.get_method(Tuple{typeof(mymethod), Int})\nmymethod(::Int64) in Main at REPL[0]:1\n\njulia> Revise.get_method(Tuple{typeof(mymethod), Float64})\nmymethod(::AbstractFloat) in Main at REPL[1]:1\n\njulia> Revise.get_method(Tuple{typeof(mymethod), Number})\n\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.get_def",
    "page": "Developer reference",
    "title": "Revise.get_def",
    "category": "function",
    "text": "rex = get_def(method::Method)\n\nReturn the RelocatableExpr defining method. The source-file defining method must be tracked. If it is in Base, this will execute track(Base) if necessary.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Interchange-between-methods-and-signatures-1",
    "page": "Developer reference",
    "title": "Interchange between methods and signatures",
    "category": "section",
    "text": "Revise.get_method\nRevise.get_def"
},

{
    "location": "dev_reference.html#Revise.parse_source",
    "page": "Developer reference",
    "title": "Revise.parse_source",
    "category": "function",
    "text": "fm = parse_source(filename::AbstractString, mod::Module)\n\nParse the source filename, returning a FileModules fm. mod is the \"parent\" module for the file (i.e., the one that included the file); if filename defines more module(s) then these will all have separate entries in fm.\n\nIf parsing filename fails, nothing is returned.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.parse_source!",
    "page": "Developer reference",
    "title": "Revise.parse_source!",
    "category": "function",
    "text": "parse_source!(fm::FileModules, filename, mod::Module)\n\nTop-level parsing of filename as included into module mod. Successfully-parsed expressions will be added to fm. Returns fm if parsing finished successfully, otherwise nothing is returned.\n\nSee also parse_source.\n\n\n\n\n\nsuccess = parse_source!(fm::FileModules, src::AbstractString, file::Symbol, pos::Integer, mod::Module)\n\nParse a string src obtained by reading file as a single string. pos is the 1-based byte offset from which to begin parsing src.\n\nSee also parse_source.\n\n\n\n\n\nsuccess = parse_source!(fm::FileModules, ex::Expr, file, mod::Module)\n\nFor a file that defines a sub-module, parse the body ex of the sub-module.  mod will be the module into which this sub-module is evaluated (i.e., included). Successfully-parsed expressions will be added to fm. Returns true if parsing finished successfully.\n\nSee also parse_source.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.parse_expr!",
    "page": "Developer reference",
    "title": "Revise.parse_expr!",
    "category": "function",
    "text": "parse_expr!(fm::FileModules, ex::Expr, file::Symbol, mod::Module)\n\nRecursively parse the expressions in ex, iterating over blocks and sub-module definitions. Successfully parsed expressions are added to fm with key mod, and any sub-modules will be stored in fm using appropriate new keys. This accomplishes two main tasks:\n\nadd parsed expressions to the source-code cache (so that later we can detect changes)\ndetermine the module into which each parsed expression is evaluated into\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.parse_module!",
    "page": "Developer reference",
    "title": "Revise.parse_module!",
    "category": "function",
    "text": "newmod = parse_module!(fm::FileModules, ex::Expr, file, mod::Module)\n\nParse an expression ex that defines a new module newmod. This module is \"parented\" by mod. Source-code expressions are added to fm under the appropriate module name.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.funcdef_expr",
    "page": "Developer reference",
    "title": "Revise.funcdef_expr",
    "category": "function",
    "text": "exf = funcdef_expr(ex)\n\nRecurse, if necessary, into ex until the first function definition expression is found.\n\nExample\n\njulia> Revise.funcdef_expr(quote\n       \"\"\"\n       A docstring\n       \"\"\"\n       @inline foo(x) = 5\n       end)\n:(foo(x) = begin\n          #= REPL[31]:5 =#\n          5\n      end)\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.get_signature",
    "page": "Developer reference",
    "title": "Revise.get_signature",
    "category": "function",
    "text": "sigex = get_signature(expr)\n\nExtract the signature from an expression expr that defines a function.\n\nIf expr does not define a function, returns nothing.\n\nExamples\n\njulia> Revise.get_signature(quote\n       function count_different(x::AbstractVector{T}, y::AbstractVector{S}) where {S,T}\n           sum(x .!= y)\n       end\n       end)\n:(count_different(x::AbstractVector{T}, y::AbstractVector{S}) where {S, T})\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.get_callexpr",
    "page": "Developer reference",
    "title": "Revise.get_callexpr",
    "category": "function",
    "text": "callex = get_callexpr(sigex::ExLike)\n\nReturn the \"call\" expression for a signature-expression sigex. (This strips out :where statements.)\n\nExample\n\njulia> Revise.get_callexpr(:(nested(x::A) where A<:AbstractVector{T} where T))\n:(nested(x::A))\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.sig_type_exprs",
    "page": "Developer reference",
    "title": "Revise.sig_type_exprs",
    "category": "function",
    "text": "typexs = sig_type_exprs(sigex::Expr)\n\nFrom a function signature-expression sigex (see get_signature), generate a list typexs of concrete signature type expressions. This list will have length 1 unless sigex has default arguments, in which case it will produce one type signature per valid number of supplied arguments.\n\nThese type-expressions can be evaluated in the appropriate module to obtain a Tuple-type.\n\nExamples\n\njulia> Revise.sig_type_exprs(:(foo(x::Int, y::String)))\n1-element Array{Expr,1}:\n :(Tuple{Core.Typeof(foo), Int, String})\n\njulia> Revise.sig_type_exprs(:(foo(x::Int, y::String=\"hello\")))\n2-element Array{Expr,1}:\n :(Tuple{Core.Typeof(foo), Int})\n :(Tuple{Core.Typeof(foo), Int, String})\n\njulia> Revise.sig_type_exprs(:(foo(x::AbstractVector{T}, y) where T))\n1-element Array{Expr,1}:\n :(Tuple{Core.Typeof(foo), AbstractVector{T}, Any} where T)\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.argtypeexpr",
    "page": "Developer reference",
    "title": "Revise.argtypeexpr",
    "category": "function",
    "text": "typeex1, typeex2, ... = argtypeexpr(ex...)\n\nReturn expressions that specify the types assigned to each argument in a method signature. Returns :Any if no type is assigned to a specific argument. It also skips keyword arguments.\n\nex... should be arguments 2:end of a :call expression (i.e., skipping over the function name).\n\nExamples\n\njulia> sigex = :(varargs(x, rest::Int...))\n:(varargs(x, rest::Int...))\n\njulia> Revise.argtypeexpr(Revise.get_callexpr(sigex).args[2:end]...)\n(:Any, :(Vararg{Int}))\n\njulia> sigex = :(complexargs(w::Vector{T}, @nospecialize(x::Integer), y, z::String=\"\"; kwarg::Bool=false) where T)\n:(complexargs(w::Vector{T}, #= REPL[39]:1 =# @nospecialize(x::Integer), y, z::String=\"\"; kwarg::Bool=false) where T)\n\njulia> Revise.argtypeexpr(Revise.get_callexpr(sigex).args[2:end]...)\n(:(Vector{T}), :Integer, :Any, :String)\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Parsing-source-code-1",
    "page": "Developer reference",
    "title": "Parsing source code",
    "category": "section",
    "text": "Revise.parse_source\nRevise.parse_source!\nRevise.parse_expr!\nRevise.parse_module!\nRevise.funcdef_expr\nRevise.get_signature\nRevise.get_callexpr\nRevise.sig_type_exprs\nRevise.argtypeexpr"
},

{
    "location": "dev_reference.html#Revise.git_source",
    "page": "Developer reference",
    "title": "Revise.git_source",
    "category": "function",
    "text": "Revise.git_source(file::AbstractString, reference)\n\nRead the source-text for file from a git commit reference. The reference may be a string, Symbol, or LibGit2.Tree.\n\nExample:\n\nRevise.git_source(\"/path/to/myfile.jl\", \"HEAD\")\nRevise.git_source(\"/path/to/myfile.jl\", :abcd1234)  # by commit SHA\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.git_files",
    "page": "Developer reference",
    "title": "Revise.git_files",
    "category": "function",
    "text": "files = git_files(repo)\n\nReturn the list of files checked into repo.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.git_repo",
    "page": "Developer reference",
    "title": "Revise.git_repo",
    "category": "function",
    "text": "repo, repo_path = git_repo(path::AbstractString)\n\nReturn the repo::LibGit2.GitRepo containing the file or directory path. path does not necessarily need to be the top-level directory of the repository. Also returns the repo_path of the top-level directory for the repository.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Git-integration-1",
    "page": "Developer reference",
    "title": "Git integration",
    "category": "section",
    "text": "Revise.git_source\nRevise.git_files\nRevise.git_repo"
},

]}
