# iOS rendering load fixes — build 99

The iPhone play session reported severe heating and mild stutter on the default
board skin. CPU traces showed repeated Canvas geometry rebuilding. These changes
remove redundant work while retaining artwork, effect counts and quality settings.

## Changes

- `BoardReadabilityLayer`: ignore unchanged presentation state instead of
  rebuilding the same board guides every frame.
- `DamageCounterPlate` / `BattleCombatFeedback`: avoid unchanged color redraws
  and repeated font-size overrides that trigger label layout.
- `ShopCardFrame`: retain static frame and breathing-glow geometry on separate
  canvases; animate glow alpha and keep upgrade effects in their original order.
  Hidden cards suspend their animation updates.
- `PrepLawnFx`: cache canonical butterfly wing geometry, then transform it for
  each pose. Keep all butterflies, motes, trails and timing.
- `ReadyOrbitGlow`: cache trajectory geometry and shared colors. Preserve the
  original 64 segments, 30 Hz cadence and ordered draw commands.
- `PerfLog`: opt-in resource/frame recording, bounded output and availability
  flags for unsupported counters. Recording is disabled in normal delivery.
  Enable with `--resource-perf-log` or a `user://resource_perf.enabled` marker;
  marker contents `off`, `false` or `0` disable it unless the explicit flag is set.

## Companion resource

Resource scripts under `assets/models/` are managed in Drive. The matching
`FormationAllyAnimated.gd` change pauses hidden action AnimationPlayers while
retaining playback for the selected action. It is required with this revision:

- Path: `assets/models/allies/FormationAllyAnimated.gd`
- [Existing Drive resource](https://drive.google.com/file/d/1e5cv5EhV5sngheSgsPpF2cos3YVjUTNL/view)
- SHA-256: `178af14317358efe7c8aef07932e466304938dd6bf67c5ea8d17be5420a83a18`
- Size: 7,560 bytes. The uploaded file was downloaded again and compared byte for
  byte with both the project asset and the `res` mirror.

## Validation

The same-device 98/99 UI comparison used an identical isolated workload and
resources, with the default lawn, four shop cards, ready effect and board guides.
Game autoloads, account access and player state were excluded from this workload.

| Combined UI workload | Build 98 | Build 99 |
| --- | ---: | ---: |
| FPS | 53.48 | 59.99 |
| P95 frame interval | 25.029 ms | 16.853 ms |
| Process CPU, one-core scale | 90.00% | 63.28% |
| Device GPU | 21.85% | 30.00% |

Seven phone image comparisons differed by at most 1/255 in a channel and at most
11 pixels per image. Resource inventory hashes matched between the packages.
A separate combined-workload power-counter comparison supported lower overall
device load; its raw units and smoothing are unspecified and it had only two to
three counter refreshes. Neither result establishes a temperature reduction or
whole-match thermal equilibrium. Full-match heating acceptance remains pending.

Regression coverage includes board redraw signals, damage-label theme changes,
565 formation animation assertions, 288 exact shop pixel comparisons, 459,648
butterfly vertex comparisons, 90,585 unchanged ready-effect drawing commands,
three exact ready-effect images, and opt-in recorder behavior.

The accompanying checks are under `tools/`. The ready-effect fixture runner is
`python3 tools/ready_orbit_cache_check.py --godot /path/to/godot --render`.
It loads the unchanged rune texture from the project or the workspace `res`
mirror. Shop pixel checks use `tools/shop_card_retained_check.tscn` with
`--render-equivalence` on a real rendering backend. Use synchronized resources
for the formation and complete prep-scene checks.
