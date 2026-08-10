#!/usr/bin/env bash
# Task 4 + Task 5 — parallel proposals + EMA early stop.
# Threads varies per config via -t.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR="$(cd -- "${HERE}/../.." &>/dev/null && pwd)"
CORPUS_DIR="${PROJECT_DIR}/test/fixtures"
OUT_DIR="${PROJECT_DIR}/test/results/task45"
NORM_DIR="${OUT_DIR}/_inputs"
BENCH_CSV="${OUT_DIR}/bench.csv"
JULIA_BIN="${JULIA_BIN:-julia}"
CSV_HEADER="image,config,steps,palette,tol,r0,r1,threads,stop_miss,seconds,circles,stopped_at,status,git_sha"

# name|steps|palette|tol|r0|r1|threads|stop_miss
CONFIGS=(
  "fast_threaded|100000|64|0.08|3.0|0.3|8|1.0"
  "fast_stop_only|100000|64|0.08|3.0|0.3|1|0.95"
  "fast_threaded_stop|100000|64|0.08|3.0|0.3|8|0.95"
  "full_threaded_stop|300000|64|0.08|3.0|0.3|8|0.95"
)

source "${HERE}/lib.sh"

run_config() {
  local cfg="$1" input="$2" out_stem="$3"
  IFS='|' read -r name steps palette tol r0 r1 threads stop_miss <<< "$cfg"

  local stem_short; stem_short="$(basename "$out_stem")"
  if [[ -f "${out_stem}.png" ]]; then
    echo "  SKIP  ${stem_short}.png"; return
  fi

  julia_timed "${out_stem}.log" -O3 -t "$threads" --project="$PROJECT_DIR" main.jl \
    -i "$input" -o "${out_stem}.png" \
    --color --color-palette "$palette" --steps "$steps" -t "$tol" \
    --radius-start "$r0" --radius-end "$r1" \
    --stop-miss-rate "$stop_miss"

  local circles; circles="$(extract_circles "${out_stem}.log")"
  local stopped; stopped="$(extract_stopped_at "${out_stem}.log")"
  local img; img="$(basename "$input" .png)"
  echo "${img},${name},${steps},${palette},${tol},${r0},${r1},${threads},${stop_miss},${LAST_SECS},${circles:-},${stopped:-},${LAST_STATUS},$(git_sha)" >> "$BENCH_CSV"
  echo "  ${LAST_STATUS^^}  ${stem_short}.png  ($(fmt_time $LAST_SECS), circles=${circles:-?}, stopped_at=${stopped:-none})"
}

run_sweep "$@"
