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
const Image = Matrix{N0f8}
const Colors = Vector{RGB{N0f8}}

const DefaultArgs = Dict{String,Any}

const REL_RADIUS = 0.0025
const REL_STD_RADIUS = 0.6
const MIN_RADIUS = 1.0

const BASE_ENERGY = N0f8(0.8)

export aggreate_images
export load_color_image
export load_image
export run

function load_image(image_path::String)::Image
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Convert the Image to gray scale
    complement.(N0f8.(Gray.(img)))
end

function load_color_image(image_path::String, colors::Colors)::Vector{Image}
    # Read the image and convert it to an array
    @assert isfile(image_path)
    img = Images.load(image_path)
    # Extract colors from Image and convert to gray scale
    extract_color(color) = N0f8.(Gray.(mapc.(*, img, color)))
    map(extract_color, colors)
end

function run(inp::Image, args::Dict=DefaultArgs)::Image
    @debug "Starting algorithm..."
    h, w = size(inp)
    out = zeros(N0f8, h, w)

    for step in 1:args["steps"]
        @debug "Step: $step"
        point = (rand(1:h), rand(1:w))
        radius = get_radius(h, w)

        @debug "Creating candidate circle at: $point with radius: $radius"
        points = gen_circle_points((h, w), point, radius)
        @debug "Meaning energy of circle: $points"
        energy = mean(getindex.(Ref(inp), points))

        @debug "Running Monte Carlo Criteria to Draw the circle..."
        draw_circle = false
        if energy > BASE_ENERGY
            @debug "Accpect energy, higher than base: $energy"
            draw_circle = true
        elseif energy / BASE_ENERGY > rand()
            @debug "Accpect energy using MC criteria: $energy"
            draw_circle = true
        else
            @debug "Reject energy: $energy"
        end

        if draw_circle
            @debug "Drawing circle at: $point with radius: $radius"
            for i in points
                out[i] = clamp(float32(out[i]) + float32(energy) / 1.5, 0.0, 1.0)
                inp[i] = clamp(float32(inp[i]) - float32(energy) / 0.5, 0.0, 1.0)
            end
        end
    end
    @info "Done with processing image"
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

function aggreate_images(imgs::Vector{Matrix{N0f8}}, colors::Colors)::Matrix{RGB{Float64}}
    imgs = [img .* color for (img, color) in zip(imgs, colors)]
    foldr(.+, imgs)
end

end
