using TOMLConfig
using Dates
using Test

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

@testset "basic parsing" begin
    template = TOML.parse(
    """
    a = 0
    b = 0.0
    [sec1]
        c = [1, 2]
        [sec1.sub1]
            d = [1.0, 2.0]
            e = true
        [sec1.sub2]
            f = 2010-05-17
            g = 2013-01-01T00:00:00
            h = 01:00:00
    """)

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
        parsed_args = parse_args(String[], Config(deepcopy(template)); as_dict = true)
        expected_parsed = deepcopy(template)
        check_parsed_types(parsed_args)
        check_parsed_types(expected_parsed)
        typed_isequal(parsed_args, expected_parsed)
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
        parsed_args = parse_args(args_list, Config(deepcopy(template)); as_dict = true)

        expected_parsed = deepcopy(template)
        expected_parsed["a"] = 1
        expected_parsed["sec1"]["c"] = [3,4,5]
        expected_parsed["sec1"]["sub1"]["d"] = [5.5]
        expected_parsed["sec1"]["sub2"]["f"] = Date("2021-06-01")
        expected_parsed["sec1"]["sub2"]["g"] = DateTime("2021-06-01T12:34:56")
        expected_parsed["sec1"]["sub2"]["h"] = Time("01:23:45")

        check_parsed_types(parsed_args)
        check_parsed_types(expected_parsed)
        typed_isequal(parsed_args, expected_parsed)
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
    template = TOML.parse(
    """
    a = 0
    b = 0.0
    c = "c"
    [sec1]
        _INHERIT_ = "_PARENT_"
        a = 1
        [sec1.sub1]
            _INHERIT_ = "_PARENT_"
            c = "d"
        [sec1.sub2]
            _INHERIT_ = "_PARENT_"
            b = "_PARENT_"
            c = "d"
    """)

    function check_parsed_keys(toml::Dict{String})
        check_keys(toml, ["a", "b", "c"], ["_INHERIT_"])
        check_keys(toml["sec1"], ["a", "b", "c"], ["_INHERIT_"])
        check_keys(toml["sec1"]["sub1"], ["a", "c"], ["_INHERIT_", "b"])
        check_keys(toml["sec1"]["sub2"], ["a", "b", "c"], ["_INHERIT_"])
    end

    @testset "no args passed" begin
        parsed_args = parse_args(String[], Config(deepcopy(template)); as_dict = true)
        expected_parsed = TOML.parse(
        """
        a = 0
        b = 0.0
        c = "c"
        [sec1]
            a = 1
            b = 0.0
            c = "c"
            [sec1.sub1]
                a = 1
                c = "d"
            [sec1.sub2]
                a = 1
                b = 0.0
                c = "d"
        """)
        check_parsed_keys(parsed_args)
        typed_isequal(parsed_args, expected_parsed)
    end

    @testset "args passed" begin
        args_list = ["--b=1.0", "--sec1.a=2", "--sec1.sub2.c=e"]
        parsed_args = parse_args(args_list, Config(deepcopy(template)); as_dict = true)
        expected_parsed = TOML.parse(
        """
        a = 0
        b = 1.0
        c = "c"
        [sec1]
            a = 2
            b = 1.0
            c = "c"
            [sec1.sub1]
                a = 2
                c = "d"
            [sec1.sub2]
                a = 2
                b = 1.0
                c = "e"
        """)
        check_parsed_keys(parsed_args)
        typed_isequal(parsed_args, expected_parsed)
    end
end

@testset "customizing arg table" begin
    template = TOML.parse(
    """
    a = [0]
    b = 0.0
    c = "c"
    [sec1]
        _INHERIT_ = "_PARENT_"
        a = [1]
        [sec1.sub1]
            _INHERIT_ = "_PARENT_"
            c = "d"
        [sec1.sub2]
            _INHERIT_ = "_PARENT_"
            b = "_PARENT_"
            c = "d"
    """)

    function randomly_insert_arg_dicts!(toml)
        for node in TOMLConfig.StatelessBFS(Config(toml))
            leaf = TOMLConfig.get_leaf(node)
            for (k,v) in leaf
                k == TOMLConfig.inherit_all_key() && continue # can't replace _INHERIT_ with arg dict
                !TOMLConfig.is_arg(v) && continue # only replace args, not child dicts
                rand() > 0.5 && continue # flip coin
                leaf[k] = !TOMLConfig.is_arg_dict(v) ?
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

    template = TOML.parse(
    """
    [a]
        _ARG_ = "_REQUIRED_"
        nargs = 2
        arg_type = "Int"
        required = true
        help = "help string"
    [b]
        _ARG_ = [1.0, 2.0]
        nargs = "+"
        help = "help string"
    """)
    @testset "arg dict properties" begin
        debug_parse_args = (args_list) -> parse_args(args_list, ArgParseSettings(exc_handler = ArgParse.debug_handler), Config(deepcopy(template)))
        @test_throws ArgParseError debug_parse_args(String[]) # --a is required
        @test_throws ArgParseError debug_parse_args(["--a", "3.0", "4.0"]) # --a must be Int
        @test_throws ArgParseError debug_parse_args(["--a", "3"]) # --a requires two args
        @test_throws ArgParseError debug_parse_args(["--a", "1", "2", "--b"]) # --b requires at least one arg
        @test_nothrow debug_parse_args(["--a", "1", "2", "--b", "5.0"])
        @test_nothrow debug_parse_args(["--a", "1", "2", "--b", "5", "10"]) # --b should allow conversion Int -> Float64
    end
end
