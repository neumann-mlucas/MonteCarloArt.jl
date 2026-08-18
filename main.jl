module MonteCarloArtMain

include("src/MonteCarloArt.jl")

using .MonteCarloArt
using ArgParse
using FileIO
using Images

""" Main function: parse arguments, load image, run algorithm, and save output.
    Debug output: --verbose or JULIA_DEBUG=MonteCarloArt,MonteCarloArtMain. """
function main()
    args = parse_cmd()
    MonteCarloArt.setup_logging(args)
    validate_args(args)

    outputs = MonteCarloArt.resolve_output(args["output"])
    length(outputs) == 1 || error("MonteCarloArt supports one output at a time (got $(length(outputs)))")
    out_path, fmt = outputs[1]

    cfg = MonteCarloArt.Config(
        steps = args["steps"],
        color_palette = args["color-palette"],
        overlap_tolerance = args["overlap-tolerance"],
        stop_miss_rate = args["stop-miss-rate"],
        alpha = args["alpha"],
        format = fmt,
    )

    input_path = args["input"]
    @info "Loading input image: '$input_path'"
    inp = args["color"] ? load_color_image(input_path) : load_image(input_path)

    @info "Running Monte Carlo algorithm"
    out = MonteCarloArt.render(inp, cfg)

    @info "Saving output to '$out_path' ($fmt)"
    if fmt == :svg
        MonteCarloArt.write_svg(out_path, out)
    elseif fmt == :gif
        MonteCarloArt.save_gif(out_path, out)
    elseif fmt == :png
        save(out_path, complement.(convert.(RGB{N0f8}, out)))
    else
        error("Unsupported format for MonteCarloArt: $fmt")
    end

    @info "Processing completed"
end

""" Assert CLI args are in sane ranges. Trust boundary — fail loud, not silent NaN. """
function validate_args(args::AbstractDict)
    args["steps"] > 0                          || error("--steps must be > 0 (got $(args["steps"]))")
    args["color-palette"] > 0                  || error("--color-palette must be > 0 (got $(args["color-palette"]))")
    0.0 < args["alpha"] <= 1.0                 || error("--alpha must be in (0, 1] (got $(args["alpha"]))")
    0.0 <= args["overlap-tolerance"] <= 1.0    || error("--overlap-tolerance must be in [0, 1] (got $(args["overlap-tolerance"]))")
    0.0 < args["stop-miss-rate"] <= 1.0        || error("--stop-miss-rate must be in (0, 1] (got $(args["stop-miss-rate"]))")
end

""" Parse command-line arguments using ArgParse. """
function parse_cmd()
    parser = ArgParseSettings()
    MonteCarloArt.add_common_args!(parser; steps_default=200000)
    @add_arg_table! parser begin
        "--color"
            help = "Enable color mode (use input colors instead of grayscale)"
            action = :store_true
        "--color-palette"
            help = "Number of colors in the palette"
            arg_type = Int
            default = 64
        "--overlap-tolerance", "-t"
            help = "Parameters that penalizes overlapping circles"
            arg_type = Float64
            default = 0.08
        "--stop-miss-rate"
            help = "Early stop when EMA of miss rate exceeds this. 1.0 = disabled (never stop early)."
            arg_type = Float64
            default = 0.99
        "--alpha"
            help = "Blend factor for stacked circles (1.0 = overwrite, 0.7 = Seurat-style optical mixing). PNG blends per-channel in Lab; SVG uses fill-opacity."
            arg_type = Float64
            default = 1.0
    end
    parse_args(parser)
end

end

MonteCarloArtMain.main()
