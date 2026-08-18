# MonteCarloArt.jl

<p align="center">
  <img src="examples/marcus_aurelius.svg" alt="Marcus Aurelius Bust" width="600px" />
</p>

MonteCarloArt.jl is a Julia script that recreates images in a pointillist style using a greedy Monte Carlo sampling algorithm. The process begins by extracting a reduced color palette of N colors from the original image. The script then attempts to place small colored dots (sparse-overlap, not disjoint) onto a blank canvas.

At each step a batch of dots is proposed in parallel — each at a random position biased toward high-error regions via importance sampling on the residual map. A dot is committed sequentially iff the average overlap under it is below a fixed threshold:

$$
\text{overlap} = \frac{1}{N} \sum_{p \in \text{points}} \text{penalty}(p)
$$

$$
\text{Draw circle if} \quad \text{overlap} < \text{overlap-tolerance}
$$

The color of each dot is selected as the closest match from the palette to the original image’s color at the proposed position. Over time, this method produces an image with subtle color blending and visual texture, characteristic of pointillist art.

You can control several parameters to influence the output:

1. **`--steps`:** upper bound on algorithm steps (more steps = more dots)
2. **`--color-palette`:** number of colors in the palette
3. **`--overlap-tolerance`:** base overlap tolerance (how closely dots can be placed)
4. **`--stop-miss-rate`:** EMA miss-rate threshold for early termination when the canvas saturates (default 0.99; 1.0 = disabled)
5. **`--alpha`:** blend factor for stacked circles (1.0 = overwrite, 0.7 ≈ Seurat-style optical mixing). PNG blends per-channel in Lab; SVG emits `fill-opacity`.

Circle radii are sampled from a normal distribution scaled to image size (no user knob).

Parallelism is auto-derived from Julia's thread count (`julia -t N`). Progress logs fire every 5% of `--steps`. Debug logging: `JULIA_DEBUG=MonteCarloArt`.

The script supports gray scale mode and can optionally export the output as an SVG (**if your computer can handle a huge SVG**). Higher-resolution input images generally produce better results.


## Requirements

The following Julia packages are required:

- `ArgParse`
- `Clustering`
- `Colors`
- `Images`


## Usage

Run the script via the command line:

Output format is inferred from the `-o` file extension (`.png` or `.svg`).

```bash
$ julia main.jl --help
usage: main.jl -i INPUT [-o OUTPUT] [--steps STEPS] [-v] [--color]
               [--color-palette COLOR-PALETTE] [-t OVERLAP-TOLERANCE]
               [--stop-miss-rate STOP-MISS-RATE] [--alpha ALPHA] [-h]

optional arguments:
  -i, --input INPUT     Input image path (required)
  -o, --output OUTPUT   Output path with extension (.png/.svg/.gif);
                        default "output.svg"
  --steps STEPS         Number of iterations (proportional to number
                        of circles) (type: Int64, default: 200000)
  -v, --verbose         verbose (debug) logging
  --color               Enable color mode (use input colors instead of
                        grayscale)
  --color-palette COLOR-PALETTE
                        Number of colors in the palette
                        (type: Int64, default: 64)
  -t, --overlap-tolerance OVERLAP-TOLERANCE
                        Parameters that penalizes overlapping circles
                        (type: Float64, default: 0.08)
  --stop-miss-rate STOP-MISS-RATE
                        Early stop when EMA of miss rate exceeds this.
                        1.0 = disabled (never stop early).
                        (type: Float64, default: 0.99)
  --alpha ALPHA         Blend factor for stacked circles (1.0 =
                        overwrite, 0.7 = Seurat-style optical mixing).
                        (type: Float64, default: 1.0)
  -h, --help            show this help message and exit

```

Threading is auto-derived from Julia's thread count — run with `-t N`
to parallelize candidate proposals. Debug logging: `JULIA_DEBUG=MonteCarloArt`.


- **Gray Scale Mode:**
```bash
julia -O3 main.jl -i input.jpg -o output.png
```


- **Color Mode with Custom Color Palette:**
```bash
julia -O3 main.jl --color --color-palette 64 -i input.jpg -o output.png
```


- **More Iterative Steps:**
```bash
julia -O3 main.jl --steps 400000 -i input.jpg -o output.png
```


- **Early Stop on Saturated Canvas (~30% wall-time savings):**
```bash
julia -O3 -t 8 main.jl --color --steps 400000 \
    --stop-miss-rate 0.95 -i input.jpg -o output.png
```


- **SVG Output (extension picks the format):**
```bash
julia -O3 -t 8 main.jl --steps 400000 -i input.jpg -o output.svg
```


- **Animated GIF (replay of committed circles, snapshot every 100):**
```bash
julia -O3 -t 8 main.jl --color --steps 100000 -i input.jpg -o output.gif
```
Frames = `n_circles / 100`, playback = 15 fps. File size scales with input resolution × frame count — downsize input for smaller GIFs.


- **Seurat-style Optical Mixing (alpha blend):**
```bash
julia -O3 -t 8 main.jl --color --steps 400000 \
    --alpha 0.7 -i input.jpg -o output.png
```


- **Recommended Settings for Higher-resolution:**
```bash
julia -O3 -t 8 main.jl --color --steps 400000 \
    --stop-miss-rate 0.95 \
    -i input.jpg -o output.svg
```


### Gallery

- **City of Sao Paulo**

<p align="center">
  <img src="examples/sao_paulo_01.svg" alt="SP 01" />
</p>


<p align="center">
  <img src="examples/sao_paulo_02.svg" alt="SP 02" />
</p>


### TODO

See `TASKS.md`. Shipped: importance sampling, threaded batch
propose+commit, EMA coverage stop, alpha blend (Seurat mixing),
5%-granularity progress logs. Backlog currently empty — palette
locality, accumulating penalty, and color-aware acceptance were
killed as speculative or redundant. New tasks wait on concrete failure
reports.


---

## License

MIT License
