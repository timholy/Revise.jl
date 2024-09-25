using Documenter, Revise

makedocs(;
    modules = [Revise],
    sitename = "Revise.jl",
    authors = "Tim Holy <tim.holy@gmail.com> and contributors",
    linkcheck = !("skiplinks" in ARGS),
    pages = [
        "Home" => "index.md",
        "config.md",
        "cookbook.md",
        "limitations.md",
        "debugging.md",
        "internals.md",
        "user_reference.md",
        "dev_reference.md",
    ],
)

deploydocs(
    repo = "github.com/timholy/Revise.jl.git",
    push_preview = true,
)
