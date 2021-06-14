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

# Example

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

# Define getters to access struct fields, since `getproperty` is overloaded for convenience below
getleaf(cfg::Config) = getfield(cfg, :leaf)
getparent(cfg::Config) = getfield(cfg, :parent)
getkey(cfg::Config) = getfield(cfg, :key)

recurse_getindex(d::AbstractDict, keys) = foldl((leaf, k) -> leaf[k], keys; init = d)
recurse_setindex!(d::AbstractDict, v, keys) = recurse_getindex(d, keys[begin:end-1])[keys[end]] = v
recurse_convert_keytype(d::AbstractDict, T = Symbol) = Dict(T(k) => v isa AbstractDict ? recurse_convert_keytype(v, T) : v for (k,v) in d)

function Base.getproperty(cfg::Config, k::Symbol)
    v = getleaf(cfg)[String(k)]
    if v isa AbstractDict
        Config(v, cfg, String(k))
    else
        v
    end
end
Base.setproperty!(cfg::Config, k::Symbol, v) = getleaf(cfg)[String(k)] = v

AbstractTrees.nodetype(::Config) = Config
AbstractTrees.children(parent::Config) = [Config(leaf, parent, key) for (key, leaf) in getleaf(parent) if leaf isa AbstractDict]

function AbstractTrees.printnode(io::IO, cfg::Config)
    if getkey(cfg) !== nothing
        println(io, string(getkey(cfg)) * ":")
    end
    print(io, join(["$k = $v" for (k,v) in getleaf(cfg) if !(v isa AbstractDict)], "\n"))
end

function Base.show(io::IO, ::MIME"text/plain", cfg::Config)
    println(io, "TOML Config with contents:\n")
    TOML.print(io, getleaf(cfg))
end

const parsing_settings = Dict{String, String}(
    "inherit_all_key"      => "INHERIT",
    "inherit_parent_value" => "%PARENT%",
    "flag_delim"           => ".",
)
_inherit_all_key()        = parsing_settings["inherit_all_key"]
_inherit_all_key!(v)      = parsing_settings["inherit_all_key"] = String(v)
_inherit_parent_value()   = parsing_settings["inherit_parent_value"]
_inherit_parent_value!(v) = parsing_settings["inherit_parent_value"] = String(v)
_flag_delim()             = parsing_settings["flag_delim"]
_flag_delim!(v)           = parsing_settings["flag_delim"] = String(v)

"""
    populate!(cfg::Config)

Populate fields of TOML config which are specified to have default values inherited from parent sections.

# Example

```julia
julia>cfg = TOMLConfig.populate!(Config(TOML.parse(
    \"\"\"
    a = 1
    b = 2

    [sec1]
    b = \"$(_inherit_parent_value())\"
    c = 3

        [sec1.sub1]
        $(_inherit_all_key()) = \"$(_inherit_parent_value())\"
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
    #   Inverted breadth-first search for `_inherit_all_key()` with value `_inherit_parent_value()`.
    #   If found, copy all key-value pairs from the immediate parent (i.e. non-recursive) into the node containing `_inherit_all_key()`.
    #   Delete the `_inherit_all_key()` afterwards.
    for node in reverse(collect(StatelessBFS(cfg)))
        parent, leaf = getparent(node), getleaf(node)
        (parent === nothing) && continue
        (get(leaf, _inherit_all_key(), nothing) != _inherit_parent_value()) && continue
        (parent !== nothing && get(leaf, _inherit_all_key(), nothing) == _inherit_parent_value()) || continue
        for (k,v) in getleaf(parent)
            (v isa AbstractDict) && continue
            !haskey(leaf, k) && (leaf[k] = deepcopy(getleaf(parent)[k]))
        end
        delete!(leaf, _inherit_all_key())
    end

    # Step 2:
    #   Breadth-first search for fields with value `_inherit_parent_value()`.
    #   If found, copy default value from the corresponding field in the immediate parent (i.e. non-recursive).
    for node in StatelessBFS(cfg)
        parent, leaf = getparent(node), getleaf(node)
        (parent === nothing) && continue
        for (k,v) in leaf
            (v == _inherit_parent_value()) && (leaf[k] = deepcopy(getleaf(parent)[k]))
        end
    end

    return cfg
end

"""
    argparse_flag(node::Config, k)

