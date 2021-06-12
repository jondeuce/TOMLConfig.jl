module TOMLConfig

using Reexport
@reexport using ArgParse, TOML

import AbstractTrees
using AbstractTrees: StatelessBFS, PostOrderDFS

export Config

"""
    Config(tree::AbstractDict{String})
    Config(; filename::String)

Basic tree structure for navigating TOML file contents.
Each `Config` leaf node represents a single section of a TOML file.
Children of a `Config` node are the corresponding subsections, if they exist.

Example:

```julia
julia>cfg = Config(TOML.parse(
    \"\"\"
    a = 1

    [sec1]
        b = 2

        [sec1.sub1]
        c = 3
    \"\"\"))

TOML Config with contents:

a = 1

[sec1]
b = 2

    [sec1.sub1]
    c = 3
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

deep_getindex(d::AbstractDict, keys) = foldl((leaf, k) -> leaf[k], keys; init = d)
deep_setindex!(d::AbstractDict, v, keys) = deep_getindex(d, keys[begin:end-1])[keys[end]] = v

Base.getindex(cfg::Config, keys) = deep_getindex(cfg.leaf, keys)
Base.setindex!(cfg::Config, v, keys) = deep_setindex!(cfg.leaf, v, keys)

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

const parsing_settings = Dict{String, String}(
    "argparse_flag_delim"  => ".",
    "inherit_all_key"      => "INHERIT",
    "inherit_parent_value" => "%PARENT%",
)
inherit_all_key()        = parsing_settings["inherit_all_key"]
inherit_all_key!(s)      = parsing_settings["inherit_all_key"] = s
inherit_parent_value()   = parsing_settings["inherit_parent_value"]
inherit_parent_value!(s) = parsing_settings["inherit_parent_value"] = s
argparse_flag_delim()    = parsing_settings["argparse_flag_delim"]
argparse_flag_delim!(s)  = parsing_settings["argparse_flag_delim"] = s

"""
    populate!(cfg::Config)

Populate fields of TOML config which are specified to have default values inherited from parent sections.

Example:

```julia
julia>cfg = TOMLConfig.populate!(Config(TOML.parse(
    \"\"\"
    a = 1
    b = 2

    [sec1]
    b = \"$(inherit_parent_value())\"
    c = 3

        [sec1.sub1]
        $(inherit_all_key()) = \"$(inherit_parent_value())\"
    \"\"\")))

TOML Config with contents:

b = 2
a = 1

[sec1]
c = 3
b = 2

    [sec1.sub1]
    c = 3
    b = 2
```
"""
function populate!(cfg::Config)
    # Step 1:
    #   Inverted breadth-first search for `inherit_all_key()` with value `inherit_parent_value()`.
    #   If found, copy all key-value pairs from the immediate parent (i.e. non-recursive) into the node containing `inherit_all_key()`.
    #   Delete the `inherit_all_key()` afterwards.
    for node in reverse(collect(StatelessBFS(cfg)))
        parent, leaf = node.parent, node.leaf
        (parent === nothing) && continue
        (get(leaf, inherit_all_key(), nothing) != inherit_parent_value()) && continue
        (parent !== nothing && get(leaf, inherit_all_key(), nothing) == inherit_parent_value()) || continue
        for (k,v) in parent.leaf
            (v isa AbstractDict) && continue
            !haskey(leaf, k) && (leaf[k] = deepcopy(parent.leaf[k]))
        end
        delete!(leaf, inherit_all_key())
    end

    # Step 2:
    #   Breadth-first search for fields with value `inherit_parent_value()`.
    #   If found, copy default value from the corresponding field in the immediate parent (i.e. non-recursive).
    for node in StatelessBFS(cfg)
        parent, leaf = node.parent, node.leaf
        (parent === nothing) && continue
        for (k,v) in leaf
            (v == inherit_parent_value()) && (leaf[k] = deepcopy(parent.leaf[k]))
        end
    end

    return cfg
end

"""
    argparse_flag(node::Config, k)

Generate command flag corresponding to nested key `k` in a `Config` node.
The flag is constructed by joining the keys recursively from the parents
of the current node using the delimiter `argparse_flag_delim()` and prepending "--".

Example:

Given a `Config` node with contents
```julia
a = 1
b = 2

[sec1]
c = 3

    [sec1.sub1]
    d = 4
```

The corresponding flags that will be generated are
```julia
--a
--b
--sec1$(argparse_flag_delim())c
--sec1$(argparse_flag_delim())sub1$(argparse_flag_delim())d
```
"""
function argparse_flag(node::Config, k)
    flag = string(k)
    while true
        if node.parent === nothing
            flag = "--" * flag
            break
        else
            flag = string(node.key) * argparse_flag_delim() * flag
            node = node.parent
        end
    end
    return flag
end

"""
    ArgParseSettings(cfg::Config)

Generate `ArgParseSettings` parser from `Config`.

Example:

```julia
julia>cfg = Config(TOML.parse(
    \"\"\"
    a = 1.0
    b = 2

    [sec1]
    c = [3, 4]

        [sec1.sub1]
        d = "d"
    \"\"\"));

julia>parser = ArgParseSettings(cfg);

julia>ArgParse.show_help(parser)
usage: <PROGRAM> [--b B] [--a A] [--sec1.c [SEC1.C...]]
                 [--sec1.sub1.d SEC1.SUB1.D]

optional arguments:
  --b B                 (type: Int64, default: 2)
  --a A                 (type: Float64, default: 1.0)
  --sec1.c [SEC1.C...]  (type: Int64, default: [3, 4])
  --sec1.sub1.d SEC1.SUB1.D
                        (default: "d")
```
"""
function ArgParse.ArgParseSettings(cfg::Config)
    parser = ArgParseSettings()
    for node in reverse(collect(PostOrderDFS(cfg)))
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

function parse!(cfg::Config, args, parser::ArgParseSettings; filter_args = false)
    # Parse and merge into config
    for (k,v) in parse_args(args, parser)
        if filter_args
            # Only update `cfg` with new value if it was explicitly passed in `args`
            !any(startswith("--" * k), args) && continue
        end
        cfg[String.(split(k, argparse_flag_delim()))] = deepcopy(v)
    end
    return cfg
end

function parse!(cfg::Config, args)

    default_parser = ArgParseSettings(populate!(deepcopy(cfg)))
    parse!(cfg, args, default_parser; filter_args = true)
    updated_parser = ArgParseSettings(populate!(cfg))
    parse!(cfg, args, updated_parser)

    return cfg
end

"""
    parse_args(cfg::Config, args = isinteractive() ? String[] : ARGS)

Populate fields of TOML config which are specified to have default values inherited from parent sections.

Example:

```julia
julia>cfg = Config(TOML.parse(
    \"\"\"
    a = 1
    b = 2

    [sec1]
    b = \"$(inherit_parent_value())\"
    c = 3

        [sec1.sub1]
        $(inherit_all_key()) = \"$(inherit_parent_value())\"
    \"\"\"));

julia>config = parse_args(cfg, ["--a", "3", "--sec1.b", "5", "--sec1.c", "10"]);

julia>TOML.print(config)
```
"""
function ArgParse.parse_args(cfg::Config, args = isinteractive() ? String[] : ARGS)
    cfg = parse!(deepcopy(cfg), args)
    return cfg.leaf
end

end # module TOMLConfig
