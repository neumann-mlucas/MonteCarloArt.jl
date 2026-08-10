# MonteCarloArt.jl — Improvement Tasks

Followups to today's refactor. Each task lists motivation, alternatives with
trade-offs, a recommendation, API surface, complexity delta, and the minimum
test to leave behind.

Priority ordered — earlier tasks compound off later ones.

Already shipped (for reference):
- Importance-sampled centers (residual-weighted rejection) — 2026-08-09
- Radius floor bug fix
- Split `render_png` / `render_svg`
- Cached circle points on the NamedTuple
- SVG stroke gamut fix
- Aligned `--color-palette` default
- Linear radius schedule (Task 2) — commit 44ba1e6, 2026-08-09
- Batched propose + sequential commit (Task 5) — commit 0930230, 2026-08-09
- EMA miss-rate early stop (Task 4) — commit 0930230, 2026-08-09
- Flag cleanup: dropped `--min-steps`, `--batch-size`, `--verbose` — commit baeec05, 2026-08-10

---

## Task 1 — Color-aware acceptance

**Status**: killed 2026-08-09 after full-corpus sweep + palette-16 A/B on
girl_pearl/mona_lisa. Residual-delta gate (variant 1d) rejected ~2% more
proposals; visual delta imperceptible. Cause: importance sampler already
biases proposals to high-residual regions where the best palette pick
almost always improves the canvas, so the color gate is nearly redundant
with sampling. Evidence kept in `test/results/task1/` and
`test/results/palette16/`; script kept in `test/scripts/task1.sh`.
**Priority**: highest impact on visual fidelity.
**Complexity**: small (single loop condition + one CLI flag + one weighting
constant).

### Motivation

Current acceptance only considers overlap. A circle can be accepted even
when placing its palette-quantized color at that location makes the image
*worse* than what's already there. The dot is drawn only because there's
empty canvas — not because it improves fidelity. Especially visible where
the palette color misses the local target (skin tones, gradients).

### Current formula

```
excess = overlap - base_tolerance
accept if excess < 0 or exp(-excess / slack) > rand()
```

### Alternatives

**1a. Additive term, fixed weight.**

$$
\Delta = w_o \cdot (\text{overlap} - t_o) \; + \; w_c \cdot (\|c_{\text{palette}} - c_{\text{target}}\|_{\text{Lab}} - t_c)
$$

Accept if `Δ < 0` or `exp(-Δ / slack) > rand()`. Both overlap and color
terms compete in a single scalar. Requires **two thresholds** (`t_o`, `t_c`)
and **two weights** (`w_o`, `w_c`), one of which can be normalized to 1.

Pro: single Metropolis test, minimal code change.
Con: weight tuning is a search problem — bad weight favors one axis.

**1b. Multiplicative gate.**

Accept overlap gate first (unchanged). Then separately gate on color:
$$
P_{\text{color}} = \exp(-\|c_{\text{palette}} - c_{\text{target}}\|_{\text{Lab}} / \sigma_c)
$$
Accept the circle iff both gates fire. Effectively: overlap-OK circles
still rejected if their color is a bad match.

Pro: independent tuning of each axis, easier to reason about.
Con: two random draws per candidate, higher reject rate.

**1c. Palette-lock at sampling time (not acceptance).**

Skip the acceptance-level fix. Instead, at circle proposal time, snap
`color = nearest_palette(target_at_center)` — already done. The failure
mode isn't wrong color, it's that the palette *itself* has no close match
for that region. Widen the palette (larger `--color-palette`) or use
per-region k-means.

Pro: no acceptance logic change. Zero-risk.
Con: papers over the problem; larger palette = more memory + slower.

**1d. Reject when local error worsens.**

Compute `err_before = ||target[i] - current[i]||²` and
`err_after = ||target[i] - c_palette||²` averaged over the circle's
pixels. Reject if `err_after > err_before + slack_c`. Uses the residual
map already maintained for importance sampling.

Pro: measures *exactly* what we care about — did the circle improve
fidelity? Trivial to compute (residual is already available).
Con: introduces a second slack parameter to tune.

### Recommendation

