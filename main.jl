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

    # default colors
    colors = parse_colors(args["colors"])

    # use command line options to define algorithm parameters
    args = merge(DefaultArgs, args)
    input, output = args["input"], args["output"]

    if !args["color"]
        @info "Loading input as grey image: '$input'"
        inp = MonteCarloArt.load_image(input)

        @info "Running gray scale algorithm..."
        out = MonteCarloArt.run(inp, args)

        @info "Saving final output image to: '$output'"
        out = Gray.(complement.(out))
        save(output * ".png", out)
    else
        @info "Loading input as color image: '$input'"
        inp = MonteCarloArt.load_color_image(input)

        @info "Running RGB algorithm with colors $(hex.(colors))"
        out = MonteCarloArt.run(inp, args)

        @info "Saving final output image to: '$output'"
        save(output * ".png", complement.(out))
    end
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
        help = "number of algorithm iterations"
        arg_type = Int
        default = 600000
        "--colors"
        help = "HEX code of colors to use in RGB mode"
        default = "#FF0000,#00FF00,#0000FF"
        "--color"
        help = "RGB mode"
        action = :store_true
        "--gif"
        help = "Save output as a GIF"
        action = :store_true
        "--verbose"
        help = "verbose mode"
        action = :store_true
    end
    parse_args(parser)
end

function parse_colors(colors::String)::MonteCarloArt.Colors
    to_color(c) = parse(RGB{N0f8}, c)
    # default value for colors
    rgb_colors = [RGB(1, 0, 0), RGB(0, 1, 0), RGB(0, 0, 1)]
    try
        rgb_colors = map(to_color, split(colors, ","))
    catch e
        @error "Unable to parse '$colors' $e"
    end
    return rgb_colors
end

end

MonteCarloArtMain.main()
