module MonteCarloArt

include("common.jl")

const Image = Matrix{Lab{Float64}}
const Stroke = @NamedTuple{
    center::Tuple{Int,Int},  # (y, x) — Julia array order; SVG writer swaps for cx/cy
    r_major::Int,
    r_minor::Int,
    theta_bin::Int,          # angle = 2π * theta_bin / THETA_BINS (bin-aligned)
    color::Lab{Float64},
}
const StrokePoint = @NamedTuple{idx::CartesianIndex{2}, dome::Float64}

const REL_RADIUS = 0.0032
const REL_STD_RADIUS = 0.4
const MIN_RADIUS = 2
const RMAX_REFRESH = 2000
# Ellipse: r_minor = r_major * aspect. Flat regions circle; strong edges elongated.
const ELLIPSE_MIN_ASPECT = 0.45
# Quantize stroke orientation → shared stencil cache entry.
const THETA_BINS = 16
# Flat-region threshold: below this edge magnitude, angle is noise → random theta.
const FLAT_EDGE_THRESH = 0.05
# Palette jitter σ per Lab channel. Kills flat-poster look; small enough to
# stay near the k-means centroid. L ∈ [0,100], a/b ≈ [-100,100].
const JITTER_L = 3.0
const JITTER_AB = 3.0
# Softmax temperature for palette selection. Lab distances typical 5-30.
# TEMP → 0: argmin. Larger TEMP: more uniform pick (Seurat optical mixing).
const PALETTE_TEMP = 5.0
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

# Ellipse-stencil cache keyed by (r_major, r_minor, theta_bin). Stores
# (dy, dx, dome) tuples so the dome falloff (used for penalty) is precomputed
# with the shape. Locked because Base.Dict is not thread-safe under get!.
const STENCIL_LOCK = ReentrantLock()
const STENCIL_CACHE = Dict{Tuple{Int,Int,Int},Vector{Tuple{Int,Int,Float64}}}()

stencil(r_major::Int, r_minor::Int, theta_bin::Int) =
    @lock STENCIL_LOCK get!(STENCIL_CACHE, (r_major, r_minor, theta_bin)) do
        θ = 2π * theta_bin / THETA_BINS
        ct, st = cos(θ), sin(θ)
        a2 = float(r_major)^2
        b2 = float(r_minor)^2
        pts = Tuple{Int,Int,Float64}[]
        for dx = (-r_major):r_major, dy = (-r_major):r_major
            xp = dx * ct + dy * st
            yp = -dx * st + dy * ct
            v = (xp * xp) / a2 + (yp * yp) / b2
            v <= 1.0 && push!(pts, (dy, dx, 1.0 - v))
        end
        pts
    end

Base.@kwdef struct Config
    steps::Int = 200000
    color_palette::Int = 64
    overlap_tolerance::Float64 = 0.15
    stop_miss_rate::Float64 = 0.99
end

export Config, Stroke
export load_color_image, load_image, render, render_png, render_svg, render_gif, save_gif
export resolve_background

const WHITE_LAB = Lab{Float64}(100, 0, 0)
const BLACK_LAB = Lab{Float64}(0, 0, 0)

""" Resolve --background spec into a Lab color. "mean" needs `inp` (image mean).
    "white"/"black" are literals. "#rrggbb" parses via common.jl helper. """
function resolve_background(spec::AbstractString, inp::Image)::Lab{Float64}
    if spec == "white"
        WHITE_LAB
    elseif spec == "black"
        BLACK_LAB
    elseif spec == "mean"
        mean_color(vec(inp))
    elseif startswith(spec, "#")
        convert(Lab{Float64}, first(parse_hex_colors(spec)))
    else
        error("--background: expected white|black|mean|#rrggbb, got '$spec'")
    end
end

function load_image(path::String)::Image
    isfile(path) || error("Image file not found: $path")
    img = Images.load(path)
    convert.(Lab{Float64}, Gray.(img))
end

function load_color_image(path::String)::Image
    isfile(path) || error("Image file not found: $path")
    img = Images.load(path)
    convert.(Lab{Float64}, img)
end

