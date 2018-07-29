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
    "text": "(v0.7) pkg> dev Example\n  Updating registry at `/tmp/pkgs/registries/Uncurated`\n  Updating git-repo `https://github.com/JuliaRegistries/Uncurated.git`\n Resolving package versions...\nDownloaded Example ─ v0.5.1\n  Updating `/tmp/pkgs/environments/v0.7/Project.toml`\n  [7876af07] + Example v0.5.1\n  Updating `/tmp/pkgs/environments/v0.7/Manifest.toml`\n  [7876af07] + Example v0.5.1\n\njulia> using Revise        # importantly, this must come before `using Example`\n[ Info: Precompiling module Revise\n\njulia> using Example\n\njulia> hello(\"world\")\n\"Hello, world\"\n\njulia> Example.f()\nERROR: UndefVarError: f not defined\n\njulia> edit(hello)   # opens Example.jl in the editor you have configured\n\n# Now, add a function `f() = π` and save the file\n\njulia> Example.f()\nπ = 3.1415926535897...Revise is not tied to any particular editor. (The EDITOR or JULIA_EDITOR environment variables can be used to specify your preference.)It\'s even possible to use Revise on code in Julia\'s Base module or its standard libraries: just say Revise.track(Base) or using Pkg; Revise.track(Pkg). For Base, any changes that you\'ve made since you last built Julia will be automatically incorporated; for the stdlibs, any changes since the last git commit will be incorporated.See Using Revise by default if you want Revise to be available every time you start julia."
},

{
    "location": "index.html#If-Revise-doesn\'t-work-as-expected-1",
    "page": "Home",
    "title": "If Revise doesn\'t work as expected",
    "category": "section",
    "text": "If Revise isn\'t working for you, here are some steps to try:See Configuration for information on customization options. In particular, some file systems (like NFS) might require special options.\nRevise can\'t handle all kinds of code changes; for more information, see the section on Limitations.\nTry running test Revise from the Pkg REPL-mode. If tests pass, check the documentation to make sure you understand how Revise should work.If you still encounter problems, please file an issue."
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
    "text": "Revise supports changes to code in worker processes. The code must be loaded in the main process in which Revise is running, and you must use @everywhere using Revise."
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
    "text": "Revise is based on the fact that you can change functions even when they are defined in other modules. Here\'s an example showing how you do that manually (without using Revise):julia> convert(Float64, π)\n3.141592653589793\n\njulia> # That\'s too hard, let\'s make life easier for students\n\njulia> @eval Base convert(::Type{Float64}, x::Irrational{:π}) = 3.0\nconvert (generic function with 714 methods)\n\njulia> convert(Float64, π)\n3.0Revise removes some of the tedium of manually copying and pasting code into @eval statements. To decrease the amount of re-JITting required, Revise avoids reloading entire modules; instead, it takes care to eval only the changes in your package(s), much as you would if you were doing it manually. Importantly, changes are detected in a manner that is independent of the specific line numbers in your code, so that you don\'t have to re-evaluate just because code moves around within the same file. (However, one unfortunate side effect is that line numbers may become inaccurate in backtraces.)To accomplish this, Revise uses the following overall strategy:add callbacks to Base so that Revise gets notified when new packages are loaded or new files included\nprepare source-code caches for every new file. These caches will allow Revise to detect changes when files are updated. For precompiled packages this happens on an as-needed basis, using the cached source in the *.ji file. For non-precompiled packages, Revise parses the source for each included file immediately so that the initial state is known and changes can be detected.\nmonitor the file system for changes to any of the dependent files; it immediately appends any updates to a list of file names that need future processing\nintercept the REPL\'s backend to ensure that the list of files-to-be-revised gets processed each time you execute a new command at the REPL\nwhen a revision is triggered, the source file(s) are re-parsed, and a diff between the cached version and the new version is created. eval the diff in the appropriate module(s).\nreplace the cached version of each source file with the new version, so that further changes are diffed against the most recent update.You can find more detail about Revise\'s inner workings in the Developer reference."
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
    "text": "revise()\n\neval any changes in the revision queue. See Revise.revision_queue.\n\n\n\n\n\nrevise(mod::Module)\n\nReevaluate every definition in mod, whether it was changed or not. This is useful to propagate an updated macro definition, or to force recompiling generated functions.\n\nReturns true if all revisions in mod were successfully implemented.\n\n\n\n\n\n"
},

