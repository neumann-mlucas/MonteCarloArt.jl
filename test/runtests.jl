using Test
using Images
using Random
using Statistics: mean
include(joinpath(@__DIR__, "..", "src", "MonteCarloArt.jl"))
using .MonteCarloArt

const SZ = 64
const L = Lab{Float64}

# White canvas with a red square and a blue square.
function blocks(sz::Int)::Matrix{L}
    img = fill(L(100, 0, 0), sz, sz)
    img[10:30, 10:30] .= convert(L, RGB(1, 0, 0))
    img[36:56, 30:56] .= convert(L, RGB(0, 0, 1))
    img
end

err(a, b) = mean(MonteCarloArt.color_distance.(a, b))

cfg(; kw...) = MonteCarloArt.Config(; steps=4000, color_palette=4, kw...)

@testset "MonteCarloArt" begin
    @testset "stencil + clipping" begin
        pts = MonteCarloArt.gen_stroke_points((SZ, SZ), (1, 1), 5, 5, 0)
        @test !isempty(pts)
        @test all(1 <= p.idx[1] <= SZ && 1 <= p.idx[2] <= SZ for p in pts)
        # circle stencil: dome 1 at center, within [0, 1]
        st = MonteCarloArt.stencil(5, 5, 0)
        @test any(t -> t[1] == 0 && t[2] == 0 && t[3] == 1.0, st)
        @test all(0 <= t[3] <= 1 for t in st)
        # theta_bin 0 ellipse: major axis along x (cols)
        el = MonteCarloArt.stencil(6, 2, 0)
        @test maximum(abs(t[2]) for t in el) > maximum(abs(t[1]) for t in el)
    end

    @testset "softmax_pick → argmin at low temperature" begin
        pal = [L(10, 0, 0), L(50, 0, 0), L(90, 0, 0)]
        Random.seed!(1)
        @test all(MonteCarloArt.softmax_pick(pal, L(48, 0, 0), 1e-3) == 2 for _ = 1:50)
    end

    @testset "resolve_background" begin
        inp = blocks(SZ)
        @test MonteCarloArt.resolve_background("white", inp) == L(100, 0, 0)
        @test MonteCarloArt.resolve_background("black", inp) == L(0, 0, 0)
        @test MonteCarloArt.resolve_background("#000000", inp).l ≈ 0 atol = 1e-6
        @test_throws ErrorException MonteCarloArt.resolve_background("nope", inp)
    end

    @testset "render reduces error" begin
        inp = blocks(SZ)
        Random.seed!(42)
        strokes, h, w = MonteCarloArt.render(inp, cfg())
        @test (h, w) == (SZ, SZ)
        @test !isempty(strokes)
        @test all(1 <= s.center[1] <= SZ && 1 <= s.center[2] <= SZ for s in strokes)
        png = MonteCarloArt.render_png(strokes, h, w)
        @test err(png, inp) < 0.5 * err(fill(L(100, 0, 0), SZ, SZ), inp)
    end

    @testset "no strokes where canvas already matches background" begin
        inp = blocks(SZ)
        Random.seed!(42)
        strokes, _, _ = MonteCarloArt.render(inp, cfg(); bg=L(100, 0, 0))
        # white is ~75% of the area; only spill-over around block edges
        # (residual re-opened by overpaint) may land there. Mean-seeded
        # residual put ~74% of centers on white.
        @test mean(inp[s.center...] == L(100, 0, 0) for s in strokes) < 0.35
    end

    @testset "deterministic under fixed seed (fixed thread count)" begin
        inp = blocks(SZ)
        Random.seed!(7)
        a, _, _ = MonteCarloArt.render(inp, cfg(; steps=1000))
        Random.seed!(7)
        b, _, _ = MonteCarloArt.render(inp, cfg(; steps=1000))
        @test a == b
    end

    @testset "svg + gif writers" begin
        inp = blocks(SZ)
        Random.seed!(42)
        strokes, h, w = MonteCarloArt.render(inp, cfg(; steps=1000))
        svg = MonteCarloArt.render_svg(strokes, h, w)
        @test occursin("<svg", svg) && occursin("</svg>", svg)
        @test count("<ellipse", svg) == length(strokes)
        frames = MonteCarloArt.render_gif(strokes, h, w)
        @test length(frames) == cld(length(strokes), MonteCarloArt.GIF_INTERVAL)
        @test size(first(frames)) == (SZ, SZ)
    end
end
