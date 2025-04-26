module MonteCarloArt

using ArgParse
using Base
using Base.Threads
using Dates
using FileIO
using Images
using Logging
using Statistics

const Point = Tuple{Int64,Int64}
const Image = Matrix{RGB{Float64}}
const Colors = Vector{RGB{Float64}}

const DefaultArgs = Dict{String,Any}

const REL_RADIUS = 0.0025
const REL_STD_RADIUS = 0.8
const MIN_RADIUS = 1.0

# const BASE_ENERGY = N0f8(0.7)
const BASE_ENERGY = 0.7

export aggreate_images
export load_color_image
export load_image
export run

function load_image(image_path::String)::Image
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Convert the Image to gray scale
    complement.(RGB{Float64}.(Gray.(img)))
end

function load_color_image(image_path::String)::Image
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    complement.(RGB{Float64}.(img))
end

function run(inp::Image, args::Dict=DefaultArgs)::Image
    @debug "Starting algorithm..."
    h, w = size(inp)
    out = zeros(RGB{Float64}, h, w)

    accept, mc_accept, misses  = 0, 0, 0
    for step in 1:args["steps"]
        @debug "Step: $step"
        point = (rand(1:h), rand(1:w))
        radius = get_radius(h, w)

        @debug "Creating candidate circle at: $point with radius: $radius"
        points = gen_circle_points((h, w), point, radius)
        pixels = getindex.(Ref(inp), points)

        color = mean_color_lab(pixels)
        energy = Gray{Float64}(color)

        @debug "Running Monte Carlo Criteria to Draw the circle..."
        draw_circle = false
        if energy > BASE_ENERGY
            @debug "Accpect energy, higher than base: $energy"
            draw_circle = true
            accept += 1
        elseif energy > rand() # wrong criteria
            @debug "Accpect energy using MC criteria: $energy"
            draw_circle = true
            mc_accept += 1
        else
            @debug "Reject energy: $energy"
            misses += 1
        end

        if draw_circle
            @debug "Drawing circle at: $point with radius: $radius"
            for i in points
                out[i] = clamp01(out[i] + color * 0.5)
                inp[i] = clamp01(inp[i] - color * 0.7)
            end
        end
    end
    to_pct(x) = 100 * round(x/args["steps"], digits=2)
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

function color_distance_lab(c1::RGB, c2::RGB)::Float64
    lab1 = convert(Lab, c1)
    lab2 = convert(Lab, c2)
    sqrt((lab1.l - lab2.l)^2 + (lab1.a - lab2.a)^2 + (lab1.b - lab2.b)^2)
end

function mean_color_lab(pixels::Vector{RGB{Float64}})
    labs = convert.(Lab, pixels)
    n = length(labs)
    l = sum(c.l for c in labs) / n
    a = sum(c.a for c in labs) / n
    b = sum(c.b for c in labs) / n
    convert(RGB, Lab(l, a, b))
end

end
