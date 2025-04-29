module MonteCarloArtMain

include("montecarloart.jl")

using .MonteCarloArt

using ArgParse
using Images
using Logging

const DefaultArgs = Dict{String,Any}((
    "steps" => 100000,
    "color" => false,
    "colors" => "#FF0000,#00FF00,#0000FF",
))


function main()
    # parse command line arguments
    args = parse_cmd()

    # verbose mode should use debug log level log level
    if args["verbose"]
        ENV["JULIA_DEBUG"] = Main
    end

    # use command line options to define algorithm parameters
    args = merge(DefaultArgs, args)
    input, output = args["input"], args["output"]

    @info "Loading input image: '$input'"
    if !args["color"]
        inp = MonteCarloArt.load_image(input)
    else
        inp = MonteCarloArt.load_color_image(input)
    end

    @info "Running MC algorithm"
    out = MonteCarloArt.run(inp, args)

    @info "Saving final output image to: '$output'"
    out = complement.(convert.(RGB{N0f8}, out))
    save(output * ".png", out)

    @info "Done"
end

function parse_cmd()
    # Create an argument parser
    parser = ArgParseSettings()
    # Add arguments to the parser
    @add_arg_table parser begin
        "--input", "-i"
        help = "input image path"
        arg_type = String
        required = true
        "--output", "-o"
        help = "output image path whiteout extension"
        arg_type = String
        default = "output"
        "--steps"
        help = "Number iterations (proporcitonal to the number of circles)"
        arg_type = Int
        default = 200000
        "--color"
        help = "Color mode"
        action = :store_true
        "--verbose"
        help = "Verbose mode"
        action = :store_true
    end
    parse_args(parser)
end

end

MonteCarloArtMain.main()
