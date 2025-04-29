module MonteCarloArt

using ArgParse
using Clustering: kmeans
using Dates
using FileIO
using Images
using Logging
using Printf
using Statistics

const Image = Matrix{Lab{Float64}}
const DefaultArgs = Dict{String,Any}()
const N_PALLET = 64
const REL_RADIUS = 0.0030
const REL_STD_RADIUS = 0.6
const MIN_RADIUS = 2.0
const BASE_ENERGY = 0.25

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
function run(inp::Image, args::Dict=DefaultArgs)::Union{Image,String}
    @info "Starting Monte Carlo Art generation"
    h, w = size(inp)
    penalty = zeros(Float64, h, w)
    circles = NamedTuple[]

    @info "Generating image color palette with $(args["color-pallet"]) colors"
    pallet = get_pallet(inp, args)

    base_energy = args["circle-tollerance"]
    steps = args["steps"]

    accept, mc_accept, misses = 0, 0, 0

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
        if energy < base_energy
            draw_circle = true
            accept += 1
        elseif (energy / base_energy) < rand()
            @info (energy / base_energy)
            draw_circle = true
            mc_accept += 1
        else
            misses += 1
        end

        @debug "Drawing circle: center $point radius $radius"
        if draw_circle
            push!(circles, (center=point, radius=radius, color=color))
            for i in points
                penalty[i] += 1
            end
        end
    end
    to_pct(x) = 100 * round(x / steps, digits=2)
    @info "Completed image generation:"
    @info "  - accept:    $accept ($(to_pct(accept)) %)"
    @info "  - mc_accept: $mc_accept ($(to_pct(mc_accept)) %)"
    @info "  - misses:    $misses ($(to_pct(misses)) %)"

    if args["svg"]
        return render_svg(circles, h, w)
    end

    out = fill(Lab{Float64}(0, 0, 0), h, w)
    for c in circles
        for i in gen_circle_points((h, w), c.center, c.radius)
            out[i] = c.color
        end
    end
    return out
end

""" Cluster image colors into a palette using k-means. """
@inline function get_pallet(img::Image, args::Dict{String,Any})::Vector{Lab{Float64}}
    pixels = reshape(collect(channelview(img)), 3, :)
    result = kmeans(pixels, args["color-pallet"], maxiter=100, display=:none)
    [Lab{Float64}(c...) for c in eachcol(result.centers)]
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

""" Render list of circles into SVG content. """
function render_svg(circles::Vector{NamedTuple}, width::Int, height::Int)::String
    header = """
    <svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" viewBox="0 0 $width $height">
    """

    body = join([
            """<circle cx="$(c.center[2])" cy="$(c.center[1])" r="$(c.radius)" fill="$(lab_to_rgb_hex(c.color))" />"""
            for c in circles
        ], "\n")

    footer = "</svg>"

    return join([header, body, footer], "\n")
end

""" Convert Lab color to RGB hex string. """
function lab_to_rgb_hex(color::Lab{Float64})::String
    rgb = complement(convert(Colors.RGB{N0f8}, color))
    @sprintf("#%02X%02X%02X", round(Int, 255 * rgb.r), round(Int, 255 * rgb.g), round(Int, 255 * rgb.b))
end

end