""" Sobel-style edge features of L channel: normalized magnitude [0,1] and
    gradient angle (atan2(gy, gx), radians). Angle is undefined where mag=0;
    callers must gate on FLAT_EDGE_THRESH before trusting it. """
function edge_features(inp::Image)::Tuple{Matrix{Float64},Matrix{Float64}}
    h, w = size(inp)
    L = [c.l for c in inp]
    mag = zeros(h, w)
    ang = zeros(h, w)
    @inbounds for y = 2:(h-1), x = 2:(w-1)
        gy = L[y+1, x] - L[y-1, x]
        gx = L[y, x+1] - L[y, x-1]
        mag[y, x] = sqrt(gx * gx + gy * gy)
        ang[y, x] = atan(gy, gx)
    end
    m = maximum(mag)
    ((m > 0 ? mag ./ m : mag), ang)
end

""" Main Monte Carlo Art algorithm. Returns (strokes, height, width);
    caller picks a `render_*` writer per output format. """
function render(inp::Image, cfg::Config)::Tuple{Vector{Stroke},Int,Int}
    h, w = size(inp)
    penalty = zeros(Float64, h, w)
    strokes = Stroke[]

    palette = kmeans_palette_lab(inp, cfg.color_palette)
    @info "Finished generating color palette with $(cfg.color_palette) colors"

    edge_map, edge_angle = edge_features(inp)
    @info "Computed edge map (mean=$(round(mean(edge_map), digits=3)), max=$(round(maximum(edge_map), digits=3)))"

    # importance-sampling state: residual[i] = ||inp[i] - current_canvas[i]||
    # in Lab. Sampling proposed centers proportional to residual concentrates
    # circles on under-approximated regions. Seed canvas as image mean so
    # initial residual reflects local deviation, not raw luminance.
    canvas_seed = mean_color(vec(inp))
    residual = color_distance.(inp, Ref(canvas_seed))
    r_max = maximum(residual)

    # thread count from Threads.nthreads(); requires JULIA_NUM_THREADS or `julia -t N`
    batch_size = Threads.nthreads()
    accept, misses = 0, 0
    ema_miss = 0.0
    next_rmax = RMAX_REFRESH
    step = 0
    progress_stride = max(1, cfg.steps ÷ 20)
    next_progress = progress_stride

    while step < cfg.steps
        n_batch = min(batch_size, cfg.steps - step)
        # refresh envelope: residual updates in place per accept and can grow
        # when a painted color is a worse fit; stale r_max under-samples peaks.
        if step >= next_rmax
            r_max = maximum(residual)
            next_rmax += RMAX_REFRESH
        end

        cand_strokes = Vector{Stroke}(undef, n_batch)
        cand_points = Vector{Vector{StrokePoint}}(undef, n_batch)
        Threads.@threads for k = 1:n_batch
            cand_strokes[k], cand_points[k] =
                propose(inp, residual, r_max, palette, edge_map, edge_angle, h, w)
        end

        # sequential commit: re-check overlap against updated penalty so
        # late candidates in the batch see prior commits' effects.
        # Also dedupe: threads share the residual snapshot and often
        # propose near-identical centers; drop candidates that fall inside
        # an earlier accept in the same batch. r_major bounds the ellipse.
        committed_batch = Tuple{Int,Int,Int}[]  # (y, x, r_major)
        for k = 1:n_batch
            cand = cand_strokes[k]
            points = cand_points[k]
            cy, cx, cr = cand.center[1], cand.center[2], cand.r_major

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

            overlap = mean(penalty[p.idx] for p in points)
            miss = overlap >= cfg.overlap_tolerance
            if !miss
                accept += 1
                push!(strokes, cand)
                push!(committed_batch, (cy, cx, cr))
                @inbounds for p in points
                    penalty[p.idx] = min(1.0, penalty[p.idx] + p.dome)
                    residual[p.idx] = color_distance(inp[p.idx], cand.color)
                end
            else
                misses += 1
            end
            ema_miss = update_ema(ema_miss, miss ? 1.0 : 0.0)
        end

        step += n_batch

        if step >= next_progress
            pct = lpad(round(Int, 100 * step / cfg.steps), 3)
            @info "progress: $pct% ($step/$(cfg.steps))  strokes=$(length(strokes))  ema_miss=$(round(ema_miss, digits=3))"
            next_progress += progress_stride
        end

        if step >= MIN_STEPS_FOR_EMA_STOP && ema_miss > cfg.stop_miss_rate
            @info "Early stop at step $step of $(cfg.steps) (ema_miss=$(round(ema_miss, digits=3)) > $(cfg.stop_miss_rate))"
            break
        end
    end

    to_pct(x) = lpad(round(Int, 100 * x / max(step, 1)), 3)
    @info "Finished algorithm steps ($step of $(cfg.steps)) with $(length(strokes)) strokes drawn"
    @info "  - accept:  $(lpad(accept, 8)) [$(to_pct(accept))%]"
    @info "  - misses:  $(lpad(misses, 8)) [$(to_pct(misses))%]"

    return (strokes, h, w)
