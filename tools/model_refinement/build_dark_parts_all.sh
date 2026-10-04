#!/usr/bin/env bash
# Build parts for the dark race and stage the runtime GLBs into the project.
# Usage: build_dark_parts_all.sh <blender> <project> <refs_dir> [unit ...]
set -u
BLENDER="$1"; PROJECT="$2"; REFS="$3"; shift 3
UNITS=("$@")
[ ${#UNITS[@]} -eq 0 ] && UNITS=(dark_imp dark_mage dark_scythe dark_suc dark_fear dark_queen dark_doom dark_dragon)
for unit in "${UNITS[@]}"; do
  out="$REFS/$unit/parts"
  mkdir -p "$out"
  if "$BLENDER" --background --factory-startup --python-exit-code 1 --python "$PROJECT/tools/model_refinement/build_dark_parts.py" -- \
      --unit "$unit" --refs "$REFS" --out "$out" --render > "$out/build.log" 2>&1 && [ -s "$out/${unit}_parts.glb" ]; then
    cp "$out/${unit}_parts.glb" "$PROJECT/assets/models/units/dark_refined/$unit/${unit}_parts.glb"
    echo "ok $unit $(grep -o 'DARK_PARTS_COMPLETE.*' "$out/build.log" | grep -o '"triangles": \[[0-9, ]*\]')"
  else
    echo "FAIL $unit"; grep -E "Error|Traceback|line [0-9]+" "$out/build.log" | tail -5
  fi
done
