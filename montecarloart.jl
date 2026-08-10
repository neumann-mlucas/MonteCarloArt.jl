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
const REL_RADIUS = 0.0032
const REL_STD_RADIUS = 0.4
const MIN_RADIUS = 2
const RMAX_REFRESH = 2000

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
    h, w = size(inp)
    penalty = zeros(Float64, h, w)
    circles = NamedTuple[]

    palette = get_palette(inp, args)
    @info "Finished generating color palette with $(args["color-palette"]) colors"

    # importance-sampling state: residual[i] = ||inp[i] - current_canvas[i]||
    # in Lab. Sampling proposed centers proportional to residual concentrates
    # circles on under-approximated regions. Seed canvas as image mean so
    # initial residual reflects local deviation, not raw luminance.
    canvas_seed = mean_color(vec(inp))
    residual    = color_distance.(inp, Ref(canvas_seed))
    r_max       = maximum(residual)

    base_tolerance = args["overlap-tolerance"]
    steps          = args["steps"]
    r0             = args["radius-start"]
    r1             = args["radius-end"]
    batch_size     = max(1, args["batch-size"])
    stop_miss_rate = args["stop-miss-rate"]
    min_steps      = args["min-steps"]

    accept, misses = 0, 0
    ema_miss  = 0.0
    next_rmax = RMAX_REFRESH
    step      = 0

    while step < steps
        n_batch = min(batch_size, steps - step)
        if step >= next_rmax
            r_max = maximum(residual)
            next_rmax += RMAX_REFRESH
        end

        candidates = Vector{NamedTuple}(undef, n_batch)
        if n_batch == 1 || Threads.nthreads() == 1
            for k in 1:n_batch
                candidates[k] = _propose(inp, residual, r_max, palette,
                                         h, w, step + k, steps, r0, r1)
            end
        else
            Threads.@threads for k in 1:n_batch
                candidates[k] = _propose(inp, residual, r_max, palette,
                                         h, w, step + k, steps, r0, r1)
            end
        end

        # sequential commit: re-check overlap against updated penalty so
        # late candidates in the batch see prior commits' effects
        for cand in candidates
            overlap = mean(penalty[p] for p in cand.points)
            miss = overlap >= base_tolerance
            if !miss
                accept += 1
                push!(circles, cand)
                @inbounds for i in cand.points
                    penalty[i]  = 1
                    residual[i] = color_distance(inp[i], cand.color)
                end
            else
                misses += 1
            end
            ema_miss = 0.99 * ema_miss + 0.01 * (miss ? 1.0 : 0.0)
        end

        step += n_batch

        if step >= min_steps && ema_miss > stop_miss_rate
            @info "Early stop at step $step of $steps (ema_miss=$(round(ema_miss, digits=3)) > $stop_miss_rate)"
            break
        end
    end
    to_pct(x) = lpad(round(Int, 100 * x / max(step, 1)), 3)
    @info "Finished algorithm steps ($step of $steps) with $(length(circles)) circles drawn"
    @info "  - accept:  $(lpad(accept, 8)) [$(to_pct(accept))%]"
    @info "  - misses:  $(lpad(misses, 8)) [$(to_pct(misses))%]"

    return args["svg"] ? render_svg(circles, h, w) : render_png(circles, h, w)
end

""" Propose one circle candidate. Reads residual/penalty as a snapshot;
    safe to call in parallel across threads with shared read-only inputs. """
@inline function _propose(inp::Image, residual::Matrix{Float64}, r_max::Float64,
                          palette::Vector{Lab{Float64}}, h::Int, w::Int,
                          step::Int, steps::Int, r0::Float64, r1::Float64)::NamedTuple
    point  = importance_center(residual, r_max)
    radius = get_radius(h, w, step, steps, r0, r1)
    points = gen_circle_points((h, w), point, radius)
    pixels = getindex.(Ref(inp), points)
    avg    = mean_color(pixels)
    idx    = argmin(color_distance(c, avg) for c in palette)
    (center=point, radius=radius, color=palette[idx], points=points)
end

""" Render list of circles into a Lab image. """
function render_png(circles::Vector{NamedTuple}, h::Int, w::Int)::Image
    out = fill(Lab{Float64}(0, 0, 0), h, w)
    for c in circles
        for i in c.points
            out[i] = c.color
        end
    end
    out
end

""" Cluster image colors into a palette using k-means. """
@inline function get_palette(img::Image, args::Dict{String,Any})::Vector{Lab{Float64}}
    pixels = reshape(collect(channelview(img)), 3, :)
    result = kmeans(pixels, args["color-palette"], maxiter=100, display=:none)
    [Lab{Float64}(c...) for c in eachcol(result.centers)]
end

""" Get a random radius with some randomness based on image size and step.
    Mean radius interpolates linearly from r0*REL_RADIUS at step 1 to
    r1*REL_RADIUS at step `steps` — broad early strokes, fine late detail. """
@inline function get_radius(height::Int, width::Int, step::Int, steps::Int,
                            r0::Float64, r1::Float64)::Int
    t = steps > 1 ? (step - 1) / (steps - 1) : 0.0
    mult = r0 + (r1 - r0) * t
    mean_r = min(height, width) * REL_RADIUS * mult
    std = mean_r * REL_STD_RADIUS
    max(MIN_RADIUS, floor(Int, abs(randn() * std + mean_r)))
end

""" Sample a center via rejection, biased toward high-residual pixels. """
@inline function importance_center(residual::Matrix{Float64}, r_max::Float64)::Tuple{Int,Int}
    h, w = size(residual)
    # degenerate case: residual collapsed to zero, fall back to uniform
    r_max <= 0 && return (rand(1:h), rand(1:w))
    while true
        y, x = rand(1:h), rand(1:w)
        @inbounds if rand() * r_max < residual[y, x]
            return (y, x)
        end
    end
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
function render_svg(circles::Vector{NamedTuple}, height::Int, width::Int)::String
    header = """
    <svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" viewBox="0 0 $width $height">
    """
    body = join([draw_circle(c) for c in circles], "\n")
    footer = "</svg>"

    return join([header, body, footer], "\n")
end

""" Draw a circle in SVG format. """
function draw_circle(c::NamedTuple)::String
    fill = lab_to_rgb_hex(c.color)
    # Darker outline in output: shift L up in complement-Lab space, keep a/b,
    # clamp to gamut to avoid the out-of-range values the previous formula
    # produced for lightness near 100.
    stroke = lab_to_rgb_hex(Lab(min(c.color.l + 12, 100), c.color.a, c.color.b))
    """<circle cx="$(c.center[2])" cy="$(c.center[1])" r="$(c.radius)" fill="$fill" stroke="$stroke" stroke-width="0.5" />"""
end

""" Convert Lab color to RGB hex string. """
function lab_to_rgb_hex(color::Lab{Float64})::String
    rgb = complement(convert(Colors.RGB{N0f8}, color))
    @sprintf("#%02X%02X%02X", round(Int, 255 * rgb.r), round(Int, 255 * rgb.g), round(Int, 255 * rgb.b))
end

end
