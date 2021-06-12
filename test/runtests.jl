using TOMLConfig
using Test

@testset "TOMLConfig.jl" begin
    template() = TOML.parse(
    """
    a = 0
    b = 0
    c = 0
    [B]
        INHERIT = "%PARENT%"
        a = 1
        [B.C]
            INHERIT = "%PARENT%"
            c = 2
        [B.D]
            INHERIT = "%PARENT%"
            b = "%PARENT%"
            c = 2
    """)

    check_keys(toml, has, doesnt) = all([haskey(toml, has) for has in has]) && !any([haskey(toml, doesnt) for doesnt in doesnt])
    function check_keys(toml)
        cfg = Config(toml)
        @test check_keys(cfg[[]], ["a", "b", "c"], ["INHERIT"])
        @test check_keys(cfg[["B"]], ["a", "b", "c"], ["INHERIT"])
        @test check_keys(cfg[["B", "C"]], ["a", "c"], ["INHERIT", "b"])
        @test check_keys(cfg[["B", "D"]], ["a", "b", "c"], ["INHERIT"])
        return true
    end

    # no args passed
    let config = parse_args(Config(template()), String[])
        expected_parsed = TOML.parse(
        """
        a = 0
        b = 0
        c = 0
        [B]
            a = 1
            b = 0
            c = 0
            [B.C]
                a = 1
                c = 2
            [B.D]
                a = 1
                b = 0
                c = 2
        """)
        check_keys(config)
        @test config == expected_parsed
    end

    # args passed
    let config = parse_args(Config(template()), ["--b=1", "--B.a=2", "--B.D.c=3"])
        expected_parsed = TOML.parse(
        """
        a = 0
        b = 1
        c = 0
        [B]
            a = 2
            b = 1
            c = 0
            [B.C]
                a = 2
                c = 2
            [B.D]
                a = 2
                b = 1
                c = 3
        """)
        check_keys(config)
        @test config == expected_parsed
    end

end
