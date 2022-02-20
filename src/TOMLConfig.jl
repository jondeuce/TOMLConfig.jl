"""
    TOMLConfig

Use TOML files to configure command line parsing via [ArgParse.jl](https://github.com/carlobaldassi/ArgParse.jl).
"""
module TOMLConfig

using AbstractTrees
using Dates
using Reexport

@reexport using ArgParse, TOML

export Config

if isdefined(Base, :Experimental) && isdefined(Base.Experimental, Symbol("@compiler_options"))
    @eval Base.Experimental.@compiler_options compile=min optimize=0 infer=false
end

@nospecialize # use only declared type signatures, helps with compile time

"""
    ArgTableEntry

Internal struct used to define leaf values which represent `ArgParse` argument table entries,
storing e.g. properties of the corresponding command line argument; see `ArgParse.add_arg_table!`.
"""
struct ArgTableEntry
    value::Any
    props::Dict{Symbol, Any}
    function ArgTableEntry(x::AbstractDict)
        @assert haskey(x, arg_key())
        value = x[arg_key()]
        props = recurse_convert_keytype(delete!(deepcopy(x), arg_key()), Symbol)
        return new(value, props)
    end
end
arg_value(v) = v
arg_value(v::ArgTableEntry) = v.value
arg_props(v::ArgTableEntry) = v.props

dict(v::ArgTableEntry) = Dict{String, Any}(arg_key() => v.value, (String(k) => v for (k, v) in v.props)...)

"""
    Config(toml::AbstractDict{String})

Basic tree structure for navigating TOML file contents.
Each node in the `Config` tree represents a single section of a TOML file.
Children of a `Config` node are the corresponding TOML subsections, if they exist.

# Examples

Construct a `Config` from a TOML string literal, parsed using the `TOML` standard library:

```jldoctest
julia> using TOMLConfig

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

`Config` can also be constructed incrementally:

```jldoctest
julia> using TOMLConfig

julia> cfg = Config();

julia> cfg.a = 1;

julia> cfg.b.c.d = "three"; # Nested fields will be dynamically set, if they don't exist

julia> cfg["b"]["e"] = [2]; # getindex!/setindex! and getproperty!/setproperty! are all supported

julia> cfg
TOML Config with contents:

a = 1

[b]
e = [2]

    [b.c]
    d = "three"
```
"""
struct Config <: AbstractDict{String, Any}
    "TOML section contents"
    contents::AbstractDict{String, Any}

    "Config node corresponding to parent TOML section, or `nothing` for the root node"
    parent::Union{Config, Nothing}

    "Key within the parent node which points to this node, or `nothing` for the root node"
    key::Union{String, Nothing}

    # Disambiguation of vararg inputs
    Config(contents::AbstractDict{String, Any}, ::Nothing, ::Nothing) = new(contents, nothing, nothing)
    Config(contents::AbstractDict{String, Any}, parent::Config, key::String) = new(contents, parent, key)
end

# Constructors
Config(x::AbstractDict) = new_root(x)
Config(x::NamedTuple) = new_root(pairs(x))
Config(; kw...) = Config(kw)
Config(x...) = Config(Dict(x...))

TOML.parsefile(::Type{Config}, filename::AbstractString) = Config(TOML.parsefile(filename))

# Define getters to access struct fields, since `getproperty` is overloaded for convenience below
contents(cfg::Config) = getfield(cfg, :contents)
parent(cfg::Config) = getfield(cfg, :parent)
key(cfg::Config) = getfield(cfg, :key)

is_leaf(v) = true
is_leaf(cfg::Config) = false
is_root(cfg::Config) = parent(cfg) === nothing && key(cfg) === nothing

function new_subtree(x::AbstractDict, parent::Union{Config, Nothing}, key::Union{String, Nothing})
    cfg = Config(Dict{String, Any}(), parent, key)
    for (k, v) in pairs(x)
        if v isa AbstractDict
            if haskey(v, arg_key())
                cfg[k] = ArgTableEntry(v)
            else
                cfg[k] = new_subtree(v, cfg, String(k))
            end
        else
            cfg[k] = v
        end
    end
    return cfg
end
new_root(x) = new_subtree(x, nothing, nothing)

function Base.show(io::IO, ::MIME"text/plain", cfg::Config)
    println(io, "TOML Config with contents:\n")
    TOML.print(io, dict(cfg))
end

# `AbstractDict` methods
dict(cfg::Config) = Dict{String, Any}(k => v isa Union{Config, ArgTableEntry} ? dict(v) : v for (k, v) in cfg)

Base.getproperty(cfg::Config, k::String) = get!(cfg, k) do; new_subtree(Dict{String, Any}(), cfg, k); end
Base.getproperty(cfg::Config, k::Symbol) = getproperty(cfg, String(k))
Base.getproperty(cfg::Config, k) = getproperty(cfg, String(k))

