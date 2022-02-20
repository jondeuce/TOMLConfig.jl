using Test
using TOMLConfig
using Dates, Random

struct NoException <: Exception end

macro test_nothrow(ex)
    esc(:(@test_throws NoException ($(ex); throw(NoException()))))
end

function check_keys(toml::Dict{String}, has, doesnt)
    for key in has
        @test haskey(toml, key)
    end
    for key in doesnt
        @test !haskey(toml, key)
    end
end

function typed_isequal(toml1::Dict{String}, toml2::Dict{String})
    @test toml1 == toml2
    for k in keys(toml1)
        v1, v2 = toml1[k], toml2[k]
        if v1 isa AbstractDict && v2 isa AbstractDict
            @test typeof(v1) == typeof(v2)
            typed_isequal(v1, v2)
        else
            @test typeof(v1) == typeof(v2)
        end
    end
end

@testset "abstract dict methods" begin
    cfg = Config()
    cfg.a = 1
    cfg["b"] = 2
    cfg."c" = [3]
    cfg.d.e = [4]
    @test cfg.a == cfg."a" == cfg["a"] == 1
    @test cfg.b == cfg."b" == cfg["b"] == 2
    @test cfg.c == cfg."c" == cfg["c"] == [3]
    @test cfg.d.e == cfg.d."e" == cfg.d["e"] == [4]

    d = TOMLConfig.dict(cfg)
    @test d["a"] == 1
    @test d["b"] == 2
    @test d["c"] == [3]
    @test d["c"] === cfg.c # identity preserved
    @test d["d"]["e"] == [4]
    @test d["d"]["e"] === cfg.d.e # identity preserved

    @test isequal(Set(propertynames(cfg)), Set([:a, :b, :c, :d])) # fields are unordered, so use set equality

    @test keys(cfg) == keys(d)
    @test length(cfg) == length(d)
    @test isempty(cfg) == isempty(d)
    for (k, v) in cfg # test iteration
        @test d[k] == v
    end

    @test get(cfg, "e", 5) == 5
    @test !haskey(cfg, "e")

    @test get(cfg, "e") do; 5; end == 5
    @test !haskey(cfg, "e")

    @test get!(cfg, "e", 5) == 5
    @test haskey(cfg, "e"); delete!(cfg, "e"); @test !haskey(cfg, "e")

    @test get!(cfg, "e") do; 5; end == 5
    @test haskey(cfg, "e"); delete!(cfg, "e"); @test !haskey(cfg, "e")

    @test merge(cfg, Config((e=5,))) == Config(; a=1, b=2, c=[3], d=Dict("e"=>[4]), e=5)

    @test cfg == copy(cfg)
    @test cfg == deepcopy(cfg)

    @test empty!(cfg) == Config()
    @test isempty(cfg)
end

@testset "basic parsing" begin
    template = TOML.parsefile(joinpath(@__DIR__, "basic.toml"))

    function check_parsed_types(toml::Dict{String})
        @test typeof(toml["a"]) == Int
        @test typeof(toml["b"]) == Float64
        @test typeof(toml["sec1"]["c"]) == Vector{Int}
        @test typeof(toml["sec1"]["sub1"]["d"]) == Vector{Float64}
        @test typeof(toml["sec1"]["sub1"]["e"]) == Bool
        @test typeof(toml["sec1"]["sub2"]["f"]) == Date
        @test typeof(toml["sec1"]["sub2"]["g"]) == DateTime
        @test typeof(toml["sec1"]["sub2"]["h"]) == Time
    end

    @testset "no args passed" begin
        parsed_args = TOMLConfig.parse_config(String[]; filename = joinpath(@__DIR__, "basic.toml"), as_dict = true)
        check_parsed_types(parsed_args)
        check_parsed_types(template)
        typed_isequal(parsed_args, template)
    end

    @testset "args passed" begin
        args_list = [
            "--a", "1",
            "--sec1.c", "3", "4", "5",
            "--sec1.sub1.d", "5.5",
            "--sec1.sub2.f", "2021-06-01",
            "--sec1.sub2.g", "2021-06-01T12:34:56",
            "--sec1.sub2.h", "01:23:45",
        ]
        parsed_args = TOMLConfig.parse_config(args_list; filename = joinpath(@__DIR__, "basic.toml"), as_dict = true)

        cfg = Config(deepcopy(template))
        cfg.a = 1
        cfg.sec1.c = [3,4,5]
        cfg.sec1.sub1.d = [5.5]
        cfg.sec1.sub2.f = Date("2021-06-01")
        cfg.sec1.sub2.g = DateTime("2021-06-01T12:34:56")
        cfg.sec1.sub2.h = Time("01:23:45")

        check_parsed_types(parsed_args)
        check_parsed_types(TOMLConfig.dict(cfg))
        typed_isequal(parsed_args, TOMLConfig.dict(cfg))
    end

    @testset "mistyped args" begin
        for args_list in [
            ["--a", "1.5"],
            ["--b", "e"],
            ["--sec1.c", "3.5", "4"],
            ["--sec1.sub1.d", "f", "g", "h"],
            ["--sec1.sub2.f", "01:00:00"],
            ["--sec1.sub2.g", "01:00:00"],
            ["--sec1.sub2.h", "2013-01-01"],
        ]
            settings = ArgParseSettings(exc_handler = ArgParse.debug_handler)
            @test_throws ArgParseError parse_args(args_list, settings, Config(deepcopy(template)))
        end
    end
