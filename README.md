## MonteCarlo.jl

> WIP

This project explores the generation of images in a dotstyle or pointillism aesthetic using a simple Monte Carlo-inspired heuristic. Points are randomly placed across the canvas, with each new point accepted or rejected based on an energy criterion derived from the Monte Carlo Metropolis method. The local color intensity at each point defines the energy value guiding placement. The goal is to simulate the organic, textured feel of pointillist artwork through stochastic processes that balance randomness with visual structure.


### Algorithm

> TODO


### Requirements

The Libraries:

- ArgParse
- Colors
- Images
- Logging


### Usage

```bash
# basic
$ julia -O3 -t 8 main.jl -i [input image] -o [output image]

# suggested for black and white
$ julia -O3 -t 8 main.jl --steps 400000 -i [input image] -o [output image]

# suggested for color mode
# always better to use custom colors / palette and use a bigger number of steps
$ julia -O3 -t 8 main.jl --steps 1000000 --color --colors "#FFFF33,#33FFFF" -i [input image] -o [output image]
```


### Parameters

> TODO


### Gallery

> TODO


#### RGB Mode

> TODO


---

### TODO

- [ ] Fix color mode
- [ ] Optimize