Base.setproperty!(cfg::Config, k::String, v) = contents(cfg)[k] = v
Base.setproperty!(cfg::Config, k::Symbol, v) = setproperty!(cfg, String(k), v)
Base.setproperty!(cfg::Config, k, v) = setproperty!(cfg, String(k), v)

Base.propertynames(cfg::Config) = map(Symbol, collect(keys(cfg)))

Base.getindex(cfg::Config, k) = getproperty(cfg, String(k))
Base.setindex!(cfg::Config, v, k) = setproperty!(cfg, String(k), v)

Base.iterate(cfg::Config, args...) = iterate(contents(cfg), args...)
Base.keys(cfg::Config) = keys(contents(cfg))
Base.values(cfg::Config) = values(contents(cfg))
Base.length(cfg::Config) = length(contents(cfg))
Base.isempty(cfg::Config) = isempty(contents(cfg))
Base.pairs(cfg::Config) = pairs(contents(cfg))
Base.delete!(cfg::Config, k) = delete!(contents(cfg), String(k))
Base.empty!(cfg::Config) = (empty!(contents(cfg)); cfg)
Base.get(cfg::Config, k, default) = get(contents(cfg), String(k), default)
Base.get!(cfg::Config, k, default) = get!(contents(cfg), String(k), default)
Base.get(f::Union{Function, Type}, cfg::Config, k) = get(f, contents(cfg), String(k))
Base.get!(f::Union{Function, Type}, cfg::Config, k) = get!(f, contents(cfg), String(k))

Base.isequal(a::Config, b::Config) = contents(a) == contents(b)
Base.copy(cfg::Config) = is_root(cfg) ? new_root(copy(contents(cfg))) : new_subtree(copy(contents(cfg)), copy(parent(cfg)), key(cfg))
Base.deepcopy(cfg::Config) = is_root(cfg) ? new_root(deepcopy(contents(cfg))) : new_subtree(deepcopy(contents(cfg)), deepcopy(parent(cfg)), key(cfg))

function Base.merge!(a::Config, b::Config)
    for (k, v) in pairs(b)
        if haskey(a, k) && (v isa Config)
            merge!(a[k], v)
        else
            a[k] = v
        end
    end
    return a
end
Base.merge(a::Config, b::Config) = merge!(deepcopy(a), b)

# AbstractTrees interface
AbstractTrees.nodetype(::Config) = Config
AbstractTrees.children(parent::Config) = filter(!is_leaf, collect(values(parent)))

function AbstractTrees.printnode(io::IO, cfg::Config)
    if key(cfg) !== nothing
        println(io, key(cfg) * ":")
    end
    print(io, join(["$k = $(arg_value(v))" for (k, v) in cfg if is_leaf(v)], "\n"))
end

# Convenience functions for getting/setting deeply nested nodes
recurse_getindex(cfg::Config, keys) = foldl((dᵢ,k) -> dᵢ[k], keys; init = cfg)
recurse_setindex!(cfg::Config, v, keys) = recurse_getindex(cfg, keys[begin:end-1])[keys[end]] = v
recurse_convert_keytype(d::AbstractDict, ::Type{K} = Symbol) where {K} = Dict{K, Any}(K(k) => v isa AbstractDict ? recurse_convert_keytype(v, K) : v for (k, v) in d)
recurse_convert_valtype(d::AbstractDict, ::Type{V} = Symbol) where {V} = Dict{keytype(d), Any}(k => v isa AbstractDict ? recurse_convert_valtype(v, V) : V(v) for (k, v) in d)
recurse_convert_keyvaltype(d::AbstractDict, ::Type{K} = Symbol, ::Type{V} = Symbol) where {K, V} = Dict{K, Any}(K(k) => v isa AbstractDict ? recurse_convert_keyvaltype(v, K, V) : V(v) for (k, v) in d)

"""
    parse_config(args...; filename::String, kwargs...)

Convenience method for parsing configuration files.
Equivalent to `ArgParse.parse_args(args..., TOML.parsefile(Config, filename); kwargs...)`.
"""
parse_config(args...; filename::String, kwargs...) = ArgParse.parse_args(args..., TOML.parsefile(Config, filename); kwargs...)

"""
    save_config(cfg::Union{Config, AbstractDict}; filename::AbstractString, kwargs...)

Save configuration `cfg` to TOML file `filename`.
Additional keyword arguments are forwarded to `TOML.print`.
"""
function save_config(cfg::AbstractDict; filename::AbstractString, kwargs...)
    open(filename; write = true) do io
        TOML.print(io, cfg; kwargs...)
    end
end
save_config(cfg::Config; kwargs...) = save_config(deepcopy(dict(cfg)); kwargs...)

