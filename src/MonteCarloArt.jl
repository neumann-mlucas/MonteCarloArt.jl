module MonteCarloArt

include("common.jl")

const Image = Matrix{Lab{Float64}}
const Circle = @NamedTuple{
    center::Tuple{Int,Int},
    radius::Int,
    color::Lab{Float64},
}

const REL_RADIUS = 0.0032
const REL_STD_RADIUS = 0.4
const MIN_RADIUS = 2
const RMAX_REFRESH = 2000
# Edge-aware radius: mean_r scales by (1 - EDGE_SHRINK * edge_norm).
# edge=0 (flat): full radius; edge=1 (strong edge): shrink to 30%.
const EDGE_SHRINK = 0.7
# EMA(α=0.99) needs ~500 steps to converge; guard against pathological
# early stops on tiny --steps budgets. Hardcoded — no user knob.
const MIN_STEPS_FOR_EMA_STOP = 500
# GIF: snapshot every N committed circles. ~200-400 frames typical.
const GIF_INTERVAL = 100
const GIF_FPS = 15
# EMA smoothing factor for miss rate; obs weighted (1-EMA_ALPHA).
const EMA_ALPHA = 0.99

const GifFrames = Vector{Matrix{RGB{N0f8}}}

@inline update_ema(prev::Float64, obs::Float64)::Float64 =
    EMA_ALPHA * prev + (1 - EMA_ALPHA) * obs

# Circle-shape offset cache. Radii repeat across proposals; cache avoids
# rebuilding the (2r+1)² stencil per candidate. Locked because Base.Dict is
# not thread-safe under concurrent get!.
const STENCIL_LOCK = ReentrantLock()
const STENCIL_CACHE = Dict{Int,Vector{Tuple{Int,Int}}}()

stencil(r::Int) = @lock STENCIL_LOCK get!(STENCIL_CACHE, r) do
    Tuple{Int,Int}[(dy, dx) for dx in -r:r, dy in -r:r if dx * dx + dy * dy <= r * r]
end

Base.@kwdef struct Config
    steps::Int = 200000
    color_palette::Int = 64
    overlap_tolerance::Float64 = 0.15
    stop_miss_rate::Float64 = 0.99
    format::Symbol = :svg
end

export Config
export load_color_image, load_image, render, save_gif

""" Load a grayscale version of the image and convert to Lab color space. """
function load_image(path::String)::Image
    isfile(path) || error("Image file not found: $path")
    img = Images.load(path)
    convert.(Lab{Float64}, Gray.(img))
end

""" Load a color image and convert to Lab color space. """
function load_color_image(path::String)::Image
    isfile(path) || error("Image file not found: $path")
    img = Images.load(path)
    convert.(Lab{Float64}, img)
end

""" Sobel-magnitude edge map of L channel, normalized to [0, 1]. """
function edge_magnitude(inp::Image)::Matrix{Float64}
    h, w = size(inp)
    L = [c.l for c in inp]
    mag = zeros(h, w)
    @inbounds for y in 2:h-1, x in 2:w-1
        gy = L[y+1, x] - L[y-1, x]
        gx = L[y, x+1] - L[y, x-1]
        mag[y, x] = sqrt(gx * gx + gy * gy)
    end
    m = maximum(mag)
    m > 0 ? mag ./ m : mag
end

""" Main Monte Carlo Art algorithm. Returns Lab image (:png), SVG string (:svg), or GIF frames (:gif). """
function render(inp::Image, cfg::Config)::Union{Image,String,GifFrames}
    h, w = size(inp)
    penalty = zeros(Float64, h, w)
    circles = Circle[]

    palette = kmeans_palette_lab(inp, cfg.color_palette)
    @info "Finished generating color palette with $(cfg.color_palette) colors"

    edge_map = edge_magnitude(inp)
    @info "Computed edge map (mean=$(round(mean(edge_map), digits=3)), max=$(round(maximum(edge_map), digits=3)))"

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

        cand_circles = Vector{Circle}(undef, n_batch)
        cand_points  = Vector{Vector{CartesianIndex{2}}}(undef, n_batch)
        Threads.@threads for k in 1:n_batch
            cand_circles[k], cand_points[k] = propose(inp, residual, r_max, palette, edge_map,
                                                      h, w, step + k, cfg)
        end

        # sequential commit: re-check overlap against updated penalty so
        # late candidates in the batch see prior commits' effects.
        # Also dedupe: threads share the residual snapshot and often
        # propose near-identical centers; drop candidates that fall inside
        # an earlier accept in the same batch.
        committed_batch = Tuple{Int,Int,Int}[]  # (y, x, r)
        for k in 1:n_batch
            cand = cand_circles[k]
            points = cand_points[k]
            cy, cx, cr = cand.center[1], cand.center[2], cand.radius

            if isempty(points)
                misses += 1
                ema_miss = update_ema(ema_miss, 1.0)
                continue
            end

            too_close = false
            for (y, x, r) in committed_batch
                dy, dx = cy - y, cx - x
                mr = min(cr, r)
                if dy * dy + dx * dx < mr * mr
                    too_close = true
                    break
                end
            end

            if too_close
                misses += 1
                ema_miss = update_ema(ema_miss, 1.0)
                continue
            end

            overlap = mean(penalty[p] for p in points)
            miss = overlap >= cfg.overlap_tolerance
            if !miss
                accept += 1
                push!(circles, cand)
                push!(committed_batch, (cy, cx, cr))
                r2 = cr * cr + 1
                @inbounds for i in points
                    dy = i[1] - cy
                    dx = i[2] - cx
                    # dome falloff: 1 at center, 0 at circle edge
                    contrib = 1 - (dy * dy + dx * dx) / r2
                    penalty[i] = min(1.0, penalty[i] + contrib)
                    residual[i] = color_distance(inp[i], cand.color)
                end
            else
                misses += 1
            end
            ema_miss = update_ema(ema_miss, miss ? 1.0 : 0.0)
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
        return render_svg(circles, h, w)
    elseif cfg.format == :gif
        return render_gif(circles, h, w)
    else
        return render_png(circles, h, w)
    end
