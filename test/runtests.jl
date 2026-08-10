using Test
using Images
include(joinpath(@__DIR__, "..", "src", "MonteCarloArt.jl"))
using .MonteCarloArt

@testset "MonteCarloArt smoke" begin
    fixture = joinpath(@__DIR__, "fixtures", "moon.jpg")
    if !isfile(fixture)
        @info "skipping — no test/fixtures/moon.jpg"
        return
    end
    inp = MonteCarloArt.load_image(fixture)
    cfg = MonteCarloArt.Config(steps=200, color_palette=8, format=:png)
    out = MonteCarloArt.render(inp, cfg)
    @test size(out) == size(inp)
    @test eltype(out) <: Lab
end