**1d** (residual-delta gate). Reuses `residual` state, mirrors PrimitiveArt
delta-error pattern, needs only one new threshold. Precise semantics.

### API

```
--color-tolerance C     default 0.0    # extra Lab distance allowed to increase
                                        # 0.0 = strict, only accept if fidelity improves
                                        # negative = require strict improvement + buffer
```

### Complexity

Per accepted step: no change (already touched all circle pixels).
Per proposed step: one extra pass to compute `err_after` — same cost as
overlap `mean(penalty[p] for p in points)`. ~2× per-step cost.

### Test

Regression check: same image processed with `--color-tolerance 0` should
produce output with lower total per-pixel `||target - render||` than
without. Automate:

```
julia -e 'include("montecarloart.jl"); using .MonteCarloArt, Images;
  # run with and without, assert error_reduction > 5%'
```

---

## Task 2 — Radius schedule

**Status**: shipped 2026-08-09 (commit 44ba1e6). `get_radius` interpolates
`r0*REL_RADIUS -> r1*REL_RADIUS` across steps; flags `--radius-start` /
`--radius-end`, defaults 1.0/1.0 preserve prior behavior. **Priority**:
highest impact on aesthetic (broad strokes early, fine detail late —
canonical pointillist behavior). **Complexity**: small (one function + two
constants).

### Motivation

Fixed `REL_RADIUS = 0.0032` means every circle is roughly the same size.
Real pointillism uses large strokes for base tone and small dots for
detail. Late-run misses (currently 85–94%) largely come from big circles
trying to fit into small gaps.

### Alternatives

**2a. Linear decay.**

$$
r_{\text{mean}}(s) = r_0 \cdot (1 - s/S) + r_1 \cdot (s/S)
$$

with `r_0` = big (e.g. 3× REL_RADIUS), `r_1` = small (e.g. 0.3× REL_RADIUS).

Pro: simple, predictable, one line of code.
Con: transition is uniform; may waste steps in the medium-radius region.

**2b. Piecewise / staged.**

Three fixed phases:
- steps 0–33%: `r = 3 * REL_RADIUS`
- steps 33–66%: `r = REL_RADIUS`
- steps 66–100%: `r = 0.5 * REL_RADIUS`

Pro: distinct visible passes, clean debug logs per phase.
Con: hard transitions may create visible "banding" at phase boundaries.

**2c. Adaptive to residual.**

Sample radius from `r_i ∝ 1 / √(residual_at_center)` — big circles in
high-residual (untouched) regions, tiny in near-finished areas.

Pro: no manual schedule tuning.
Con: needs residual sampling *before* radius pick; couples two systems.
Risk: pathological with sharp edges — radius collapses to 1 immediately
around any detail.

**2d. Miss-rate driven.**

Shrink radius when miss rate over last N steps exceeds threshold.

Pro: self-tuning to canvas density.
Con: hysteresis / stability concerns; needs windowed miss tracking.

### Recommendation

**2a** (linear decay). Cheapest, matches how humans describe pointillism
("start broad, refine"). Falls back gracefully to current behavior with
`r_0 = r_1 = REL_RADIUS`.

### API

```
--radius-start MULT     default 1.0    # r_0 = MULT * REL_RADIUS
--radius-end   MULT     default 1.0    # r_1 = MULT * REL_RADIUS
                                        # both 1.0 = current fixed behavior
```

Suggest defaults `(3.0, 0.3)` once validated.

### Complexity

Constant. `get_radius(h, w, step, steps)` interpolates `mean_r` linearly.

### Test

Assert: `n_circles(r0=3, r1=0.3) > n_circles(r0=1, r1=1)` because small
late circles get accepted more often. Also visually eyeball a diff.

---

## Task 3 — Accumulating penalty

**Status**: not started. **Priority**: unlocks depth semantics.
**Complexity**: one-liner change plus threshold reinterpretation.

### Motivation

`penalty[i] = 1` throws away the count of overlaps. Two circles on top
of each other look the same as one. Loses depth information that could
tune tolerance meaningfully.

### Alternatives

**3a. Integer count.**

```
penalty[i] += 1   # was: penalty[i] = 1
```

