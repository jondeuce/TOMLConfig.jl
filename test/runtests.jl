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

    check_keys(dict, has, doesnt) = all([haskey(dict, has) for has in has]) && !any([haskey(dict, doesnt) for doesnt in doesnt])
    function check_keys(cfg)
        @test check_keys(cfg[[]], ["a", "b", "c"], ["INHERIT"])
        @test check_keys(cfg[["B"]], ["a", "b", "c"], ["INHERIT"])
        @test check_keys(cfg[["B", "C"]], ["a", "c"], ["INHERIT", "b"])
        @test check_keys(cfg[["B", "D"]], ["a", "b", "c"], ["INHERIT"])
        return true
    end

    # no args passed
    let cfg = TOMLConfig.parse_args!(Config(template()), String[])
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
        check_keys(cfg)
        @test cfg.leaf == expected_parsed
    end

    # args passed
    let cfg = TOMLConfig.parse_args!(Config(template()), ["--b=1", "--B.a=2", "--B.D.c=3"])
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
        check_keys(cfg)
        @test cfg.leaf == expected_parsed
    end

end
