module MonteCarloArtMain

include("montecarloart.jl")

using .MonteCarloArt
using ArgParse
using Images
using Logging

""" Default configuration parameters. """
const DefaultArgs = Dict{String,Any}((
    "steps" => 100000,
    "color" => false,
    "colors" => "#FF0000,#00FF00,#0000FF",
))

""" Main function: parse arguments, load image, run algorithm, and save output. """
function main()
    args = parse_cmd()

    # Set debug logging level if verbose mode is enabled
    if args["verbose"]
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    end

    # Merge default parameters with command line arguments
    args = merge(DefaultArgs, args)
    input_path, output_path = args["input"], args["output"]

    @info "Loading input image: '$input_path'"
    inp = args["color"] ? load_color_image(input_path) : load_image(input_path)

    @info "Running Monte Carlo algorithm"
    out = run(inp, args)

    @info "Saving output image to: '$(output_path).png'"
    out = complement.(convert.(RGB{N0f8}, out))
    save(output_path * ".png", out)

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

        "--steps"
        help = "Number of iterations (proportional to number of circles)"
        arg_type = Int
        default = 200000

        "--color"
        help = "Enable color mode (use input colors instead of grayscale)"
        action = :store_true

        "--verbose"
        help = "Enable verbose logging (debug level)"
        action = :store_true
    end

    parse_args(parser)
end

end

MonteCarloArtMain.main()
