module MonteCarloArt

include("common.jl")

const Image = Matrix{Lab{Float64}}
const Circle = @NamedTuple{
    center::Tuple{Int,Int},
    radius::Int,
    color::Lab{Float64},
    points::Vector{CartesianIndex{2}},
}

const REL_RADIUS = 0.0032
const REL_STD_RADIUS = 0.4
const MIN_RADIUS = 2
const RMAX_REFRESH = 2000
# EMA(α=0.99) needs ~500 steps to converge; guard against pathological
# early stops on tiny --steps budgets. Hardcoded — no user knob.
const MIN_STEPS_FOR_EMA_STOP = 500
# GIF: snapshot every N committed circles. ~200-400 frames typical.
const GIF_INTERVAL = 100
const GIF_FPS = 15

const GifFrames = Vector{Matrix{RGB{N0f8}}}

Base.@kwdef struct Config
    steps::Int = 200000
    color_palette::Int = 64
    overlap_tolerance::Float64 = 0.08
    stop_miss_rate::Float64 = 1.0
    alpha::Float64 = 1.0
    format::Symbol = :png
end

export Config
export load_color_image, load_image, render, save_gif

""" Load a grayscale version of the image and convert to Lab color space. """
function load_image(path::String)::Image
    @assert isfile(path) "Image file not found: $path"
    img = Images.load(path)
    convert.(Lab{Float64}, complement.(Gray.(img)))
end

""" Load a color image and convert to Lab color space. """
function load_color_image(path::String)::Image
    @assert isfile(path) "Image file not found: $path"
    img = Images.load(path)
    convert.(Lab{Float64}, complement.(img))
end

""" Main Monte Carlo Art algorithm. Returns Lab image (:png), SVG string (:svg), or GIF frames (:gif). """
function render(inp::Image, cfg::Config)::Union{Image,String,GifFrames}
    h, w = size(inp)
    penalty = zeros(Float64, h, w)
    circles = Circle[]

    palette = kmeans_palette_lab(inp, cfg.color_palette)
    @info "Finished generating color palette with $(cfg.color_palette) colors"

    # importance-sampling state: residual[i] = ||inp[i] - current_canvas[i]||
    # in Lab. Sampling proposed centers proportional to residual concentrates
    # circles on under-approximated regions. Seed canvas as image mean so
    # initial residual reflects local deviation, not raw luminance.
    canvas_seed = mean_color(vec(inp))
    residual = color_distance.(inp, Ref(canvas_seed))
    r_max    = maximum(residual)

    batch_size = Threads.nthreads()
    accept, misses = 0, 0
    ema_miss  = 0.0
    next_rmax = RMAX_REFRESH
    step      = 0
    progress_stride = max(1, cfg.steps ÷ 20)
    next_progress   = progress_stride

    while step < cfg.steps
        n_batch = min(batch_size, cfg.steps - step)
        if step >= next_rmax
            r_max = maximum(residual)
            next_rmax += RMAX_REFRESH
        end

        candidates = Vector{Circle}(undef, n_batch)
        Threads.@threads for k in 1:n_batch
            candidates[k] = propose(inp, residual, r_max, palette,
                                    h, w, step + k, cfg)
        end

        # sequential commit: re-check overlap against updated penalty so
        # late candidates in the batch see prior commits' effects
        for cand in candidates
            overlap = mean(penalty[p] for p in cand.points)
            miss = overlap >= cfg.overlap_tolerance
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

        if step >= next_progress
            pct = lpad(round(Int, 100 * step / cfg.steps), 3)
            @info "progress: $pct% ($step/$(cfg.steps))  circles=$(length(circles))  ema_miss=$(round(ema_miss, digits=3))"
            next_progress += progress_stride
        end

        if step >= MIN_STEPS_FOR_EMA_STOP && ema_miss > cfg.stop_miss_rate
            @info "Early stop at step $step of $(cfg.steps) (ema_miss=$(round(ema_miss, digits=3)) > $(cfg.stop_miss_rate))"
            break
        end
    end

    to_pct(x) = lpad(round(Int, 100 * x / max(step, 1)), 3)
    @info "Finished algorithm steps ($step of $(cfg.steps)) with $(length(circles)) circles drawn"
    @info "  - accept:  $(lpad(accept, 8)) [$(to_pct(accept))%]"
    @info "  - misses:  $(lpad(misses, 8)) [$(to_pct(misses))%]"

    if cfg.format == :svg
        return render_svg(circles, h, w, cfg.alpha)
    elseif cfg.format == :gif
        return render_gif(circles, h, w, cfg.alpha)
    else
        return render_png(circles, h, w, cfg.alpha)
    end
end

""" Propose one circle candidate. Reads residual/penalty as a snapshot;
    safe to call in parallel across threads with shared read-only inputs. """
