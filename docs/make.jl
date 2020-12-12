using Documenter, Revise

makedocs(
    modules = [Revise],
    clean = false,
    format = Documenter.HTML(prettyurls = get(ENV, "CI", nothing) == "true"),
    sitename = "Revise.jl",
    authors = "Tim Holy",
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
