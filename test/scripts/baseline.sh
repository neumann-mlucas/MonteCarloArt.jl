#!/usr/bin/env bash
# Baseline run for MonteCarloArt.jl: current-HEAD × corpus × canonical configs.
# Each config emits both PNG and SVG. Skips outputs that already exist.
#
# Usage:  ./test/scripts/baseline.sh                # full corpus
#         ./test/scripts/baseline.sh aristotle.png  # subset (basename or path)
#
# Env: JULIA_NUM_THREADS (default 8), JULIA_BIN.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${HERE}/lib.sh"

set_out_dir "baseline"
JULIA_OPTS=(-O3 -t "${JULIA_NUM_THREADS:-8}")
CSV_HEADER="image,config,steps,palette,tol,stop_miss,seconds,circles,status,git_sha"

# name|steps|palette|tol|stop_miss
# tol values sweep {0.08, 0.20}; stop_miss values sweep {0.99 (~off), 0.85 (early)}
CONFIGS=(
  "fast|100000|64|0.08|0.99"
  "full|300000|64|0.08|0.99"
  "loose|100000|64|0.20|0.99"
  "earlystop|100000|64|0.08|0.85"
)

run_config() {
  local cfg="$1" input="$2" out_stem="$3"
  IFS='|' read -r name steps palette tol stop_miss <<< "$cfg"

  local stem_short; stem_short="$(basename "$out_stem")"
  if [[ -f "${out_stem}.png" && -f "${out_stem}.svg" ]]; then
    echo "  SKIP  ${stem_short}.{png,svg}"; return
  fi

  julia_timed "${out_stem}.log" "${JULIA_OPTS[@]}" --project="$PROJECT_DIR" main.jl \
    -i "$input" -o "${out_stem}.png,${out_stem}.svg" \
    --color --color-palette "$palette" --steps "$steps" \
    -t "$tol" --stop-miss-rate "$stop_miss"

  local circles; circles="$(extract_circles "${out_stem}.log")"
  local img; img="$(basename "$input" .png)"
  echo "${img},${name},${steps},${palette},${tol},${stop_miss},${LAST_SECS},${circles:-},${LAST_STATUS},$(git_sha)" >> "$BENCH_CSV"
  echo "  ${LAST_STATUS^^}  ${stem_short}.{png,svg}  ($(fmt_time "$LAST_SECS"), circles=${circles:-?})"
}

run_sweep "$@"
