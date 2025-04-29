module MonteCarloArt

using ArgParse
using Base
using Base.Threads
using Dates
using FileIO
using Images
using Logging
using Statistics

const Image = Matrix{Lab{Float64}}

const DefaultArgs = Dict{String,Any}

const N_PALLET = 64

const REL_RADIUS = 0.0030
const REL_STD_RADIUS = 0.8
const MIN_RADIUS = 1.0

const BASE_ENERGY = 0.1

export load_color_image
export load_image
export run

function load_image(image_path::String)::Image
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Convert the Image to gray scale
    gray_img = complement.(Gray.(img))
    convert.(Lab{Float64}, gray_img)
end

function load_color_image(image_path::String)::Image
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Convert the Image to Lab color space
    convert.(Lab{Float64}, complement.(img))
end

function run(inp::Image, args::Dict=DefaultArgs)::Image
    @debug "Entering algorithm subroutine"
    h, w = size(inp)
    out = zeros(Lab{Float64}, h, w)
    penalty = zeros(Float64, h, w)

    @info "Generatiing Image Color Pallet"
    pallet = get_pallet(inp)

    @info "Starting algorithm iterative steps"
    accept, mc_accept, misses = 0, 0, 0
    for step in 1:args["steps"]
        @debug "Step: $step"
        point = get_center(h, w)
        radius = get_radius(h, w)

        @debug "Creating candidate circle at: $point with radius: $radius"
        points = gen_circle_points((h, w), point, radius)
        pixels = getindex.(Ref(inp), points)

        @debug "Picking a color in the pallet to use"
        avg = mean_color(pixels)
        idx = argmin([color_distance(c, avg) for c in pallet])
        color = pallet[idx]

        @debug "Running Monte Carlo like Criteria to Draw the circle"
        energy = mean(penalty[p] for p in points)
        draw_circle = false
        if energy < BASE_ENERGY
            @debug "Accpect energy, lower than base: $energy"
            draw_circle = true
            accept += 1
        elseif (energy / BASE_ENERGY) < rand()
            @info "Accpect energy using MC criteria: $(energy / BASE_ENERGY)"
            draw_circle = true
            mc_accept += 1
        else
            @debug "Reject energy: $energy"
            misses += 1
        end

        if draw_circle
            @debug "Drawing circle at: $point with radius: $radius"
            for i in points
                out[i] = color
                penalty[i] += 1
            end
        end
    end

    to_pct(x) = 100 * round(x / args["steps"], digits=2)
    @info "Done with processing image"
    @info "  - accept:    $accept ($(to_pct(accept)) %)"
    @info "  - mc_accept: $mc_accept ($(to_pct(mc_accept)) %)"
    @info "  - misses:    $misses ($(to_pct(misses)) %)"
    out
end

function get_radius(height, width)::Int64
    radius = min(height, width) * REL_RADIUS
    std = radius * REL_STD_RADIUS
    floor(Int, abs(randn() * std + max(1.2, MIN_RADIUS)))
end

function get_center(height, width)::Tuple{Int64,Int64}
    (rand(1:height), rand(1:width))
end

function gen_circle_points(size::Tuple{Int,Int}, center::Tuple{Int,Int}, radius::Int)
    points = CartesianIndex[]
    for dx in -radius:radius, dy in -radius:radius
        if dx^2 + dy^2 <= radius^2
            x, y = center[1] + dx, center[2] + dy
            if 1 ≤ x ≤ size[1] && 1 ≤ y ≤ size[2]
                push!(points, CartesianIndex(x, y))
            end
        end
    end
    points
end

function get_pallet(img::Image)::Vector{Lab{Float64}}
    # get pixels array
    pixels = reshape(collect(channelview(img)), 3, :)
    # clustering
    result = kmeans(pixels, N_PALLET)
    # convert back to Lab color space
    [Lab{Float64}(c...) for c in eachcol(result.centers)]
end

function color_distance(c1::Lab, c2::Lab)::Float64
    sqrt((c1.l - c2.l)^2 + (c1.a - c2.a)^2 + (c1.b - c2.b)^2)
end

function mean_color(pixels::Vector{Lab{Float64}})::Lab{Float64}
    l = mean(c.l for c in pixels)
    a = mean(c.a for c in pixels)
    b = mean(c.b for c in pixels)
    Lab{Float64}(l, a, b)
end

end