end

@testset "nested field inheritance" begin
    template = TOML.parsefile(joinpath(@__DIR__, "nested.toml"))

    function check_parsed_keys(toml::Dict{String})
        check_keys(toml, ["a", "b", "c"], ["_INHERIT_"])
        check_keys(toml["sec1"], ["a", "b", "c"], ["_INHERIT_"])
        check_keys(toml["sec1"]["sub1"], ["a", "c"], ["_INHERIT_", "b"])
        check_keys(toml["sec1"]["sub2"], ["a", "b", "c"], ["_INHERIT_"])
    end

    @testset "no args passed" begin
        parsed_args = parse_args(String[], Config(deepcopy(template)); as_dict = true)
        check_parsed_keys(parsed_args)

        cfg = Config(deepcopy(template))
        cfg.sec1.b = 0.0
        cfg.sec1.c = "c"
        cfg.sec1.sub1.a = [1]
        cfg.sec1.sub2.a = [1]
        cfg.sec1.sub2.b = 0.0
        delete!(cfg.sec1, TOMLConfig.inherit_all_key())
        delete!(cfg.sec1.sub1, TOMLConfig.inherit_all_key())
        delete!(cfg.sec1.sub2, TOMLConfig.inherit_all_key())

        typed_isequal(parsed_args, TOMLConfig.dict(cfg))
    end

    @testset "args passed" begin
        args_list = ["--b=1.0", "--sec1.a=2", "--sec1.sub2.c=e"]
        parsed_args = parse_args(args_list, Config(deepcopy(template)); as_dict = true)
        check_parsed_keys(parsed_args)

        cfg = Config(deepcopy(template))
        cfg.b = 1.0
        cfg.sec1.a = [2]
        cfg.sec1.b = 1.0
        cfg.sec1.c = "c"
        cfg.sec1.sub1.a = [2]
        cfg.sec1.sub2.a = [2]
        cfg.sec1.sub2.b = 1.0
        cfg.sec1.sub2.c = "e"
        delete!(cfg.sec1, TOMLConfig.inherit_all_key())
        delete!(cfg.sec1.sub1, TOMLConfig.inherit_all_key())
        delete!(cfg.sec1.sub2, TOMLConfig.inherit_all_key())

        typed_isequal(parsed_args, TOMLConfig.dict(cfg))
    end
end

@testset "customizing arg table" begin
    template = TOML.parsefile(joinpath(@__DIR__, "nested.toml"))

    function randomly_insert_arg_dicts!(toml)
        seed = 0
        for node in TOMLConfig.StatelessBFS(Config(toml))
            for (k, v) in node
                k == TOMLConfig.inherit_all_key() && continue # can't replace _INHERIT_ with arg dict
                !TOMLConfig.is_leaf(v) && continue # only replace args, not child dicts
                rand(MersenneTwister(seed += 1)) > 0.5 && continue # flip coin
                node[k] = !(v isa TOMLConfig.ArgTableEntry) ?
                    Dict{String, Any}(TOMLConfig.arg_key() => TOMLConfig.arg_value(v)) :
                    TOMLConfig.arg_value(v)
            end
        end
        return toml
    end

    @testset "arg dict equivalence" begin
        for args_list in [
            String[],
            ["--a", "1", "2", "--c", "cat"],
            ["--b", "2.0", "--sec1.b", "3.0", "--sec1.sub1.a", "5"],
        ]
            template′ = randomly_insert_arg_dicts!(deepcopy(template))
            parsed_args = parse_args(args_list, Config(deepcopy(template)); as_dict = true)
            parsed_args′ = parse_args(args_list, Config(deepcopy(template′)); as_dict = true)
            typed_isequal(parsed_args, parsed_args′)
        end
    end
end

@testset "arg dict properties" begin
    template = TOML.parsefile(joinpath(@__DIR__, "argtable.toml"))
    debug_parse_args = (args_list) -> parse_args(args_list, ArgParseSettings(exc_handler = ArgParse.debug_handler), Config(deepcopy(template)))
    @test_throws ArgParseError debug_parse_args(String[]) # --a is required
    @test_throws ArgParseError debug_parse_args(["--a", "3.0", "4.0"]) # --a must be Int
    @test_throws ArgParseError debug_parse_args(["--a", "3"]) # --a requires two args
    @test_throws ArgParseError debug_parse_args(["--a", "1", "2", "--b"]) # --b requires at least one arg
    @test_nothrow debug_parse_args(["--a", "1", "2", "--b", "5.0"])
    @test_nothrow debug_parse_args(["--a", "1", "2", "--b", "5", "10"]) # --b should allow conversion Int -> Float64
end
