module TOMLConfig

using AbstractTrees, Dates

using Reexport
@reexport using ArgParse, TOML

export Config

"""
    Config(tree::AbstractDict{String})
    Config(; filename::String)

Basic tree structure for navigating TOML file contents.
Each `Config` leaf node represents a single section of a TOML file.
Children of a `Config` node are the corresponding TOML subsections, if they exist.

# Examples

```jldoctest
julia> cfg = Config(TOML.parse(
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

julia> cfg.sec1
TOML Config with contents:

b = 2

[sub1]
c = 3

julia> cfg.sec1.sub1
TOML Config with contents:

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
recurse_convert_keytype(d::AbstractDict, ::Type{K} = Symbol) where {K} = Dict{K, Any}(K(k) => v isa AbstractDict ? recurse_convert_keytype(v, K) : v for (k,v) in d)
recurse_convert_valtype(d::AbstractDict, ::Type{V} = Symbol) where {V} = Dict{keytype(d), Any}(k => v isa AbstractDict ? recurse_convert_valtype(v, V) : V(v) for (k,v) in d)
recurse_convert_keyvaltype(d::AbstractDict, ::Type{K} = Symbol, ::Type{V} = Symbol) where {K, V} = Dict{K, Any}(K(k) => v isa AbstractDict ? recurse_convert_keyvaltype(v, K, V) : V(v) for (k,v) in d)

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
AbstractTrees.children(parent::Config) = [Config(leaf, parent, key) for (key, leaf) in getleaf(parent) if leaf isa AbstractDict && arg_key() ∉ keys(leaf)]

function AbstractTrees.printnode(io::IO, cfg::Config)
    if getkey(cfg) !== nothing
        println(io, getkey(cfg) * ":")
    end
    print(io, join(["$k = $v" for (k,v) in getleaf(cfg) if !(v isa AbstractDict)], "\n"))
end

function Base.show(io::IO, ::MIME"text/plain", cfg::Config)
    println(io, "TOML Config with contents:\n")
    TOML.print(io, getleaf(cfg))
end

default_parser_settings() = Dict{String, String}(
    "arg_key"              => "_ARG_",
    "arg_required_value"   => "_REQUIRED_",
    "flag_delim"           => ".",
    "inherit_all_key"      => "_INHERIT_",
    "inherit_parent_value" => "_PARENT_",
)

const _parser_settings = default_parser_settings()
parser_settings()      = _parser_settings

arg_key()              = parser_settings()["arg_key"]
arg_required_value()   = parser_settings()["arg_required_value"]
flag_delim()           = parser_settings()["flag_delim"]
inherit_all_key()      = parser_settings()["inherit_all_key"]
inherit_parent_value() = parser_settings()["inherit_parent_value"]

"""
    parser_settings!(;
        arg_key = "$(arg_key())",
        arg_required_value = "$(arg_required_value())",
        flag_delim = "$(flag_delim())",
        inherit_all_key = "$(inherit_all_key())",
        inherit_parent_value = "$(inherit_parent_value())",
    )

Customize global settings for parsing `Config` structs.
To restore default settings, use `TOMLConfig.parser_settings!()`.

# Keywords:
* `arg_key`: if this key is found in a TOML section, the rest of the section is interpreted as properties for the argument table entry
* `arg_required_value`: if this value is found in a TOML section, the `required = true` is passed to the argument table entry
* `inherit_all_key`: if this key is found in a TOML section, all fields from the immediate parent section (i.e., non-recursive) should be inherited
* `inherit_parent_value`: if this value is found in a TOML section, it is replaced with the value corresponding to the same key in the immediate parent section (i.e., non-recursive)
* `flag_delim`: command line flags for keys in nested TOML sections are formed by joining all parent keys together with this delimiter
"""
function parser_settings!(; kwargs...)
    for (k,v) in merge!(default_parser_settings(), recurse_convert_keyvaltype(kwargs, String, String))
        if k ∈ keys(parser_settings())
            parser_settings()[k] = string(v)
        else
            error("Unknown parser setting: $(k). Possible settings are: $(join(sort(collect(keys(default_parser_settings()))), ", ")).")
        end
    end
end

"""
    defaults!(cfg::Config)

