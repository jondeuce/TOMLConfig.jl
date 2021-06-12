module TOMLConfig

using Reexport
@reexport using ArgParse, TOML

import AbstractTrees
using AbstractTrees: StatelessBFS, PostOrderDFS

export Config

"""
Basic tree structure for representing TOML file contents.
A `Config` struct represents a single section of the TOML file, the children are the subsections.

Example:

```julia
julia>cfg = Config(TOML.parse(\"\"\"
    a = 1

    [sec1]
        b = 2

        [sec1.subsec1]
        c = 3

        [sec1.subsec2]
        d = 4
        e = 5
    \"\"\"))

TOML Config with contents:

a = 1

[sec1]
b = 2

    [sec1.subsec1]
    c = 3

    [sec1.subsec2]
    e = 5
    d = 4
```
"""
struct Config
    "TOML section contents"
    leaf::AbstractDict{String, Any}

    "Node corresponding to parent TOML section, or `nothing` for the root node"
    parent::Union{Config, Nothing}

    "Key within the parent node which points to this node, or `nothing` for the root node"
    key::Union{String, Nothing}
end
Config(tree::AbstractDict{String}) = Config(tree, nothing, nothing)
Config(; filename::String) = Config(TOML.parsefile(filename))

AbstractTrees.nodetype(::Config) = Config
AbstractTrees.children(parent::Config) = [Config(leaf, parent, key) for (key, leaf) in parent.leaf if leaf isa AbstractDict]

Base.getindex(cfg::Config, keys) = foldl((leaf, k) -> leaf[k], keys; init = cfg.leaf)
Base.setindex!(cfg::Config, v, keys) = cfg[keys[begin:end-1]][keys[end]] = v

function AbstractTrees.printnode(io::IO, cfg::Config)
    if cfg.key !== nothing
        println(io, string(cfg.key) * ":")
    end
    print(io, join(["$k = $v" for (k,v) in cfg.leaf if !(v isa AbstractDict)], "\n"))
end

function Base.show(io::IO, ::MIME"text/plain", cfg::Config)
    println(io, "TOML Config with contents:\n")
    TOML.print(io, cfg.leaf)
end

function clean_toml!(cfg::Config)
    # Keys `"INHERIT"` with value `"%PARENT%"` specify that all fields from the immediate parent (i.e. non-recursive) should be copied into the child, unless that key is already present in the child
    for node in reverse(collect(StatelessBFS(cfg)))
        parent, leaf = node.parent, node.leaf
        (parent === nothing) && continue
        (get(leaf, "INHERIT", "") != "%PARENT%") && continue
        (parent !== nothing && get(leaf, "INHERIT", "") == "%PARENT%") || continue
        for (k,v) in parent.leaf
            (v isa AbstractDict) && continue
            !haskey(leaf, k) && (leaf[k] = deepcopy(parent.leaf[k]))
        end
        delete!(leaf, "INHERIT")
    end

    # Fields with value "%PARENT%" take default values from the corresponding field of their parent
    for node in StatelessBFS(cfg)
        parent, leaf = node.parent, node.leaf
        (parent === nothing) && continue
        for (k,v) in leaf
            (v == "%PARENT%") && (leaf[k] = deepcopy(parent.leaf[k]))
        end
    end

    return cfg
end

function argparse_flag(node::Config, k)
    flag = string(k)
    while true
        if node.parent === nothing
            flag = "--" * flag
            break
        else
            flag = string(node.key) * "." * flag
            node = node.parent
        end
    end
    return flag
end

# Generate arg parser
function ArgParse.ArgParseSettings(cfg::Config)
    parser = ArgParseSettings()
    for node in PostOrderDFS(cfg)
        for (k,v) in node.leaf
            if v isa AbstractDict
                continue
            end
            props = Dict{Symbol,Any}(:default => deepcopy(v))
            if v isa AbstractVector
                props[:arg_type] = eltype(v)
                props[:nargs] = '*'
            else
                props[:arg_type] = typeof(v)
            end
            add_arg_table!(parser, argparse_flag(node, k), props)
        end
    end
    return parser
end

function parse_args!(cfg::Config, args, parser::ArgParseSettings; filter_args = false)
    # Parse and merge into config
    for (k,v) in parse_args(args, parser)
        if filter_args
            # Only update `cfg` with new value if it was explicitly passed in `args`
            !any(startswith("--" * k), args) && continue
        end
        cfg[String.(split(k, "."))] = deepcopy(v)
    end
    return cfg
end

# Command line parsing
function parse_args!(
        cfg::Config,
        args = isinteractive() ? String[] : ARGS
    )

    default_parser = ArgParseSettings(clean_toml!(deepcopy(cfg)))
    parse_args!(cfg, args, default_parser; filter_args = true)
    updated_parser = ArgParseSettings(clean_toml!(cfg))
    parse_args!(cfg, args, updated_parser)

    return cfg
end

end # module TOMLConfig
