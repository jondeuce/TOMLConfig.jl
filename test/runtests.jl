using TOMLConfig
using Test

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

@testset "simple parsing" begin
    template = TOML.parse(
    """
    a = 0
    b = 0.0
    [sec1]
        c = [1, 2]
        [sec1.sub1]
            d = [1.0, 2.0]
    """)

    @testset "no args passed" begin
        parsed_args = parse_args(Config(deepcopy(template)), String[]; as_dict = true)
        expected_parsed = deepcopy(template)
        typed_isequal(parsed_args, expected_parsed)
    end

    @testset "args passed" begin
        parsed_args = parse_args(Config(deepcopy(template)), ["--a", "1", "--sec1.c", "3", "4", "5", "--sec1.sub1.d", "5.5"]; as_dict = true)
        expected_parsed = deepcopy(template)
        expected_parsed["a"] = 1
        expected_parsed["sec1"]["c"] = [3,4,5]
        expected_parsed["sec1"]["sub1"]["d"] = [5.5]
        typed_isequal(parsed_args, expected_parsed)
    end

    @testset "mistyped args" begin
        for args in [
            ["--a", "1.5"],
            ["--b", "e"],
            ["--sec1.c", "3.5", "4"],
            ["--sec1.sub1.d", "f", "g", "h"],
        ]
            @test_throws ArgParseError parse_args(Config(deepcopy(template)), args; as_dict = true, exc_handler = ArgParse.debug_handler)
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
        INHERIT = "%PARENT%"
        a = 1
        [sec1.sub1]
            INHERIT = "%PARENT%"
            c = "d"
        [sec1.sub2]
            INHERIT = "%PARENT%"
            b = "%PARENT%"
            c = "d"
    """)

    function check_parsed_keys(toml)
        check_keys(toml, ["a", "b", "c"], ["INHERIT"])
        check_keys(toml["sec1"], ["a", "b", "c"], ["INHERIT"])
        check_keys(toml["sec1"]["sub1"], ["a", "c"], ["INHERIT", "b"])
        check_keys(toml["sec1"]["sub2"], ["a", "b", "c"], ["INHERIT"])
    end

    @testset "no args passed" begin
        parsed_args = parse_args(Config(deepcopy(template)), String[]; as_dict = true)
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
        parsed_args = parse_args(Config(deepcopy(template)), ["--b=1.0", "--sec1.a=2", "--sec1.sub2.c=e"]; as_dict = true)
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