{
    "location": "user_reference.html#Revise.track",
    "page": "User reference",
    "title": "Revise.track",
    "category": "function",
    "text": "Revise.track(Base)\nRevise.track(Core.Compiler)\nRevise.track(stdlib)\n\nTrack updates to the code in Julia\'s base directory, base/compiler, or one of its standard libraries.\n\n\n\n\n\nRevise.track(mod::Module, file::AbstractString)\nRevise.track(file::AbstractString)\n\nWatch file for updates and revise loaded code with any changes. mod is the module into which file is evaluated; if omitted, it defaults to Main.\n\n\n\n\n\n"
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
    "text": "There are really only two functions that a user would be expected to call manually: revise and Revise.track. Other user-level constructs might apply if you want to exclude Revise from watching specific packages.revise\nRevise.track\nRevise.dont_watch_pkgs\nRevise.silence"
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
    "text": "Revise.juliadir\n\nConstant specifying full path to julia top-level directory from which julia was built. This is reliable even for cross-builds.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.basesrccache",
    "page": "Developer reference",
    "title": "Revise.basesrccache",
    "category": "constant",
    "text": "Revise.basesrccache\n\nFull path to the running Julia\'s cache of source code defining Base.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Path-related-variables-1",
    "page": "Developer reference",
    "title": "Path-related variables",
    "category": "section",
    "text": "Revise.juliadir\nRevise.basesrccache"
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
    "location": "dev_reference.html#Revise.file2modules",
    "page": "Developer reference",
    "title": "Revise.file2modules",
    "category": "constant",
    "text": "Revise.file2modules\n\nGlobal variable, file2modules is the core information that allows re-evaluation of code in the proper module scope. It is a dictionary indexed by absolute paths of files; file2modules[filename] returns a value of type Revise.FileModules.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.module2files",
    "page": "Developer reference",
    "title": "Revise.module2files",
    "category": "constant",
    "text": "Revise.module2files\n\nGlobal variable, module2files holds the list of filenames used to define a particular module. This is only used by revise(MyModule) to \"refresh\" all the definitions in a module.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Internal-state-management-1",
    "page": "Developer reference",
    "title": "Internal state management",
    "category": "section",
    "text": "Revise.watched_files\nRevise.revision_queue\nRevise.included_files\nRevise.file2modules\nRevise.module2files"
},

{
    "location": "dev_reference.html#Revise.RelocatableExpr",
    "page": "Developer reference",
    "title": "Revise.RelocatableExpr",
    "category": "type",
    "text": "A RelocatableExpr is exactly like an Expr except that comparisons between RelocatableExprs ignore line numbering information.\n\nYou can use convert(Expr, rex::RelocatableExpr) to convert to an Expr and convert(RelocatableExpr, ex::Expr) for the converse. Beware that the latter operates in-place and is intended only for internal use.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.ExprsSigs",
    "page": "Developer reference",
    "title": "Revise.ExprsSigs",
    "category": "type",
    "text": "Revise.ExprsSigs\n\nstruct holding parsed source code.\n\nFields:\n\nexprs: all RelocatableExpr in the module or file\nsigs: all detected function signatures (used in method deletion)\n\nThese fields are stored as sets so that one can efficiently find the differences between two versions of the same module or file.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.ModDict",
    "page": "Developer reference",
    "title": "Revise.ModDict",
    "category": "type",
    "text": "A ModDict is an alias for Dict{Module,ExprsSigs}. It is used to organize expressions according to their module of definition.\n\nSee also FileModules.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.FileModules",
    "page": "Developer reference",
    "title": "Revise.FileModules",
    "category": "type",
    "text": "FileModules(topmod::Module, md::ModDict, [cachefile::String])\n\nStructure to hold the per-module expressions found when parsing a single file.  topmod is the current module when the file is parsed. md holds the evaluatable statements, organized by the module of their occurrence. In particular, if the file defines one or more new modules, then md contains key/value pairs for each module. If the file does not define any new modules, topmod is the only key in md.\n\nExample:\n\nSuppose MyPkg.jl has a file that looks like this:\n\n__precompile__(true)\n\nmodule MyPkg\n\nfoo(x) = x^2\n\nend\n\nThen if this module is loaded from Main, schematically the corresponding fm::FileModules looks something like\n\nfm.topmod = Main\nfm.md = Dict(Main=>ExprsSigs(OrderedSet([:(__precompile__(true))]), OrderedSet()),\n             Main.MyPkg=>ExprsSigs(OrderedSet([:(foo(x) = x^2)]), OrderedSet([:(foo(x))]))\n\nbecause the precompile statement occurs in Main, and the definition of foo occurs in Main.MyPkg.\n\nnote: Source cache files\nOptionally, a FileModule can also record the path to a cache file holding the original source code. This is applicable only for precompiled modules and Base. (This cache file is distinct from the original source file that might be edited by the developer, and it will always hold the state of the code when the package was precompiled or Julia\'s Base was built.) For such modules, the ExprsSigs will be empty for any file that has not yet been edited: the original source code gets parsed only when a revision needs to be made.Source cache files greatly reduce the overhead of using Revise.\n\nTo create a FileModules from a source file, see parse_source.\n\n\n\n\n\n"
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
    "text": "Revise.RelocatableExpr\nRevise.ExprsSigs\nRevise.ModDict\nRevise.FileModules\nRevise.WatchList"
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
    "text": "Revise.revise_file_now(file)\n\nProcess revisions to file. This parses file and computes an expression-level diff between the current state of the file and its most recently evaluated state. It then deletes any removed methods and re-evaluates any changed expressions.\n\nfile must be a key in Revise.file2modules\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.eval_revised",
    "page": "Developer reference",
    "title": "Revise.eval_revised",
    "category": "function",
    "text": "succeeded = eval_revised(revmd::ModDict, delete_methods=true)\n\nEvaluate the changes listed in revmd, which consists of deleting all the listed signatures in each .sigs field(s) (unless delete_methods=false) and evaluating expressions in the .exprs field(s).\n\nReturns true if all revisions in revmd were successfully implemented.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.revised_statements",
    "page": "Developer reference",
    "title": "Revise.revised_statements",
    "category": "function",
    "text": "revmod = revised_statements(new_defs, old_defs)\n\nReturn a Dict(Module=>changeset), revmod, listing the changes that should be eval_revised for each module to update definitions from old_defs to new_defs.  See parse_source to obtain the defs structures.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.get_method",
    "page": "Developer reference",
    "title": "Revise.get_method",
    "category": "function",
    "text": "m = get_method(mod::Module, sig)\n\nGet the method m with signature sig from module mod. This is used to provide the method to Base.delete_method. See also get_signature.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Evaluating-changes-(revising)-and-computing-diffs-1",
    "page": "Developer reference",
    "title": "Evaluating changes (revising) and computing diffs",
    "category": "section",
    "text": "Revise.revise_file_now\nRevise.eval_revised\nRevise.revised_statements\nRevise.get_method"
},

