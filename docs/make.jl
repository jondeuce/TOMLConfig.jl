push!(LOAD_PATH, joinpath(@__DIR__, ".."))
using Documenter, TOMLConfig

makedocs(;
    modules = [TOMLConfig],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
    ),
    sitename = "TOMLConfig.jl",
    authors = "Jonathan Doucette",
    pages = [
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo = "github.com/jondeuce/TOMLConfig.jl.git",
    push_preview = true,
    deploy_config = Documenter.GitHubActions(),
)