`overlap = mean(penalty[p] for p in points)` now means "average stack
depth over the circle". Threshold `base_tolerance` becomes "max depth
allowed" instead of "coverage fraction".

Pro: trivial code change. Direct depth signal.
Con: changes semantics of `--overlap-tolerance` — old configs need
retuning (typical values now 0.5–2.0, not 0.05–0.20).

**3b. Time-decayed count.**

```
penalty[i] = penalty[i] * decay + 1    # decay ∈ [0.9, 0.99]
```

Old circles fade, recent circles dominate the penalty. Effectively a
"recency window" for overlap.

Pro: allows revisiting regions after canvas settles.
Con: introduces `decay` parameter; loses total-history information.

**3c. Distance-weighted count.**

Penalty falls with distance from nearest existing circle center. Uses a
distance transform, not point-membership.

Pro: continuous field, no dot-boundary artifacts.
Con: expensive — distance transform per accepted circle.

### Recommendation

**3a** (integer count). Small change, big semantic gain. Ship with a
version bump / note that `--overlap-tolerance` scale changed.

### API

No new flag. Recommend updating `--overlap-tolerance` default from `0.08`
to a small integer (`1.0` = allow single-layer overlap).

### Complexity

Zero cost delta.

### Test

Run `--overlap-tolerance 0.0` — no circle should overlap any other.
Assert `maximum(penalty) == 1` at end.

---

## Task 4 — Coverage-based stop

**Status**: shipped 2026-08-09 (commit 0930230, bundled with Task 5).
`--stop-miss-rate` gates an EMA of miss rate; hardcoded 500-step warmup.
Verified on flowers.png: 100k budget → ~35k executed (65% wall saved).
**Priority**: pure runtime win (~30% at 300k-step configs).
**Complexity**: small (windowed counter + early break).

### Motivation

Current logs at 300k steps show 89–94% miss rate — canvas saturated
after ~100–150k. Remaining ~150–200k steps produce trivial improvements
at full cost.

### Alternatives

**4a. Sliding window miss rate.**

Maintain a ring buffer of last N step outcomes. Break loop when
`window_misses / N > threshold`.

Pro: adaptive to per-image saturation.
Con: needs ring buffer or approximate exponential moving avg.

**4b. Exponential moving average of miss rate.**

```
ema_miss = 0.99 * ema_miss + 0.01 * (this_step_was_miss ? 1 : 0)
if step > min_steps && ema_miss > 0.95: break
```

Pro: zero allocation, single scalar.
Con: EMA smoothing lag ~100 steps; can slightly overshoot break point.

**4c. Fixed circles-drawn cap.**

Stop when `length(circles) >= max_circles`. `steps` becomes upper bound
instead of target.

Pro: predictable output size.
Con: user-facing knob shifts to circle count, less intuitive for time.

### Recommendation

**4b** (EMA). One line of state, no buffer. Also emits an interpretable
metric to the debug log.

### API

```
--stop-miss-rate RATE   default 1.0    # 1.0 = never stop early, 0.95 = typical
```

`--min-steps` was dropped 2026-08-10 in favor of a hardcoded 500-step
warmup (EMA α=0.99 converges in ~500 iters; the flag was only there to
prevent pathological early stops and never got tuned in practice).

### Complexity

Constant. One float, one branch per step.

### Test

Assert: with `--stop-miss-rate 0.9`, run terminates before nominal
`--steps` on a saturated image.

---

## Task 5 — Threading (deferred earlier)

**Status**: shipped 2026-08-09 (commit 0930230, bundled with Task 4).
Batch size auto-derived from `Threads.nthreads()`; `@threads` around
`_propose`, sequential commit filters stale candidates. Measured ~1.27×
at bs=8 on flowers.png (Amdahl-bound by sequential commit + GC pressure
on shared heap). **Priority**: 4–8× on multicore. **Complexity**: medium
(needs conflict resolution).

### Motivation

`--steps 300000` is single-threaded. Each proposal (center + radius +
palette lookup + overlap calc) is independent up to the shared `penalty`
+ `residual` grids.

### Alternatives

**5a. Batch propose, sequential commit.**