# Parser settings
default_args_list() = ARGS
default_argparse_settings() = ArgParseSettings()
default_parser_settings() = Dict{String, String}(
    "arg_key"              => "_ARG_",
    "arg_required_value"   => "_REQUIRED_",
    "flag_delim"           => ".",
    "inherit_all_key"      => "_INHERIT_",
    "inherit_parent_value" => "_PARENT_",
)

const _parser_settings = default_parser_settings()
parser_settings()      = _parser_settings
parser_settings(k)     = _parser_settings[string(k)]
parser_settings!(k, v) = _parser_settings[string(k)] = string(v)

arg_key()              = parser_settings("arg_key")
arg_required_value()   = parser_settings("arg_required_value")
flag_delim()           = parser_settings("flag_delim")
inherit_all_key()      = parser_settings("inherit_all_key")
inherit_parent_value() = parser_settings("inherit_parent_value")

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
    for (k, v) in merge!(default_parser_settings(), recurse_convert_keyvaltype(kwargs, String, String))
        if k ∈ keys(parser_settings())
            parser_settings!(k, v)
        else
            error("Invalid parser setting: $(k). Possible settings are: $(join(sort(collect(keys(default_parser_settings()))), ", ")).")
        end
    end
end

"""
    defaults!(cfg::Config)

Populate fields of TOML config which are specified to have default values inherited from parent sections.

# Examples

```jldoctest
julia> using TOMLConfig

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
function defaults!(cfg::Config; replace_arg_dicts = false)
    _INHERIT_ = inherit_all_key()
    _PARENT_  = inherit_parent_value()

    # Step 0:
    #   Breadth-first search to replace arg table dictionaries with default values, which may be "_PARENT_"
    if replace_arg_dicts
        for node in StatelessBFS(cfg)
            for (k, v) in node
                if v isa ArgTableEntry
                    node[k] = arg_value(v)
                end
            end
        end
    end

    # Step 1:
    #   Inverted breadth-first search for "_INHERIT_" keys with value "_PARENT_".
    #   If found, copy all key-value pairs from the immediate parent (i.e. non-recursive) into the node containing "_INHERIT_".
    #   Delete the "_INHERIT_" key afterwards.
    for node in reverse(collect(StatelessBFS(cfg)))
        is_root(node) && continue
        !haskey(node, _INHERIT_) && continue
        node[_INHERIT_] != _PARENT_ && continue
        for (k, v) in parent(node)
            if is_leaf(v) && !haskey(node, k)
                # If key `k` is not already present in the current section, inherit arg (possibly an arg dict) from the parent section
                node[k] = deepcopy(v)
            end
        end
        delete!(node, _INHERIT_)
    end

    # Step 2:
    #   Breadth-first search for fields with value "_PARENT_".
    #   If found, copy default value from the corresponding field in the immediate parent (i.e. non-recursive).
    for node in StatelessBFS(cfg)
        is_root(node) && continue
        for (k, v) in deepcopy(node)
            is_leaf(v) && arg_value(v) == _PARENT_ || continue
            if v isa ArgTableEntry
                node[k][arg_key()] = arg_value(parent(node)[k])
            else
                node[k] = arg_value(parent(node)[k])
            end
        end
    end

    return cfg
end

"""
    arg_table_flag(cfg::Config, k::String)

Generate command flag corresponding to nested key `k` in a `Config` node.
The flag is constructed by joining the keys recursively from the parents
of the current node using the delimiter `flag_delim()` and prepending "--".

# Examples

```jldoctest
julia> using TOMLConfig

julia> cfg = Config();

julia> cfg.a = 1;

julia> cfg.sec1.b = 2;

julia> cfg.sec1.sub1.c = 3;

julia> cfg
TOML Config with contents:

a = 1

[sec1]
b = 2

    [sec1.sub1]
    c = 3

julia> TOMLConfig.arg_table_flag(cfg, "a")
"--a"

julia> TOMLConfig.arg_table_flag(cfg.sec1, "b")
"--sec1.b"

julia> TOMLConfig.arg_table_flag(cfg.sec1.sub1, "c")
"--sec1.sub1.c"
```
"""
function arg_table_flag(cfg::Config, k::String)
    flag = k
    while true
        if is_root(cfg)
            flag = "--" * flag
            return flag
        else
            flag = key(cfg) * flag_delim() * flag
            cfg = parent(cfg)
        end
    end
end

"""
    ArgParse.add_arg_table!(settings::ArgParseSettings, cfg::Config)

Populate `settings` argument table using configuration `cfg`.

# Examples