@inline function propose(inp::Image, residual::Matrix{Float64}, r_max::Float64,
                         palette::Vector{Lab{Float64}}, h::Int, w::Int,
                         step::Int, cfg::Config)::Circle
    point  = importance_center(residual, r_max)
    radius = get_radius(h, w)
    points = gen_circle_points((h, w), point, radius)
    pixels = getindex.(Ref(inp), points)
    avg    = mean_color(pixels)
    idx    = argmin(color_distance(c, avg) for c in palette)
    (center=point, radius=radius, color=palette[idx], points=points)
end

""" Render list of circles into a Lab image. alpha=1.0 overwrites (Seurat off);
    alpha<1.0 blends new color into canvas per-channel (optical mixing). """
function render_png(circles::Vector{Circle}, h::Int, w::Int, alpha::Float64=1.0)::Image
    out = fill(Lab{Float64}(0, 0, 0), h, w)
    if alpha >= 1.0
        for c in circles, i in c.points
            out[i] = c.color
        end
    else
        a, b = alpha, 1.0 - alpha
        for c in circles, i in c.points
            p = out[i]; q = c.color
            out[i] = Lab{Float64}(a * q.l + b * p.l,
                                  a * q.a + b * p.a,
                                  a * q.b + b * p.b)
        end
    end
    out
end

""" Sample a radius from a normal distribution scaled to image size. """
@inline function get_radius(height::Int, width::Int)::Int
    mean_r = min(height, width) * REL_RADIUS
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
@inline function gen_circle_points(dims::Tuple{Int,Int}, center::Tuple{Int,Int}, radius::Int)::Vector{CartesianIndex{2}}
    CartesianIndex{2}[
        CartesianIndex(center[1] + dx, center[2] + dy)
        for dx in -radius:radius, dy in -radius:radius
        if dx^2 + dy^2 <= radius^2 && 1 <= center[1] + dx <= dims[1] && 1 <= center[2] + dy <= dims[2]
    ]
end

""" Render list of circles into SVG content. Stream to IOBuffer to avoid
    materializing N per-circle Strings before concatenation. """
function render_svg(circles::Vector{Circle}, height::Int, width::Int, alpha::Float64=1.0)::String
    io = IOBuffer()
    println(io, svg_open(width, height))
    for c in circles
        println(io, draw_circle(c, alpha))
    end
    print(io, SVG_CLOSE)
    String(take!(io))
end

# Circles are stored in complement-Lab space (see load_*_image). SVG needs
# display-space colors, so invert before hexifying.
svg_color(c::Lab) = rgb_hex(complement(convert(RGB{N0f8}, c)))

""" Replay committed circles onto a running canvas, snapshotting every
    GIF_INTERVAL circles. Frames in display-space RGB{N0f8}. """
function render_gif(circles::Vector{Circle}, h::Int, w::Int, alpha::Float64=1.0)::GifFrames
    out = fill(Lab{Float64}(0, 0, 0), h, w)
    frames = GifFrames()
    a, b = alpha, 1.0 - alpha
    for (n, c) in enumerate(circles)
        if alpha >= 1.0
            @inbounds for i in c.points
                out[i] = c.color
            end
        else
            @inbounds for i in c.points
                p = out[i]; q = c.color
                out[i] = Lab{Float64}(a * q.l + b * p.l,
                                      a * q.a + b * p.a,
                                      a * q.b + b * p.b)
            end
        end
        if n % GIF_INTERVAL == 0 || n == length(circles)
            push!(frames, complement.(convert.(RGB{N0f8}, out)))
        end
    end
    @info "GIF: $(length(frames)) frames at $GIF_FPS fps ($(round(length(frames)/GIF_FPS, digits=1))s clip)"
    frames
end

""" Write GIF frames as animated GIF. Mirrors StringArt.save_gif. """
function save_gif(path::String, frames::GifFrames)
    isempty(frames) && return
    save(path, stack(frames; dims=3), fps=GIF_FPS)
end

""" Draw a circle in SVG format. """
function draw_circle(c::Circle, alpha::Float64=1.0)::String
    fill = svg_color(c.color)
    # Darker outline in output: shift L up in complement-Lab space, keep a/b,
    # clamp to gamut to avoid out-of-range values.
    stroke = svg_color(Lab(min(c.color.l + 12, 100), c.color.a, c.color.b))
    # Match stroke opacity to fill opacity, else outlines look hard over faded fill.
    op = alpha >= 1.0 ? "" : " fill-opacity=\"$(round(alpha, digits=3))\" stroke-opacity=\"$(round(alpha, digits=3))\""
    """<circle cx="$(c.center[2])" cy="$(c.center[1])" r="$(c.radius)" fill="$fill"$op stroke="$stroke" stroke-width="0.5" />"""
end

end