end

""" Propose one circle candidate. Reads residual/penalty as a snapshot;
    safe to call in parallel across threads with shared read-only inputs.
    Returns (circle, points) — points transient, not stored per accept. """
@inline function propose(inp::Image, residual::Matrix{Float64}, r_max::Float64,
                         palette::Vector{Lab{Float64}}, edge_map::Matrix{Float64},
                         h::Int, w::Int, step::Int, cfg::Config)::Tuple{Circle,Vector{CartesianIndex{2}}}
    point  = importance_center(residual, r_max)
    radius = get_radius(h, w, @inbounds edge_map[point[1], point[2]])
    points = gen_circle_points((h, w), point, radius)
    if isempty(points)
        return ((center=point, radius=radius, color=palette[1]), points)
    end
    pixels = getindex.(Ref(inp), points)
    avg    = mean_color(pixels)
    idx    = argmin(color_distance(c, avg) for c in palette)
    ((center=point, radius=radius, color=palette[idx]), points)
end

""" Render list of circles into a Lab image (white background). """
function render_png(circles::Vector{Circle}, h::Int, w::Int)::Image
    out = fill(Lab{Float64}(100, 0, 0), h, w)
    for c in circles, i in gen_circle_points((h, w), c.center, c.radius)
        out[i] = c.color
    end
    out
end

""" Sample a radius from a normal distribution scaled to image size and
    inversely to local edge magnitude. Strong edges shrink the mean by up
    to EDGE_SHRINK to preserve fine detail. """
@inline function get_radius(height::Int, width::Int, edge::Float64)::Int
    scale = 1.0 - EDGE_SHRINK * edge
    mean_r = min(height, width) * REL_RADIUS * scale
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

""" Generate points that form a filled circle of given radius, clipped to
    image bounds. Uses cached offset stencil per radius. """
@inline function gen_circle_points(dims::Tuple{Int,Int}, center::Tuple{Int,Int}, radius::Int)::Vector{CartesianIndex{2}}
    cy, cx = center
    h, w = dims
    CartesianIndex{2}[
        CartesianIndex(cy + dy, cx + dx)
        for (dy, dx) in stencil(radius)
        if 1 <= cy + dy <= h && 1 <= cx + dx <= w
    ]
end

""" Render list of circles into SVG content. Stream to IOBuffer to avoid
    materializing N per-circle Strings before concatenation. """
function render_svg(circles::Vector{Circle}, height::Int, width::Int)::String
    io = IOBuffer()
    println(io, svg_open(width, height))
    for c in circles
        println(io, draw_circle(c))
    end
    print(io, SVG_CLOSE)
    String(take!(io))
end

svg_color(c::Lab) = rgb_hex(convert(RGB{N0f8}, c))

""" Replay committed circles onto a running canvas, snapshotting every
    GIF_INTERVAL circles. Frames in display-space RGB{N0f8}. """
function render_gif(circles::Vector{Circle}, h::Int, w::Int)::GifFrames
    out = fill(Lab{Float64}(100, 0, 0), h, w)
    frames = GifFrames()
    for (n, c) in enumerate(circles)
        @inbounds for i in gen_circle_points((h, w), c.center, c.radius)
            out[i] = c.color
        end
        if n % GIF_INTERVAL == 0 || n == length(circles)
            push!(frames, convert.(RGB{N0f8}, out))
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

""" Draw a circle in SVG format. Darker outline via L-shift toward black. """
function draw_circle(c::Circle)::String
    fill = svg_color(c.color)
    stroke = svg_color(Lab(max(c.color.l - 12, 0), c.color.a, c.color.b))
    """<circle cx="$(c.center[2])" cy="$(c.center[1])" r="$(c.radius)" fill="$fill" stroke="$stroke" stroke-width="0.5" />"""
end

end