end

""" Propose one stroke candidate. Reads residual/penalty as a snapshot;
    safe to call in parallel across threads with shared read-only inputs.
    Returns (stroke, points) — points transient, not stored per accept. """
@inline function propose(
    inp::Image,
    residual::Matrix{Float64},
    r_max::Float64,
    palette::Vector{Lab{Float64}},
    edge_map::Matrix{Float64},
    edge_angle::Matrix{Float64},
    h::Int,
    w::Int,
)::Tuple{Stroke,Vector{StrokePoint}}
    point = importance_center(residual, r_max)
    @inbounds edge = edge_map[point[1], point[2]]
    @inbounds grad = edge_angle[point[1], point[2]]
    r_maj, r_min, theta_bin = get_stroke_geom(h, w, edge, grad)
    points = gen_stroke_points((h, w), point, r_maj, r_min, theta_bin)
    if isempty(points)
        # center clipped off canvas; caller drops via isempty guard, color unread
        return (
            (center=point, r_major=r_maj, r_minor=r_min, theta_bin=theta_bin, color=palette[1]),
            points,
        )
    end
    pixels = [inp[p.idx] for p in points]
    avg = mean_color(pixels)
    idx = softmax_pick(palette, avg, PALETTE_TEMP)
    base = palette[idx]
    color = Lab{Float64}(
        base.l + randn() * JITTER_L,
        base.a + randn() * JITTER_AB,
        base.b + randn() * JITTER_AB,
    )
    (
        (center=point, r_major=r_maj, r_minor=r_min, theta_bin=theta_bin, color=color),
        points,
    )
end

function render_png(
    strokes::Vector{Stroke},
    h::Int,
    w::Int;
    bg::Lab{Float64}=WHITE_LAB,
)::Image
    out = fill(bg, h, w)
    for s in strokes, p in gen_stroke_points((h, w), s.center, s.r_major, s.r_minor, s.theta_bin)
        out[p.idx] = s.color
    end
    out
end

""" Sample stroke geometry. r_major from normal dist scaled to image size
    (no edge shrink — preserve material). r_minor = r_major * aspect;
    aspect shrinks toward ELLIPSE_MIN_ASPECT on strong edges. theta follows
    the local isophote (gradient + π/2) when edge is well-defined, else
    random. theta_bin=0 on circular strokes to keep the stencil cache small. """
@inline function get_stroke_geom(
    height::Int,
    width::Int,
    edge::Float64,
    grad::Float64,
)::Tuple{Int,Int,Int}
    mean_r = min(height, width) * REL_RADIUS
    std = mean_r * REL_STD_RADIUS
    r = max(MIN_RADIUS, floor(Int, abs(randn() * std + mean_r)))
    # area-preserving ellipse: r_maj = r/√aspect, r_min = r·√aspect.
    # r_min allowed to reach 1px — MIN_RADIUS only floors the base radius,
    # not the minor axis (else aspect gets swallowed at small radii).
    aspect = 1.0 - (1.0 - ELLIPSE_MIN_ASPECT) * edge
    sa = sqrt(aspect)
    r_maj = max(MIN_RADIUS, ceil(Int, r / sa))
    r_min = max(1, floor(Int, r * sa))
    if r_maj == r_min
        return (r_maj, r_min, 0)
    end
    theta = edge > FLAT_EDGE_THRESH ? grad + π / 2 : 2π * rand()
    theta_bin = mod(round(Int, theta * THETA_BINS / (2π)), THETA_BINS)
    (r_maj, r_min, theta_bin)
