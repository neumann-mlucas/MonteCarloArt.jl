module MonteCarloArtMain

include("montecarloart.jl")

using .MonteCarloArt
using ArgParse
using Images
using Logging

""" Main function: parse arguments, load image, run algorithm, and save output. """
function main()
    args = parse_cmd()

    # Set debug logging level if verbose mode is enabled
    if args["verbose"]
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    end

    input_path, output_path = args["input"], args["output"]

    @info "Loading input image: '$input_path'"
    inp = args["color"] ? load_color_image(input_path) : load_image(input_path)

    @info "Running Monte Carlo algorithm"
    out = MonteCarloArt.run(inp, args)

    @info "Saving output image to: '$(output_path).png'"
    if args["svg"]
        open(output_path * ".svg", "w") do f
            write(f, out)
        end
    else
        out = complement.(convert.(RGB{N0f8}, out))
        save(output_path * ".png", out)
    end

    @info "Processing completed"
end

""" Parse command-line arguments using ArgParse. """
function parse_cmd()
    parser = ArgParseSettings()
    @add_arg_table parser begin
        "--input", "-i"
        help = "Input image path (required)"
        arg_type = String
        required = true

        "--output", "-o"
        help = "Output image path (without extension)"
        arg_type = String
        default = "output"

        "--steps", "-s"
        help = "Number of iterations (proportional to number of circles)"
        arg_type = Int
        default = 200000

        "--svg"
        help = "Save output as SVG instead of PNG"
        action = :store_true

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

        "--radius-start"
        help = "Multiplier on base radius at step 1 (broad strokes early). 1.0 = current fixed size."
        arg_type = Float64
        default = 1.0

        "--radius-end"
        help = "Multiplier on base radius at final step (fine detail late). 1.0 = current fixed size."
        arg_type = Float64
        default = 1.0

        "--batch-size"
        help = "Candidates proposed per batch (parallelized across threads). 1 = single-threaded reference path."
        arg_type = Int
        default = 1

        "--stop-miss-rate"
        help = "Early stop when EMA of miss rate exceeds this. 1.0 = disabled (never stop early)."
        arg_type = Float64
        default = 1.0

        "--min-steps"
        help = "Never stop early before this many steps (guards EMA warmup)."
        arg_type = Int
        default = 10000

        "--verbose"
        help = "Enable verbose logging (debug level)"
        action = :store_true
    end

    parse_args(parser)
end

end

MonteCarloArtMain.main()
