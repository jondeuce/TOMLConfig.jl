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
recurse_convert_keytype(d::AbstractDict, ::Type{T} = Symbol) where {T} = Dict{T, Any}(T(k) => v isa AbstractDict ? recurse_convert_keytype(v, T) : v for (k,v) in d)

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
AbstractTrees.children(parent::Config) = [Config(leaf, parent, key) for (key, leaf) in getleaf(parent) if leaf isa AbstractDict && _arg_table_key() ∉ keys(leaf)]

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
    "arg_table_key"        => "_ARG_",
    "arg_table_required"   => "_REQUIRED_",
    "inherit_all_key"      => "_INHERIT_",
    "inherit_parent_value" => "_PARENT_",
    "flag_delim"           => ".",
)
_arg_table_key()          = parsing_settings["arg_table_key"]
_arg_table_key!(v)        = parsing_settings["arg_table_key"] = String(v)
_arg_table_required()     = parsing_settings["arg_table_required"]
_arg_table_required!(v)   = parsing_settings["arg_table_required"] = String(v)
_inherit_all_key()        = parsing_settings["inherit_all_key"]
_inherit_all_key!(v)      = parsing_settings["inherit_all_key"] = String(v)
_inherit_parent_value()   = parsing_settings["inherit_parent_value"]
_inherit_parent_value!(v) = parsing_settings["inherit_parent_value"] = String(v)
_flag_delim()             = parsing_settings["flag_delim"]
_flag_delim!(v)           = parsing_settings["flag_delim"] = String(v)

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
function defaults!(cfg::Config)
    # Step 1:
    #   Inverted breadth-first search for `_inherit_all_key()` with value `_inherit_parent_value()`.
    #   If found, copy all key-value pairs from the immediate parent (i.e. non-recursive) into the node containing `_inherit_all_key()`.
    #   Delete the `_inherit_all_key()` afterwards.
    for node in reverse(collect(StatelessBFS(cfg)))
        parent, leaf = getparent(node), getleaf(node)
        if parent !== nothing && get(leaf, _inherit_all_key(), nothing) == _inherit_parent_value()
            for (k,v) in getleaf(parent)
                if !(v isa AbstractDict) && !haskey(leaf, k)
                    # If key `k` is not already present in the current leaf, inherit value `v` from the parent leaf
                    leaf[k] = deepcopy(getleaf(parent)[k])
                end
            end
            delete!(leaf, _inherit_all_key())
        end
    end

    # Step 2:
    #   Breadth-first search for fields with value `_inherit_parent_value()`.
    #   If found, copy default value from the corresponding field in the immediate parent (i.e. non-recursive).
    for node in StatelessBFS(cfg)
        parent, leaf = getparent(node), getleaf(node)
        if parent !== nothing
            for (k,v) in leaf
                if v == _inherit_parent_value()
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
of the current node using the delimiter `_flag_delim()` and prepending "--".

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
--sec1$(_flag_delim())c
--sec1$(_flag_delim())sub1$(_flag_delim())d
```
"""
function argparse_flag(node::Config, k::String)
    flag = k
    while true
        if getparent(node) === nothing
            flag = "--" * flag
            return flag
        else
            flag = getkey(node) * _flag_delim() * flag
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
            if v isa AbstractDict
                if _arg_table_key() ∈ keys(v)
                    props, v = v, v[_arg_table_key()]
                    props = delete!(deepcopy(props), _arg_table_key())
                    props = recurse_convert_keytype(props, Symbol)

                    # Special-casing specific properties
                    if :arg_type ∈ keys(props)
                        arg_type_dict = Dict{String, DataType}("Any" => Any, "DateTime" => DateTime, "Time" => Time, "Date" => Date, "Bool" => Bool, "Int64" => Int64, "Float64" => Float64, "String" => String)
                        @assert props[:arg_type] ∈ keys(arg_type_dict)
                        props[:arg_type] = arg_type_dict[props[:arg_type]]
                    end

                    if :nargs ∈ keys(props)
                        nargs_dict = Dict{String, Char}("A" => 'A',"?" => '?',"*" => '*',"+" => '+',"R" => 'R')
                        @assert props[:nargs] isa Int || props[:nargs] ∈ keys(nargs_dict)
                        if !(props[:nargs] isa Int)
                            props[:nargs] = nargs_dict[props[:nargs]]
                        end
                    end

                    if v == _arg_table_required()
                        get!(props, :required, true)
                    else
                        get!(props, :required, false)
                        get!(props, :default, deepcopy(v))
                        if v isa AbstractVector
                            get!(props, :arg_type, eltype(v))
                            get!(props, :nargs, '*')
                        else
                            get!(props, :arg_type, typeof(v))
                        end
                    end
                    add_arg_table!(settings, argparse_flag(node, k), props)
                end
            else
                props = Dict{Symbol,Any}()
                props[:required] = false
                props[:default] = deepcopy(v)
                if v isa AbstractVector
                    props[:arg_type] = eltype(v)
                    props[:nargs] = '*'
                else
                    props[:arg_type] = typeof(v)
                end
                add_arg_table!(settings, argparse_flag(node, k), props)
            end
        end
    end

    return settings
end

function parse!(cfg::Config, args_list, settings::ArgParseSettings; explicit_args_only = false)
    # Parse and merge into config
    for (k,v) in parse_args(args_list, settings)
        if explicit_args_only
            # Only update `cfg` with new value if it was explicitly passed in `args_list`
            !any(startswith("--" * k), args_list) && continue
        end
        ks = String.(split(k, _flag_delim()))
        recurse_setindex!(getleaf(cfg), deepcopy(v), ks)
    end
    return cfg
end

"""
    ArgParse.parse_args(
        [args_list::Vector, [settings::ArgParseSettings,]] cfg::Config;
        as_dict = false,
        as_symbols = false,
        arg_table_key = "$(_arg_table_key())",
        arg_table_required = "$(_arg_table_required())",
        inherit_all_key = "$(_inherit_all_key())",
        inherit_parent_value = "$(_inherit_parent_value())",
        flag_delim = "$(_flag_delim())",
    )

Parse TOML configuration struct with command line arguments `args_list`.

# Arguments:
* `args_list::Vector`: vector of arguments to be parsed
* `settings::ArgParseSettings`: settings struct which will be configured according to `cfg`
* `cfg::Config`: TOML configuration settings

# Keywords:
* `as_dict`: if true, return config as a dictionary with `String` keys, otherwise return a `Config` struct
* `as_symbols`: if true and `as_dict=true`, return config dictionary with `Symbol` keys
* `arg_table_key`: if this key is found in a TOML section, the rest of the section is interpreted as properties for the argument table entry
* `arg_table_required`: if this value is found in a TOML section, the `required = true` is passed to the argument table entry
* `inherit_all_key`: if this key is found in a TOML section, all fields from the immediate parent section (i.e., non-recursive) should be inherited
* `inherit_parent_value`: if this value is found in a TOML section, it is replaced with the value corresponding to the same key in the immediate parent section (i.e., non-recursive)
* `flag_delim`: command line flags for keys in nested TOML sections are formed by joining all parent keys together with this delimiter

# Examples

```jldoctest
julia> cfg = Config(TOML.parse(
    \"\"\"
    a = 1
    b = 2

    [sec1]
    b = \"$(_inherit_parent_value())\"
    c = 3

        [sec1.sub1]
        $(_inherit_all_key()) = \"$(_inherit_parent_value())\"
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
function ArgParse.parse_args(
        args_list::Vector,
        settings::ArgParseSettings,
        cfg::Config;
        as_dict::Bool                          = false,
        as_symbols::Bool                       = false,
        arg_table_key::AbstractString          = _arg_table_key(),
        arg_table_required::AbstractString     = _arg_table_required(),
        inherit_all_key::AbstractString        = _inherit_all_key(),
        inherit_parent_value::AbstractString   = _inherit_parent_value(),
        flag_delim::AbstractString             = _flag_delim(),
    )
    # Set parsing defaults
    _arg_table_key!(arg_table_key)
    _arg_table_required!(arg_table_required)
    _inherit_all_key!(inherit_all_key)
    _inherit_parent_value!(inherit_parent_value)
    _flag_delim!(flag_delim)

    settings, cfg = deepcopy(settings), deepcopy(cfg)
    parse!(cfg, args_list, add_arg_table!(deepcopy(settings), defaults!(deepcopy(cfg))); explicit_args_only = true)
    parse!(cfg, args_list, add_arg_table!(settings, defaults!(cfg)); explicit_args_only = false)

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
ArgParse.parse_args(cfg::Config; kwargs...) = parse_args(ArgParseSettings(), cfg; kwargs...)
ArgParse.parse_args(settings::ArgParseSettings, cfg::Config; kwargs...) = parse_args(ARGS, settings, cfg; kwargs...)
ArgParse.parse_args(args_list::Vector, cfg::Config; kwargs...) = parse_args(args_list, ArgParseSettings(), cfg; kwargs...)

end # module TOMLConfig