{
    "location": "dev_reference.html#Revise.parse_source",
    "page": "Developer reference",
    "title": "Revise.parse_source",
    "category": "function",
    "text": "parse_source(filename::AbstractString, mod::Module)\n\nParse the source filename, returning a pair filename => fm::FileModules (see FileModules) containing the information needed to evaluate code in file. mod is the \"parent\" module for the file (i.e., the one that included the file); if filename defines more module(s) then these will all have separate entries in fm.md.\n\nIf parsing filename fails, nothing is returned.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.parse_source!",
    "page": "Developer reference",
    "title": "Revise.parse_source!",
    "category": "function",
    "text": "success = parse_source!(md::ModDict, filename, mod::Module)\n\nTop-level parsing of filename as included into module mod. Successfully-parsed expressions will be added to md. Returns true if parsing finished successfully.\n\nSee also parse_source.\n\n\n\n\n\nsuccess = parse_source!(md::ModDict, src::AbstractString, file::Symbol, pos::Integer, mod::Module)\n\nParse a string src obtained by reading file as a single string. pos is the 1-based byte offset from which to begin parsing src.\n\nSee also parse_source.\n\n\n\n\n\nsuccess = parse_source!(md::ModDict, ex::Expr, file, mod::Module)\n\nFor a file that defines a sub-module, parse the body ex of the sub-module.  mod will be the module into which this sub-module is evaluated (i.e., included). Successfully-parsed expressions will be added to md. Returns true if parsing finished successfully.\n\nSee also parse_source.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.parse_expr!",
    "page": "Developer reference",
    "title": "Revise.parse_expr!",
    "category": "function",
    "text": "parse_expr!(md::ModDict, ex::Expr, file::Symbol, mod::Module)\n\nRecursively parse the expressions in ex, iterating over blocks and sub-module definitions. Successfully parsed expressions are added to md with key mod, and any sub-modules will be stored in md using appropriate new keys. This accomplishes two main tasks:\n\nadd parsed expressions to the source-code cache (so that later we can detect changes)\ndetermine the module into which each parsed expression is evaluated into\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.parse_module!",
    "page": "Developer reference",
    "title": "Revise.parse_module!",
    "category": "function",
    "text": "newmod = parse_module!(md::ModDict, ex::Expr, file, mod::Module)\n\nParse an expression ex that defines a new module newmod. This module is \"parented\" by mod. Source-code expressions are added to md under the appropriate module name.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.get_signature",
    "page": "Developer reference",
    "title": "Revise.get_signature",
    "category": "function",
    "text": "sig = get_signature(expr)\n\nExtract the signature from an expression expr that defines a function.\n\nIf expr does not define a function, returns nothing.\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Revise.sig_type_exprs",
    "page": "Developer reference",
    "title": "Revise.sig_type_exprs",
    "category": "function",
    "text": "typexs = sig_type_exprs(ex::Expr)\n\nFrom a function signature ex (see get_signature), generate a list typexs of concrete signature type expressions. This list will have length 1 unless ex has default arguments, in which case it will produce one type signature per valid number of supplied arguments.\n\nThese type-expressions can be evaluated in the appropriate module to obtain a Tuple-type.\n\nExamples\n\njulia> Revise.sig_type_exprs(:(foo(x::Int, y::String)))\n1-element Array{Expr,1}:\n:(Tuple{Core.Typeof(foo), Int, String})\n\njulia> Revise.sig_type_exprs(:(foo(x::Int, y::String=\"hello\")))\n2-element Array{Expr,1}:\n :(Tuple{Core.Typeof(foo), Int})\n :(Tuple{Core.Typeof(foo), Int, String})\n\n\n\n\n\n"
},

{
    "location": "dev_reference.html#Parsing-source-code-1",
    "page": "Developer reference",
    "title": "Parsing source code",
    "category": "section",
    "text": "Revise.parse_source\nRevise.parse_source!\nRevise.parse_expr!\nRevise.parse_module!\nRevise.get_signature\nRevise.sig_type_exprs"
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