Populate fields of TOML config which are specified to have default values inherited from parent sections.

# Examples

```jldoctest
julia> cfg = TOMLConfig.defaults!(Config(TOML.parse(
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
function defaults!(cfg::Config)
    # Step 1:
    #   Inverted breadth-first search for `inherit_all_key()` with value `inherit_parent_value()`.
    #   If found, copy all key-value pairs from the immediate parent (i.e. non-recursive) into the node containing `inherit_all_key()`.
    #   Delete the `inherit_all_key()` afterwards.
    for node in reverse(collect(StatelessBFS(cfg)))
        parent, leaf = getparent(node), getleaf(node)
        if parent !== nothing && get(leaf, inherit_all_key(), nothing) == inherit_parent_value()
            for (k,v) in getleaf(parent)
                if !(v isa AbstractDict) && !haskey(leaf, k)
                    # If key `k` is not already present in the current leaf, inherit value `v` from the parent leaf
                    leaf[k] = deepcopy(getleaf(parent)[k])
                end
            end
            delete!(leaf, inherit_all_key())
        end
    end

    # Step 2:
    #   Breadth-first search for fields with value `inherit_parent_value()`.
    #   If found, copy default value from the corresponding field in the immediate parent (i.e. non-recursive).
    for node in StatelessBFS(cfg)
        parent, leaf = getparent(node), getleaf(node)
        if parent !== nothing
            for (k,v) in leaf
                if v == inherit_parent_value()
                    leaf[k] = deepcopy(getleaf(parent)[k])
                end
            end
        end
    end

    return cfg
end

"""
    argparse_flag(node::Config, k::String)

Generate command flag corresponding to nested key `k` in a `Config` node.
The flag is constructed by joining the keys recursively from the parents
of the current node using the delimiter `flag_delim()` and prepending "--".

# Examples

Given a `Config` node with contents
```jldoctest
a = 1
b = 2

[sec1]
c = 3

    [sec1.sub1]
    d = 4
