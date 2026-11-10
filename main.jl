module MonteCarloArtMain

include("src/MonteCarloArt.jl")

using .MonteCarloArt
using ArgParse
using FileIO
using Images
using Random

""" Main function: parse arguments, load image, run algorithm, and save output.
    Debug output: --verbose or JULIA_DEBUG=MonteCarloArt,MonteCarloArtMain. """
function main()
    args = parse_cmd()
    Random.seed!(args["seed"])  # reproducible for a fixed -t N; batch size = nthreads()
    MonteCarloArt.setup_logging(args)
    validate_args(args)

    outputs = MonteCarloArt.resolve_output(args["output"])

    cfg = MonteCarloArt.Config(
        steps=args["steps"],
        color_palette=args["color-palette"],
        overlap_tolerance=args["overlap-tolerance"],
        stop_miss_rate=args["stop-miss-rate"],
    )

    input_path = args["input"]
    @info "Loading input image: '$input_path'"
    load = args["color"] ? load_color_image : load_image
    inp = load(input_path, args["size"])
    @info "Canvas: $(size(inp, 2))×$(size(inp, 1))"

    bg = MonteCarloArt.resolve_background(args["background"], inp)
    @info "Background: $(args["background"]) → Lab($(round(bg.l, digits=1)), $(round(bg.a, digits=1)), $(round(bg.b, digits=1)))"

    @info "Running Monte Carlo algorithm"
    circles, h, w = MonteCarloArt.render(inp, cfg; bg=bg)

    for (out_path, fmt) in outputs
        @info "Saving output to '$out_path' ($fmt)"
        if fmt == :svg
            MonteCarloArt.write_svg(
                out_path,
                MonteCarloArt.render_svg(circles, h, w; bg=bg),
            )
        elseif fmt == :gif
            MonteCarloArt.save_gif(out_path, MonteCarloArt.render_gif(circles, h, w; bg=bg))
        elseif fmt == :png
            save(
                out_path,
                convert.(RGB{N0f8}, MonteCarloArt.render_png(circles, h, w; bg=bg)),
            )
        else
            error("Unsupported format for MonteCarloArt: $fmt")
        end
    end

    @info "Processing completed"
end

""" Assert CLI args are in sane ranges. Trust boundary — fail loud, not silent NaN. """
function validate_args(args::AbstractDict)
    args["steps"] > 0 || error("--steps must be > 0 (got $(args["steps"]))")
    args["size"] > 0 || error("--size must be > 0 (got $(args["size"]))")
    args["color-palette"] > 0 ||
        error("--color-palette must be > 0 (got $(args["color-palette"]))")
    0.0 <= args["overlap-tolerance"] <= 1.0 ||
        error("--overlap-tolerance must be in [0, 1] (got $(args["overlap-tolerance"]))")
    0.0 < args["stop-miss-rate"] <= 1.0 ||
        error("--stop-miss-rate must be in (0, 1] (got $(args["stop-miss-rate"]))")
end

""" Parse command-line arguments using ArgParse. """
function parse_cmd()
    parser = ArgParseSettings()
    MonteCarloArt.add_common_args!(
        parser;
        steps_default=200000,
        output_default="output.png",
    )
    @add_arg_table! parser begin
        "--color"
        help = "Enable color mode (use input colors instead of grayscale)"
        action = :store_true
        "--color-palette"
        help = "Number of colors in the palette"
        arg_type = Int
        default = 64
        "--overlap-tolerance"
        help = "Mean soft-penalty threshold under a candidate circle. Higher = denser packing."
        arg_type = Float64
        default = 0.15
        "--stop-miss-rate"
        help = "Early stop when EMA of miss rate exceeds this. 1.0 = disabled (never stop early)."
        arg_type = Float64
        default = 0.99
        "--background"
        help = "Canvas background: white | black | mean (image mean color) | #rrggbb"
        arg_type = String
        default = "white"
        "--size", "-s"
        help = "Max canvas side in pixels; larger inputs are downscaled (aspect kept), smaller kept as is"
        arg_type = Int
        default = 1024
        "--seed"
        help = "RNG seed (reproducible for a fixed -t N)"
        arg_type = Int
        default = 42
    end
    parse_args(parser)
end

end

MonteCarloArtMain.main()