Generate `K = nthreads()` candidates in parallel (all use current
`penalty`/`residual` snapshot). Commit sequentially — for each accepted
candidate, re-verify overlap against updated penalty; drop if now over
tolerance.

Pro: preserves determinism-ish (given seed).
Con: late candidates in batch see stale state; effective throughput
< K × single-threaded.

**5b. Sharded grid.**

Split canvas into K disjoint tiles. Each thread runs the loop on its
tile with a local `penalty`/`residual`. Merge at end.

Pro: zero contention. Full linear scaling.
Con: tile boundaries visible unless overlap margin is used; importance
sampling can't cross tiles.

**5c. Coarse-grained: parallel candidate scoring, serial acceptance.**

`Threads.@threads` inside the proposal — parallel `gen_circle_points` +
`mean(penalty[p])` + palette lookup. Acceptance stays serial.

Pro: safe, low-risk. Reuses existing loop structure.
Con: modest speedup (~2×) — dominant cost per step isn't the scoring.

**5d. Independent chains, merge at end.**

Run K completely independent full runs with different seeds (like
`--seed 0..K-1`), merge circles by taking union or by simulated overlap
resolution.

Pro: dead simple; embarrassingly parallel.
Con: total work = K × single run; only useful if consuming K different
outputs.

### Recommendation

**5a** (batch propose, sequential commit). Best speedup/risk trade.
`@threads` around a batch of `K` proposals; sequential commit filters
stale ones.

### API

No flags. Batch size auto-derived from `Threads.nthreads()`; run Julia
with `-t N`. Rationale (2026-08-10): only sane batch value is
`nthreads()` (larger = uneven finish; smaller = underutilized). A
separate `--batch-size` knob was tried and dropped as unnecessary.

### Complexity

Per step: parallel scoring `K` candidates ≈ K× less wall time. Commit
filter is O(K). Net: ~4–6× speedup on 8-thread machine (some slippage
from stale-state rejects).

### Test

Byte-identity across thread counts is impossible (task-local RNG state
depends on scheduling); test at `-t 1` for the reference path and
compare quality metrics (RMSE, accept-rate) at higher thread counts.

---

## Task 6 — Alpha-blend accepted circles

**Status**: not started. **Priority**: aesthetic — Seurat-style color
mixing.
**Complexity**: one-line change.

### Motivation

`out[i] = c.color` overwrites. Two overlapping circles = only the second
color visible. Real pointillism relies on adjacent-color optical mixing;
digital equivalent is alpha-blending.

### Alternatives

**6a. Fixed alpha per accepted circle.**

```
out[i] = α * c.color + (1 - α) * out[i]     # α ≈ 0.7
```

Pro: minimal change. Visible immediately.
Con: color drifts toward average; needs artistic tuning.

**6b. Alpha ∝ residual.**

Fresh regions (high residual) get α ≈ 1 (full color). Already-drawn
regions (low residual) get α ≈ 0.3 (subtle overlay).

Pro: preserves detail in finished areas; mixes on top of them.
Con: two-argument blend; slightly more compute.

**6c. Additive-in-Lab.**

Compute weighted mean in Lab space per pixel across all overlapping
circles. Post-process rather than incremental.

Pro: physically correct color mixing.
Con: needs per-pixel color list; memory-heavy.

### Recommendation

**6a** with `α` exposed as `--alpha`. Default 1.0 = current behavior.
Set `--alpha 0.7` for pointillist mixing.

### API

```
--alpha A               default 1.0    # 1.0 = overwrite, 0.5 = 50/50 blend
```

### Complexity

Zero cost. One multiplication per pixel per accepted circle.

### Test

Assert: `--alpha 1.0` output ≡ current output. `--alpha 0.5` output
differs in RGB values but shape identity is preserved.

---

## Task 8 — `--uniform-centers` flag (killed)

**Status**: killed 2026-08-10. Reason: low-value polish. Importance sampling
is the only production path; adding a debug branch to A/B-measure it earns
its keep only if someone actually runs the benchmark. No one plans to. The
`r_max <= 0` fallback inside `importance_center` already covers the
degenerate flat-residual case. If measurement infra ever ships (Task 0 bench
harness), reconsider then.

