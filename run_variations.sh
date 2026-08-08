#!/usr/bin/env bash
# Batch-run MonteCarloArt over a grid of parameters for each input image.
#
# Layout (created if missing):
#   in/     normalized PNG copies of source images (auto-converted from webp/etc)
#   out/    results, one PNG per parameter combination
#
# Naming: out/<stem>__c{0|1}_p<palette>_s<steps>_t<tol>.png
#   c1 = color mode, c0 = grayscale
#   p  = --color-palette
#   s  = --steps
#   t  = --overlap-tolerance
#
# Usage:  ./run_variations.sh
#
# Prereqs: julia, and one of {magick, convert} for webp/other → png normalization.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"
IN_DIR="${SCRIPT_DIR}/in"
OUT_DIR="${SCRIPT_DIR}/out"
JULIA_BIN="${JULIA_BIN:-julia}"
JULIA_OPTS=(-O3 -t 8)

mkdir -p "$IN_DIR" "$OUT_DIR"

# --- inputs ---------------------------------------------------------------
INPUTS=(
  "/home/neumann/Downloads/marcus-aurelius-6363862_1280.webp"
  "/home/neumann/Downloads/Aristotle_Altemps_Inv8575.jpg"
  # add more paths here
)

# --- parameter grid -------------------------------------------------------
COLORS=(true)
PALETTES=(64)
STEPS=(100000 300000)
TOLS=(0.08 0.12)

# --- helpers --------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

im_convert() {
  # $1 src, $2 dst
  if have magick; then
    magick "$1" "$2"
  elif have convert; then
    convert "$1" "$2"
  else
    echo "ERROR: neither 'magick' nor 'convert' is installed" >&2
    exit 1
  fi
}

normalize_to_png() {
  # Normalize any input to PNG under IN_DIR. Echoes destination path.
  local src="$1"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: input not found: $src" >&2
    exit 1
  fi
  local name stem ext dst
  name="$(basename "$src")"
  stem="${name%.*}"
  ext="${name##*.}"
  dst="${IN_DIR}/${stem}.png"

  if [[ ! -f "$dst" ]]; then
    case "${ext,,}" in
    png) cp "$src" "$dst" ;;
    *) im_convert "$src" "$dst" ;;
    esac
  fi
  echo "$dst"
}

fmt_time() {
  local s="$1"
  printf '%dm%02ds' $((s / 60)) $((s % 60))
}

run_one() {
  local input="$1"
  local out_stem="$2"
  local color="$3"
  local palette="$4"
  local steps="$5"
  local tol="$6"

  if [[ -f "${out_stem}.png" ]]; then
    echo "  SKIP  ${out_stem}.png (exists)"
    return
  fi

  local flags=(
    -i "$input"
    -o "$out_stem"
    --steps "$steps"
    --color-palette "$palette"
    -t "$tol"
  )
  [[ "$color" == "true" ]] && flags+=(--color)

  local t0 t1
  t0=$(date +%s)
  (cd "$PROJECT_DIR" && "$JULIA_BIN" "${JULIA_OPTS[@]}" main.jl "${flags[@]}") \
    >"${out_stem}.log" 2>&1
  t1=$(date +%s)
  echo "  DONE  ${out_stem}.png  ($(fmt_time $((t1 - t0))))"
}

# --- main loop ------------------------------------------------------------
total=$((${#INPUTS[@]} * ${#COLORS[@]} * ${#PALETTES[@]} * ${#STEPS[@]} * ${#TOLS[@]}))
i=0
overall_t0=$(date +%s)

for src in "${INPUTS[@]}"; do
  png="$(normalize_to_png "$src")"
  stem="$(basename "$png" .png)"
  echo "=== $stem  ($png) ==="

  for color in "${COLORS[@]}"; do
    for palette in "${PALETTES[@]}"; do
      for steps in "${STEPS[@]}"; do
        for tol in "${TOLS[@]}"; do
          i=$((i + 1))
          cbit=0
          [[ "$color" == "true" ]] && cbit=1
          tag="c${cbit}_p${palette}_s${steps}_t${tol}"
          out="${OUT_DIR}/${stem}__${tag}"
          printf '[%02d/%02d] ' "$i" "$total"
          run_one "$png" "$out" "$color" "$palette" "$steps" "$tol"
        done
      done
    done
  done
done

overall_t1=$(date +%s)
echo
echo "All done: $total runs in $(fmt_time $((overall_t1 - overall_t0)))"
echo "Outputs:  $OUT_DIR"
echo "Inputs:   $IN_DIR"
