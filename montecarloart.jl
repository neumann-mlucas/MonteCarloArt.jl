module MonteCarloArt

using ArgParse
using Base
using Base.Threads
using Dates
using FileIO
using Images
using Logging
using Statistics
using Clustering: kmeans

const Image = Matrix{Lab{Float64}}
const DefaultArgs = Dict{String,Any}()
const N_PALLET = 64
const REL_RADIUS = 0.0030
const REL_STD_RADIUS = 0.8
const MIN_RADIUS = 1.0
const BASE_ENERGY = 0.1

export load_color_image, load_image, run

""" Load a grayscale version of the image and convert to Lab color space. """
function load_image(image_path::String)::Image
    @assert isfile(image_path) "Image file not found: $image_path"
    img = Images.load(image_path)
    gray_img = complement.(Gray.(img))
    convert.(Lab{Float64}, gray_img)
end

""" Load a color image and convert to Lab color space. """
function load_color_image(image_path::String)::Image
    @assert isfile(image_path) "Image file not found: $image_path"
    img = Images.load(image_path)
    convert.(Lab{Float64}, complement.(img))
end

""" Main Monte Carlo Art algorithm. """
function run(inp::Image, args::Dict=DefaultArgs)::Image
    @info "Starting Monte Carlo Art generation"
    h, w = size(inp)
    out = fill(Lab{Float64}(0, 0, 0), h, w)
    penalty = zeros(Float64, h, w)

    @info "Generating image color palette with $N_PALLET colors"
    pallet = get_pallet(inp)

    accept, mc_accept, misses = 0, 0, 0

    steps = get(args, "steps", 10000)
    for step in 1:steps
        @debug "Step $step of $steps"
        point = get_center(h, w)
        radius = get_radius(h, w)
        points = gen_circle_points((h, w), point, radius)
        pixels = getindex.(Ref(inp), points)

        avg = mean_color(pixels)
        idx = argmin(color_distance(c, avg) for c in pallet)
        color = pallet[idx]

        energy = mean(penalty[p] for p in points)
        draw_circle = false

        @debug "Applying Monte Carlo acceptance criteria"
        if energy < BASE_ENERGY
            draw_circle = true
            accept += 1
        elseif (energy / BASE_ENERGY) < rand()
            draw_circle = true
            mc_accept += 1
        else
            misses += 1
        end

        @debug "Drawing circle: center $point radius $radius"
        if draw_circle
            for i in points
                out[i] = color
                penalty[i] += 1
            end
        end
    end

    to_pct(x) = 100 * round(x / steps, digits=2)
    @info "Completed image generation:"
    @info "  - accept:    $accept ($(to_pct(accept)) %)"
    @info "  - mc_accept: $mc_accept ($(to_pct(mc_accept)) %)"
    @info "  - misses:    $misses ($(to_pct(misses)) %)"

    return out
end

""" Get a random radius with some randomness based on image size. """
@inline function get_radius(height::Int, width::Int)::Int
    radius = min(height, width) * REL_RADIUS
    std = radius * REL_STD_RADIUS
    floor(Int, abs(randn() * std + max(MIN_RADIUS, 1.2)))
end

""" Get a random center point inside the image. """
@inline function get_center(height::Int, width::Int)::Tuple{Int,Int}
    (rand(1:height), rand(1:width))
end

""" Generate points that form a filled circle of given radius. """
@inline function gen_circle_points(size::Tuple{Int,Int}, center::Tuple{Int,Int}, radius::Int)
    CartesianIndex[
        CartesianIndex(center[1] + dx, center[2] + dy)
        for dx in -radius:radius, dy in -radius:radius
        if dx^2 + dy^2 <= radius^2 && 1 <= center[1] + dx <= size[1] && 1 <= center[2] + dy <= size[2]
    ]
end

""" Cluster image colors into a palette using k-means. """
@inline function get_pallet(img::Image)::Vector{Lab{Float64}}
    pixels = reshape(collect(channelview(img)), 3, :)
    result = kmeans(pixels, N_PALLET)
    [Lab{Float64}(c...) for c in eachcol(result.centers)]
end

""" Calculate Euclidean distance between two Lab colors. """
@inline function color_distance(c1::Lab, c2::Lab)::Float64
    sqrt((c1.l - c2.l)^2 + (c1.a - c2.a)^2 + (c1.b - c2.b)^2)
end

""" Calculate the mean Lab color from a list of Lab pixels. """
@inline function mean_color(pixels::Vector{Lab{Float64}})::Lab{Float64}
    Lab{Float64}(
        mean(c.l for c in pixels),
        mean(c.a for c in pixels),
        mean(c.b for c in pixels)
    )
end

end
