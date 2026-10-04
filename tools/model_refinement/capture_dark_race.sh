#!/usr/bin/env bash
# Capture the dark-race refinement matrix with the real preview (rendered, not headless).
# Usage: capture_dark_race.sh <godot> <project> <out_dir> <old|new> [unit ...]
# VIEWS="front battle" limits the per-unit views; LINEUP=0 skips the race line-ups.
# Each run writes 4 frames (idle 0.8s, run 3.0s, attack 5.3s, idle 6.9s) plus capture-metadata.json.
set -u
GODOT="$1"; PROJECT="$2"; OUT="$3"; VARIANT="$4"; shift 4
UNITS=("$@")
[ ${#UNITS[@]} -eq 0 ] && UNITS=(dark_imp dark_mage dark_scythe dark_suc dark_fear dark_queen dark_doom dark_dragon)
FLAG=""; [ "$VARIANT" = "old" ] && FLAG="--old"
run() { # dir, args...
  local dir="$1"; shift
  mkdir -p "$dir"
  "$GODOT" --path "$PROJECT" --rendering-method gl_compatibility --resolution 1280x720 \
    res://scenes/debug/DarkRaceRefinementPreview.tscn -- "$@" --capture-dir "$dir" > "$dir/run.log" 2>&1
  local code=$?
  if ! grep -q "MODEL_CAPTURE_COMPLETE" "$dir/run.log"; then echo "FAIL($code) $dir"; grep -E "ERROR" "$dir/run.log" | head -3; return 1; fi
  echo "ok $dir"
}
VIEWS="${VIEWS:-front side back battle}"
for unit in "${UNITS[@]}"; do
  for view in $VIEWS; do
    if [ "$view" = battle ]; then run "$OUT/$VARIANT/$unit/battle" --unit "$unit" $FLAG --view battle
    else run "$OUT/$VARIANT/$unit/close-$view" --unit "$unit" $FLAG --close --view "$view"; fi
  done
done
if [ "${LINEUP:-1}" = 1 ]; then
  run "$OUT/$VARIANT/lineup-battle" $FLAG --lineup --view battle
  run "$OUT/$VARIANT/lineup-close-front" $FLAG --lineup --close --view front
  run "$OUT/$VARIANT/lineup-close-back" $FLAG --lineup --close --view back
fi
