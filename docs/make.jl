using Documenter, Revise

makedocs(
    modules = [Revise],
    clean = false,
    format = :html,
    sitename = "Revise.jl",
    authors = "Tim Holy",
    linkcheck = !("skiplinks" in ARGS),
    pages = [
        "Home" => "index.md",
        "config.md",
        "limitations.md",
        "internals.md",
        "user_reference.md",
        "dev_reference.md",
    ],
    # # Use clean URLs, unless built as a "local" build
    # html_prettyurls = !("local" in ARGS),
#    html_canonical = "https://juliadocs.github.io/Revise.jl/stable/",
)

deploydocs(
    repo = "github.com/timholy/Revise.jl.git",
    target = "build",
    julia = "1.0",
    deps = nothing,
    make = nothing,
)