---

## Task 9 — Palette locality

**Status**: not started. **Priority**: medium visual quality.
**Complexity**: medium (extra k-means pass or preprocessing).

### Motivation

Global k-means picks colors that minimize *global* variance. Local
regions can have terrible palette matches (background palette color
used on a face because it's the "closest" among 32 clusters).

### Alternatives

**9a. Larger palette.**

`--color-palette 128` or 256. Trivial but slower and less "pointillist".

**9b. Per-region palette (tile k-means).**

Split image into tiles (e.g. 4×4), k-means each tile independently for
a small local palette, use the union. Preserves per-region color fidelity.

Pro: local matching. Roughly same total colors as global palette.
Con: color transitions between tiles can be sharp.

**9c. LAB-perceptual k-means.**

Already using Lab, but weight `a`/`b` chroma over `L` luminance.
Empirically produces palettes that better preserve skin tones.

**9d. Adaptive palette (per accepted circle).**

Instead of pre-computing a palette, pick color per accepted circle as
`nearest_of(palette ∪ {mean_target_at_circle})` — extends palette
on-demand. Cap total colors at `max-palette`.

Pro: uses source colors directly where palette fails.
Con: risk of palette explosion; harder to reason about.

### Recommendation

**9b** (tile k-means). Balances quality and complexity. Ship as
`--palette-mode global|tiled` with `--tile-count N`.

### API

```
--palette-mode MODE     default global    # global | tiled
--tile-count N          default 4         # tiles per axis (in tiled mode)
```

### Complexity

Preprocessing: `N² * kmeans(H*W/N²)` vs single `kmeans(H*W)`. Comparable
order of magnitude. Per-step: single `argmin` over larger palette.

### Test

Assert: tiled palette output on a portrait has different (better) skin
tones than global palette output — subjective but measurable by
histogram distance to source.

---

## Task 10 — Progress reporting

**Status**: not started. **Priority**: developer QoL.
**Complexity**: trivial.

### Motivation

`@debug "Step $step of $steps"` fires per step at debug level. No
progress at info level. Long runs are opaque.

### Alternatives

**10a. Print at `step % (steps ÷ 20) == 0` (5% granularity).**

`@info "step $step/$steps  accept=$accept  circles=$(length(circles))"`.

**10b. `ProgressMeter.jl` dependency.**

Fancy in-terminal bar with ETA. Adds a package dep.

**10c. Signal handler that dumps state on SIGUSR1.**

`kill -USR1 <pid>` prints current stats. Useful for long batch runs.

### Recommendation

**10a**. No dep, minimal noise, meaningful. Skip 10b (overkill), 10c
(niche).

### API

None. Or `--quiet` to suppress.

### Complexity

One `mod` check per step.

### Test

None needed (log formatting).

---

## Cross-cutting: test strategy

Every task above modifies the generative loop. Without an objective
harness, "did it improve?" collapses to eyeballing SVGs at 2am. This
section defines the test corpus, metrics, and workflow. Build once, use
per task.

### Test corpus

Purpose-built set covering the failure modes each task targets. Small
enough to run in ~15 min for a full sweep, diverse enough that a change
that helps portraits but hurts landscapes gets caught.

| Category                     | Sample count | What it stresses                       | Task relevance |
|------------------------------|--------------|----------------------------------------|-----------------|
| **Classical sculpture bust** | 2            | Baseline. Clean subject/background.    | All tasks. Regression anchor. |
| **Renaissance portrait**     | 2            | Skin tones, subtle chiaroscuro.        | 1, 9 (color fidelity, palette locality) |
| **Ukiyo-e print**            | 1            | Already-limited palette, hard edges.   | 3, 7 (penalty semantics, cooling) |
| **Painterly landscape**      | 2            | Gradients (sky), texture (foliage).    | 2, 6 (radius schedule, alpha) |
| **Van Gogh / high-brush**    | 1            | Bold strokes, saturated color regions. | 2, 6 |
| **Album cover / graphic**    | 1            | Solid color blocks, sharp lines.       | 1, 3 (color-aware, overlap depth) |
| **High-contrast photograph** | 2            | Full histogram, dramatic tone.         | 4 (coverage stop — hits saturation faster) |
| **Adversarial: fine texture**| 1            | Grass, fur, small detail.              | 2, 9 (radius, palette). Should degrade *gracefully*. |
| **Adversarial: text/UI**     | 1            | Known-bad case. Must not crash or hang.| Stability check, not quality. |

**Total: 13 images.** Store in `test/corpus/` at consistent short-side
(768 or 1024 px). Include an `attribution.txt` naming source and
license.

Concrete starter set (all public domain or commons):

```
test/corpus/
    01_bust_marcus_aurelius.png       # existing
    02_bust_aristotle.png             # existing
    03_portrait_vermeer_pearl.png     # https://commons.wikimedia.org/...
    04_portrait_rembrandt_self.png
    05_ukiyoe_hokusai_wave.png
    06_landscape_monet_lily.png
    07_landscape_church_pond.png
    08_painterly_vangogh_stars.png
    09_graphic_bluenote_1568.png
    10_photo_ansel_adams.png
    11_photo_karsh_churchill.png
    12_texture_grass_closeup.png      # adversarial
    13_ui_screenshot.png              # adversarial
```

### Metrics

Objective (script-computable), ordered by usefulness:

**M1. Per-pixel RMSE (Lab space).**
```
rmse = sqrt(mean((target_lab - render_lab).^2))
```
Direct fidelity. Lab because color perception isn't linear in RGB.
Julia: `Images.jl` + broadcast. ImageMagick has an RGB approximation
via `magick compare -metric RMSE`.

**M2. SSIM.**
```
using Images
ssim(target_gray, render_gray)
```
Structural similarity. More robust to color-quantization noise than
RMSE. `ImageQualityIndexes.jl` provides it in one call.

**M3. Palette distance.**
```
palette_target = kmeans(target, K)
palette_render = kmeans(render,  K)
d = min_assignment_cost(palette_target, palette_render, color_distance)
```
How faithfully the render preserves the source's color statistics.
Independent of spatial placement. Catches "muddy palette" failures
that RMSE misses.

**M4. Coverage & circle stats.**
- `circles_drawn / steps` (accept efficiency)
- `mean(radius)` (schedule verification)
- `max(penalty)` (overlap depth — for task 3)
- `runtime_wall_seconds`

**M5. File size (SVG).**
Rough proxy for geometric complexity. Useful for schedule tasks.

Subjective (human-scored, small N):

**M6. Blind pairwise A/B.**
Grid of triples (baseline, candidate_a, candidate_b) shown in random
order. Human picks preferred. Recorded in a CSV. Ship 10 blind pairs
per major task change; require statistical majority (~7/10) to accept.

### Workflow per task

```
1. Baseline run: current-HEAD version × corpus (13 images) × 2 configs
   (100k/300k steps, everything else default).
   Store as test/results/baseline/<image>_<config>.png plus metrics.

2. Implement task on a branch.

3. Candidate run: same corpus × same configs plus one new config that
   exercises the task's new knobs (e.g. --color-tolerance 0.5).

4. Compare:
   scripts/compare.jl test/results/baseline test/results/candidate
     → prints per-image delta table: rmse_before, rmse_after, ssim_delta, ...

5. Accept if:
   - No image degrades > 5% on RMSE (regression).
   - Target category (per task table above) improves >= 5% on average.
   - Adversarial images don't crash / hang.

6. On rejection: log the failure image + params in test/regressions.md.
   Iterate.
```

### Directory layout

Actual current layout (gitignored via `test/*`):

```
test/
    fixtures/             # input images (aristotle, flowers, girl_pearl, ...)
    results/              # per-task outputs, gitignored
        baseline/         # from baseline.sh
        task1/            # from task1.sh (color-aware A/B)
        task2/            # from task2.sh (radius schedule A/B)
        task45/           # from task45.sh (threading + early stop)
    scripts/
        baseline.sh       # canonical corpus × 2 configs
        task1.sh          # per-task A/B run
        task2.sh
        task45.sh
```

Aspirational bits not yet built: `bench.jl`, `compare.jl`, structured
metrics JSON. Current harness emits CSV rows per run (image, config,
seconds, circles, stopped_at). Enough for eyeballing; formal metrics
land with Task 0 if needed.

### Test-strategy alignment per task

| Task | Primary metric | Corpus focus                     | Regression risk |
|------|---------------|----------------------------------|-----------------|
| 1 color-aware  | M1, M3       | Portraits, painterly            | Graphic/hard-edge may lose intent |
| 2 radius       | M2, M4       | Landscape, texture              | Sculptures may over-detail        |
| 3 penalty      | M4 (depth)   | Graphic, ukiyo-e                | Semantic change — retune all      |
| 4 coverage stop| M4 (runtime) | High-contrast photos            | Under-run on dense images         |
| 5 threading    | M4, quality-not-worse across `-t` | Any   | Correctness > quality here        |
| 6 alpha        | M2, subjective | Painterly, landscape           | Loss of edge sharpness            |
| 7 cooling      | M1, M2       | Full corpus                      | Same as 1                         |
| 9 palette      | M3           | Portraits, graphic               | Runtime cost                      |

### Minimum harness (Task 0)

Before Task 1, ship the smallest useful harness:

```
scripts/bench.jl                     # run corpus × two configs, dump metrics
scripts/compare.jl <dir_a> <dir_b>   # tabular diff, prints regressions
```

Concretely, a fifty-line Julia script per file. No frameworks, no config
DSL, no reporting UI. Data as CSV; render tables in the terminal.
Everything else is over-engineering until it isn't.

### What NOT to test

- **Exact byte equality of PNG outputs across Julia versions.** Palette
  k-means uses random init; even with `Random.seed!` the ordering of
  centroids drifts across Julia point releases. Test metrics, not bits.
- **Threading correctness by comparing full runs across thread counts.**
  Same reason: fine-grained scheduling changes commit order for `5a`.
  Test at `-t 1` for the reference path; test at higher `-t` for
  quality-not-worse.
- **Every parameter combination.** The 72-run grid is a *research*
  sweep, not a regression suite. Regression = 13 images × 2 configs.

### Cadence

- **Per commit**: run corpus × 1 fast config (`--steps 50000`) — smoke,
  ~2 min.
- **Per PR**: full corpus × 2 configs — ~15 min.
- **Per release / major change**: add M6 pairwise on a subset — ~30 min
  human time.

### Metric implementation notes

`bench.jl` skeleton (~40 lines):

```julia
using Images, Statistics, JSON3, ImageQualityIndexes

function metrics(target_path, render_path)
    t = load(target_path);  t_lab = convert.(Lab, t)
    r = load(render_path);  r_lab = convert.(Lab, r)
    rmse = sqrt(mean(((getfield.(t_lab, :l) .- getfield.(r_lab, :l)).^2 .+
                      (getfield.(t_lab, :a) .- getfield.(r_lab, :a)).^2 .+
                      (getfield.(t_lab, :b) .- getfield.(r_lab, :b)).^2)))
    return (rmse=rmse, ssim=assess_ssim(Gray.(t), Gray.(r)))
end

# usage: julia bench.jl corpus/*.png configs/baseline.json results/baseline/
```

Keeps the moving parts under 100 lines total across `bench.jl` +
`compare.jl`. When a task needs more, add it then.

---

## Order of operations recommendation

1. ~~Task 1 (color-aware acceptance)~~ — killed 2026-08-09, redundant with
   importance sampling.
2. ~~Task 2 (radius schedule)~~ — shipped 2026-08-09 (commit 44ba1e6).
3. ~~Task 4 (coverage-based stop) + Task 5 (threading)~~ — shipped
   2026-08-09 (commit 0930230), simplified 2026-08-10 (commit baeec05).
4. ~~Task 8 (uniform centers)~~ — killed 2026-08-10, low-value polish.
5. Task 9 (palette locality) — only if perceived color issues remain.
   **← current**
6. Task 3 (accumulating penalty) — breaks CLI compatibility, do at a
   major version bump.
7. Task 6 (alpha), Task 10 (progress) — polish, any time.