Generate command flag corresponding to nested key `k` in a `Config` node.
The flag is constructed by joining the keys recursively from the parents
of the current node using the delimiter `_flag_delim()` and prepending "--".

# Example

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
--sec1$(_flag_delim())c
--sec1$(_flag_delim())sub1$(_flag_delim())d
```
"""
function argparse_flag(node::Config, k)
    flag = string(k)
    while true
        if getparent(node) === nothing
            flag = "--" * flag
            break
        else
            flag = string(getkey(node)) * _flag_delim() * flag
            node = getparent(node)
        end
    end
    return flag
end

"""
    ArgParseSettings(cfg::Config)

Generate `ArgParseSettings` parser from `Config`.

# Example

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

julia>ArgParse.show_help(parser; exit_when_done = false)
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
function ArgParse.ArgParseSettings(cfg::Config; kwargs...)
    parser = ArgParseSettings(; kwargs...)
    for node in reverse(collect(PostOrderDFS(cfg)))
        for (k,v) in getleaf(node)
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
        ks = String.(split(k, _flag_delim()))
        recurse_setindex!(getleaf(cfg), deepcopy(v), ks)
    end
    return cfg
end

function parse!(cfg::Config, args; kwargs...)

    default_parser = ArgParseSettings(populate!(deepcopy(cfg)); kwargs...)
    parse!(cfg, args, default_parser; filter_args = true)
    updated_parser = ArgParseSettings(populate!(cfg); kwargs...)
    parse!(cfg, args, updated_parser)

    return cfg
end

"""
    ArgParse.parse_args(
        cfg::Config,
        args = isinteractive() ? String[] : ARGS;
        as_dict = false,
        as_symbols = false,
        inherit_all_key = "$(_inherit_all_key())",
        inherit_parent_value = "$(_inherit_parent_value())",
        flag_delim = "$(_flag_delim())",
        kwargs...
    )

Parse TOML configuration struct with command line arguments `args`.

# Arguments:
* `cfg::Config`: TOML configuration settings
* `args`: vector of arguments to be parsed

# Keywords:
* `as_dict`: if true, return config as a dictionary with `String` keys, otherwise return a `Config` struct
* `as_symbols`: if true and `as_dict=true`, return config dictionary with `Symbol` keys
* `inherit_all_key`: if this key is found in a TOML section, all fields from the immediate parent section (i.e., non-recursive) should be inherited
* `inherit_parent_value`: if this value is found in a TOML section, it is replaced with the value corresponding to the same key in the immediate parent section (i.e., non-recursive)
* `flag_delim`: command line flags for keys in nested TOML sections are formed by joining all parent keys together with this delimiter
* `kwargs`: remaining keyword arguments are forwarded to `ArgParseSettings` constructor internally

# Example

```julia
julia>cfg = Config(TOML.parse(
    \"\"\"
    a = 1
    b = 2

    [sec1]
    b = \"$(_inherit_parent_value())\"
    c = 3

        [sec1.sub1]
        $(_inherit_all_key()) = \"$(_inherit_parent_value())\"
    \"\"\"));

julia>parsed_args = parse_args(cfg, ["--a", "3", "--sec1.b", "5", "--sec1.c", "10"]);
TOML Config with contents:

b = 2
a = 3

[sec1]
c = 10
b = 5

    [sec1.sub1]
    c = 10
    b = 5
```
"""
function ArgParse.parse_args(
        cfg::Config,
        args::AbstractVector{<:AbstractString} = isinteractive() ? String[] : ARGS;
        as_dict::Bool                          = false,
        as_symbols::Bool                       = false,
        inherit_all_key::AbstractString        = _inherit_all_key(),
        inherit_parent_value::AbstractString   = _inherit_parent_value(),
        flag_delim::AbstractString             = _flag_delim(),
        kwargs...
    )
    _inherit_all_key!(inherit_all_key)
    _inherit_parent_value!(inherit_parent_value)
    _flag_delim!(flag_delim)
    cfg = parse!(deepcopy(cfg), args; kwargs...)

    if as_dict
        if as_symbols
            return recurse_convert_keytype(getleaf(cfg), Symbol)
        else
            return getleaf(cfg)
        end
    else
        return cfg
    end
end

end # module TOMLConfig