```jldoctest
julia> using TOMLConfig

julia> cfg = Config(TOML.parse(
       \"\"\"
       a = 1.0
       b = 2
       
       [sec1]
       c = [3, 4]
       
           [sec1.sub1]
           d = "d"
       \"\"\"));

julia> settings = add_arg_table!(ArgParseSettings(prog = "myscript.jl"), cfg);

julia> ArgParse.show_help(settings; exit_when_done = false)
usage: myscript.jl [--b B] [--a A] [--sec1.c [SEC1.C...]]
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
        for (k, v) in node
            is_leaf(v) || continue

            if !(v isa ArgTableEntry)
                # Add to arg table using specified value as the default
                props = Dict{Symbol,Any}()
                props[:default] = arg_value(v)
                props[:required] = false

                if v isa AbstractVector
                    props[:arg_type] = eltype(v)
                    props[:nargs] = '*'
                else
                    props[:arg_type] = typeof(v)
                end

                add_arg_table!(settings, arg_table_flag(node, k), props)

            else
                props = arg_props(v)
                v = arg_value(v)

                # Special-casing specific properties
                if :arg_type ∈ keys(props)
                    arg_type_dict = Dict{String, DataType}("Any" => Any, "DateTime" => DateTime, "Time" => Time, "Date" => Date, "Bool" => Bool, "Int" => Int, "Float64" => Float64, "String" => String)
                    if props[:arg_type] ∉ keys(arg_type_dict)
                        error("Invalid arg_type: $(repr(props[:arg_type])). Must be one of: $(join(sort(repr.(keys(arg_type_dict))), ", ")).")
                    end
                    props[:arg_type] = arg_type_dict[props[:arg_type]]
                end

                if :nargs ∈ keys(props)
                    nargs_dict = Dict{String, Char}("A" => 'A', "?" => '?', "*" => '*', "+" => '+', "R" => 'R')
                    if !(props[:nargs] isa Int) && !(props[:nargs] ∈ keys(nargs_dict))
                        error("Invalid nargs: $(repr(props[:nargs])). Must be a nonnegative integer, or one of: $(join(sort(repr.(keys(nargs_dict))), ", ")).")
                    end
                    if props[:nargs] ∈ keys(nargs_dict)
                        props[:nargs] = nargs_dict[props[:nargs]]
                    end
                end

                # Add to arg table using user specified props
                if v == arg_required_value()
                    get!(props, :required, true)
                else
                    get!(props, :default, v)
                    get!(props, :required, false)
                    if v isa AbstractVector
                        get!(props, :arg_type, eltype(v))
                        get!(props, :nargs, '*')
                    else
                        get!(props, :arg_type, typeof(v))
                    end
                end

                add_arg_table!(settings, arg_table_flag(node, k), props)
            end
        end
    end

    return settings
end

"""
    ArgParse.parse_args(
        [args_list::Vector = ARGS,]
        [settings::ArgParseSettings = ArgParseSettings(),]
        cfg::Config;
        as_dict = false,
        as_symbols = false,
        kwargs...
    )

Parse TOML configuration struct with command line arguments `args_list`.

# Arguments:
* `args_list::Vector`: (optional) vector of arguments to be parsed
* `settings::ArgParseSettings`: (optional) settings struct which will be configured according to `cfg`
* `cfg::Config`: TOML configuration settings

# Keywords:
* `as_dict`: if true, return config as a dictionary with `String` keys, otherwise return a `Config` struct
* `as_symbols`: if true and `as_dict=true`, return config dictionary with `Symbol` keys
* `kwargs...`: additional keyword arguments can be passed to customize the global parser settings; see `TOMLConfig.parser_settings!`. Note that these settings remain persistent on subsequent calls to `parse_args`; use `TOMLConfig.parser_settings!()` to restore all defaults.

# Examples

```jldoctest
julia> using TOMLConfig

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

julia> parsed_args = parse_args(["--a", "3", "--sec1.b", "5", "--sec1.c", "10"], cfg)
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
    default_cfg = defaults!(deepcopy(cfg); replace_arg_dicts = false)

    # Add arg table entries to `settings` dynamically using default `cfg` specification
    add_arg_table!(settings, default_cfg)

    # Parse `args_list` arguments into `cfg` using the dynamically constructed arg table
    for (k, v) in parse_args(args_list, settings)
        if any(startswith("--" * k), args_list)
            # Only update `cfg` with new value if it was explicitly passed in `args_list`
            keys = String.(split(k, flag_delim()))
            recurse_setindex!(cfg, deepcopy(v), keys)
        end
    end

    # Populate remaining "_INHERIT_" keys and/or "_PARENT_" values which were not overridden by `args_list`
    defaults!(cfg; replace_arg_dicts = true)

    # Return parsed config
    if as_dict
        if as_symbols
            return recurse_convert_keytype(dict(cfg), Symbol)
        else
            return dict(cfg)
        end
    else
        return cfg
    end
end

end # module TOMLConfig