```

The corresponding flags that will be generated are
```jldoctest
--a
--b
--sec1$(flag_delim())c
--sec1$(flag_delim())sub1$(flag_delim())d
```
"""
function argparse_flag(node::Config, k::String)
    flag = k
    while true
        if getparent(node) === nothing
            flag = "--" * flag
            return flag
        else
            flag = getkey(node) * flag_delim() * flag
            node = getparent(node)
        end
    end
end

"""
    ArgParse.add_arg_table!(settings::ArgParseSettings, cfg::Config)

Populate `settings` argument table using configuration `cfg`.

# Examples

```jldoctest
julia> cfg = Config(TOML.parse(
    \"\"\"
    a = 1.0
    b = 2

    [sec1]
    c = [3, 4]

        [sec1.sub1]
        d = "d"
    \"\"\"));

julia> settings = add_arg_table!(ArgParseSettings(), cfg);

julia> ArgParse.show_help(settings; exit_when_done = false)
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
function ArgParse.add_arg_table!(settings::ArgParseSettings, cfg::Config)
    # Populate settings argument table
    for node in reverse(collect(PostOrderDFS(cfg)))
        for (k,v) in getleaf(node)
            if !(v isa AbstractDict)
                # Add to arg table using specified value as the default
                props = Dict{Symbol,Any}()
                props[:default] = deepcopy(v)
                props[:required] = false

                if v isa AbstractVector
                    props[:arg_type] = eltype(v)
                    props[:nargs] = '*'
                else
                    props[:arg_type] = typeof(v)
                end

                add_arg_table!(settings, argparse_flag(node, k), props)

            elseif arg_key() ∈ keys(v)
                props, v = deepcopy(v), v[arg_key()]
                props = delete!(props, arg_key())
                props = recurse_convert_keytype(props, Symbol)

                # Special-casing specific properties
                if :arg_type ∈ keys(props)
                    arg_type_dict = Dict{String, DataType}("Any" => Any, "DateTime" => DateTime, "Time" => Time, "Date" => Date, "Bool" => Bool, "Int64" => Int64, "Float64" => Float64, "String" => String)
                    @assert props[:arg_type] ∈ keys(arg_type_dict)
                    props[:arg_type] = arg_type_dict[props[:arg_type]]
                end

                if :nargs ∈ keys(props)
                    nargs_dict = Dict{String, Char}("A" => 'A', "?" => '?', "*" => '*', "+" => '+', "R" => 'R')
                    @assert props[:nargs] isa Int || props[:nargs] ∈ keys(nargs_dict)
                    if !(props[:nargs] isa Int)
                        props[:nargs] = nargs_dict[props[:nargs]]
                    end
                end

                # Add to arg table using user specified props
                if v == arg_required_value()
                    get!(props, :required, true)
                else
                    get!(props, :default, deepcopy(v))
                    get!(props, :required, false)
                    if v isa AbstractVector
                        get!(props, :arg_type, eltype(v))
                        get!(props, :nargs, '*')
                    else
                        get!(props, :arg_type, typeof(v))
                    end
                end

                add_arg_table!(settings, argparse_flag(node, k), props)
            end
        end
    end

    return settings
end

"""
    ArgParse.parse_args(
        [args_list::Vector, [settings::ArgParseSettings,]] cfg::Config;
        as_dict = false,
        as_symbols = false,
        kwargs...
    )

Parse TOML configuration struct with command line arguments `args_list`.

# Arguments:
* `args_list::Vector`: vector of arguments to be parsed
* `settings::ArgParseSettings`: settings struct which will be configured according to `cfg`
* `cfg::Config`: TOML configuration settings

# Keywords:
* `as_dict`: if true, return config as a dictionary with `String` keys, otherwise return a `Config` struct
* `as_symbols`: if true and `as_dict=true`, return config dictionary with `Symbol` keys
* `kwargs...`: additional keyword arguments can be passed to customize the global parser settings; see `TOMLConfig.parser_settings!`. Note that these settings remain persistent on subsequent calls to `parse_args`; use `TOMLConfig.parser_settings!()` to restore all defaults.

# Examples

```jldoctest
julia> cfg = Config(TOML.parse(
    \"\"\"
    a = 1
    b = 2

    [sec1]
    b = \"$(inherit_parent_value())\"
    c = 3

        [sec1.sub1]
        $(inherit_all_key()) = \"$(inherit_parent_value())\"
    \"\"\"));

julia> parsed_args = parse_args(cfg, ["--a", "3", "--sec1.b", "5", "--sec1.c", "10"]);
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
function ArgParse.parse_args(args_list::Vector, settings::ArgParseSettings, cfg::Config; kwargs...)
    parse_args!(args_list, deepcopy(settings), deepcopy(cfg); kwargs...)
end
default_args_list() = ARGS
default_argparse_settings() = ArgParseSettings()
ArgParse.parse_args(cfg::Config; kwargs...) = parse_args(default_argparse_settings(), cfg; kwargs...)
ArgParse.parse_args(settings::ArgParseSettings, cfg::Config; kwargs...) = parse_args(default_args_list(), settings, cfg; kwargs...)
ArgParse.parse_args(args_list::Vector, cfg::Config; kwargs...) = parse_args(args_list, default_argparse_settings(), cfg; kwargs...)

function parse_args!(
        args_list::Vector,
        settings::ArgParseSettings,
        cfg::Config;
        as_dict::Bool = false,
        as_symbols::Bool = false,
        kwargs...
    )
    # Update global parser settings
    parser_settings!(; kwargs...)

    # Populate all "_INHERIT_" keys and/or "_PARENT_" values to establish defaults
    default_cfg = defaults!(deepcopy(cfg))

    # Add arg table entries to `settings` dynamically using default `cfg` specification
    add_arg_table!(settings, default_cfg)

    # Parse `args_list` arguments into `cfg` using the dynamically constructed arg table
    for (k,v) in parse_args(args_list, settings)
        if any(startswith("--" * k), args_list)
            # Only update `cfg` with new value if it was explicitly passed in `args_list`
            keys = String.(split(k, flag_delim()))
            recurse_setindex!(getleaf(cfg), deepcopy(v), keys)
        end
    end

    # Populate remaining "_INHERIT_" keys and/or "_PARENT_" values which were not overridden by `args_list`
    defaults!(cfg)

    # Return parsed config
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