end

""" Sample palette index proportional to softmax(-dist/T). T→0 → argmin;
    larger T → more uniform (Seurat-style optical mixing). Subtract d_min
    before exp for numerical stability. """
@inline function softmax_pick(
    palette::Vector{Lab{Float64}},
    avg::Lab{Float64},
    temp::Float64,
)::Int
    n = length(palette)
    dists = Vector{Float64}(undef, n)
    @inbounds for i = 1:n
        dists[i] = color_distance(palette[i], avg)
    end
    d_min = minimum(dists)
    total = 0.0
    @inbounds for i = 1:n
        dists[i] = exp(-(dists[i] - d_min) / temp)
        total += dists[i]
    end
    r = rand() * total
    acc = 0.0
    @inbounds for i = 1:n
        acc += dists[i]
        r <= acc && return i
    end
    n
end

""" Sample a center via rejection, biased toward high-residual pixels. """
@inline function importance_center(
    residual::Matrix{Float64},
    r_max::Float64,
)::Tuple{Int,Int}
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

""" Generate points that form a filled (rotated) ellipse, clipped to image
    bounds. Uses cached offset+dome stencil per (r_major, r_minor, theta_bin). """
@inline function gen_stroke_points(
    dims::Tuple{Int,Int},
    center::Tuple{Int,Int},
    r_major::Int,
    r_minor::Int,
    theta_bin::Int,
)::Vector{StrokePoint}
    cy, cx = center
    h, w = dims
    StrokePoint[
        (idx=CartesianIndex(cy + dy, cx + dx), dome=v) for
        (dy, dx, v) in stencil(r_major, r_minor, theta_bin) if
        1 <= cy + dy <= h && 1 <= cx + dx <= w
    ]
end

""" Render list of strokes into SVG content. Stream to IOBuffer to avoid
    materializing N per-stroke Strings before concatenation. """
function render_svg(
    strokes::Vector{Stroke},
    height::Int,
    width::Int;
    bg::Lab{Float64}=WHITE_LAB,
)::String
    io = IOBuffer()
    println(io, svg_open(width, height))
    println(io, """<rect x="0" y="0" width="$width" height="$height" fill="$(svg_color(bg))" />""")
    for s in strokes
        println(io, draw_stroke(s))
    end
    print(io, SVG_CLOSE)
    String(take!(io))
end

svg_color(c::Lab) = rgb_hex(convert(RGB{N0f8}, c))

""" Replay committed strokes onto a running canvas, snapshotting every
    GIF_INTERVAL strokes. Frames in display-space RGB{N0f8}. """
function render_gif(
    strokes::Vector{Stroke},
    h::Int,
    w::Int;
    bg::Lab{Float64}=WHITE_LAB,
)::GifFrames
    out = fill(bg, h, w)
    frames = GifFrames()
    for (n, s) in enumerate(strokes)
        @inbounds for p in gen_stroke_points((h, w), s.center, s.r_major, s.r_minor, s.theta_bin)
            out[p.idx] = s.color
        end
        if n % GIF_INTERVAL == 0 || n == length(strokes)
            push!(frames, convert.(RGB{N0f8}, out))
        end
    end
    @info "GIF: $(length(frames)) frames at $GIF_FPS fps ($(round(length(frames)/GIF_FPS, digits=1))s clip)"
    frames
end

function save_gif(path::String, frames::GifFrames)
    isempty(frames) && return
    save(path, stack(frames; dims=3), fps=GIF_FPS)
end

""" Draw an ellipse stroke in SVG format. """
function draw_stroke(s::Stroke)::String
    fill = svg_color(s.color)
    cx = s.center[2]
    cy = s.center[1]
    deg = round(360 * s.theta_bin / THETA_BINS, digits=1)
    """<ellipse cx="$cx" cy="$cy" rx="$(s.r_major)" ry="$(s.r_minor)" fill="$fill" transform="rotate($deg $cx $cy)" />"""
end

end
