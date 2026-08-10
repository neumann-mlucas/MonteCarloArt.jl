#!/usr/bin/env bash
# Task 2 (radius schedule) — sweeps --radius-start / --radius-end.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR="$(cd -- "${HERE}/../.." &>/dev/null && pwd)"
CORPUS_DIR="${PROJECT_DIR}/test/fixtures"
OUT_DIR="${PROJECT_DIR}/test/results/task2"
NORM_DIR="${OUT_DIR}/_inputs"
BENCH_CSV="${OUT_DIR}/bench.csv"
JULIA_BIN="${JULIA_BIN:-julia}"
JULIA_OPTS=(-O3 -t 8)
CSV_HEADER="image,config,steps,palette,tol,r0,r1,seconds,circles,status,git_sha"

# name|steps|palette|tol|r0|r1
CONFIGS=(
  "fast|100000|64|0.08|3.0|0.3"
  "full|300000|64|0.08|3.0|0.3"
)

source "${HERE}/lib.sh"

run_config() {
  local cfg="$1" input="$2" out_stem="$3"
  IFS='|' read -r name steps palette tol r0 r1 <<< "$cfg"

  local stem_short; stem_short="$(basename "$out_stem")"
  if [[ -f "${out_stem}.png" ]]; then
    echo "  SKIP  ${stem_short}.png"; return
  fi

  julia_timed "${out_stem}.log" "${JULIA_OPTS[@]}" --project="$PROJECT_DIR" main.jl \
    -i "$input" -o "${out_stem}.png" \
    --color --color-palette "$palette" --steps "$steps" -t "$tol" \
    --radius-start "$r0" --radius-end "$r1"

  local circles; circles="$(extract_circles "${out_stem}.log")"
  local img; img="$(basename "$input" .png)"
  echo "${img},${name},${steps},${palette},${tol},${r0},${r1},${LAST_SECS},${circles:-},${LAST_STATUS},$(git_sha)" >> "$BENCH_CSV"
  echo "  ${LAST_STATUS^^}  ${stem_short}.png  ($(fmt_time $LAST_SECS), circles=${circles:-?})"
}

run_sweep "$@"
