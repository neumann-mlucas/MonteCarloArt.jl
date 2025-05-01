# MonteCarloArt.jl

> WIP

MonteCarloArt.jl is a Julia script that recreates images in a pointillist style using a Monte Carlo-inspired algorithm. The process begins by extracting a reduced color palette of N colors from the original image. The script then attempts to place small, non-overlapping colored dots onto a blank canvas.

Each dot is proposed at a random position and is only added to the canvas if the average overlap energy is below a fixed threshold (`overlap_tolerance_energy`), or if it passes a Monte Carlo acceptance check. The acceptance logic follows:

$$
\text{energy} = \frac{1}{N} \sum_{p \in \text{points}} \text{penalty}(p)
$$

$$
\Delta E = \text{energy} - \text{overlap\_tolerance\_energy}
$$

$$
\text{Draw circle if} \quad
\begin{cases}
\Delta E < 0 & \text{(accept unconditionally)} \\
\exp\left(-\frac{\Delta E}{T}\right) > \text{rand()} & \text{(accept with probability)} \\
\text{otherwise reject}
\end{cases}
$$

The color of each dot is selected as the closest match from the palette to the original image’s color at the proposed position. Over time, this method produces an image with subtle color blending and visual texture, characteristic of pointillist art.

You can control several parameters to influence the output:

1. **"--steps":** The number of algorithm steps (more steps = more dots in the canvas)

2. **"--color-pallet":** number of colors in the palette

3. **"--overlap-tolerance":**The base overlap tolerance (controls how closely dots can be placed)


The script supports gray scale mode and can optionally export the output as an SVG (if your computer can handle a huge SVG). Higher-resolution input images generally produce better results.


---

## Requirements

The following Julia packages are required:

- `ArgParse`
- `Clustering`
- `Colors`
- `Images`
- `Logging`


---

## Usage

Run the script via the command line:

```bash
$ julia main.jl --help
usage: main.jl -i INPUT [-o OUTPUT] [-s STEPS] [--svg] [--color]
               [--color-pallet COLOR-PALLET] [-t OVERLAP-TOLLERANCE]
               [--verbose] [-h]

optional arguments:
  -i, --input INPUT     Input image path (required)
  -o, --output OUTPUT   Output image path (without extension)
                        (default: "output")
  -s, --steps STEPS     Number of iterations (proportional to number
                        of circles) (type: Int64, default: 200000)
  --svg                 Save output as SVG instead of PNG
  --color               Enable color mode (use input colors instead of
                        grayscale)
  --color-pallet COLOR-PALLET
                        Number of colors in the palette (default: 64)
                        (type: Int64, default: 32)
  -t, --overlap-tollerance OVERLAP-TOLLERANCE
                        Parameters that penalizes overlapping circles
                        (type: Float64, default: 0.08)
  --verbose             Enable verbose logging (debug level)
  -h, --help            show this help message and exit

```


- **Gray Scale Mode:**
```bash
julia -O3 main.jl -i input.jpg -o output.png
```


- **More Iterative Steps:**
```bash
julia -O3 main.jl --steps 400000 -i input.jpg -o output.png
```


- **SVG Output:**
```bash
julia -O3 -t 8 main.jl --steps 400000 --svg -i input.jpg -o output.png
```


- **Recommended Settings for better Higher-resolution:**
```bash
julia -O3 main.jl --color --steps 400000 --svg -i input.jpg -o output.png
```


---

### Gallery

> WIP


---

### TODO

- [ ] Add Threading
- [ ] Add more CLI parameters
- [ ] Use the color distance / color intensity as a variable in the MC criteria


---

## License

MIT License
