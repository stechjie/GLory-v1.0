# FrameRonin VFX selection

Source: https://frameronin.com/recharge-resources#rr-slot-01
Archive: VFX_Lightweight_Godot4_2026-10-27.zip
Archive SHA256: 20723b1adfd312950a4eee4163a870978254b305a46424fba7515062a0979460

The user confirmed on 2026-10-31 that the author offers these resources free and explicitly authorized integration. No license terms were invented or appended to upstream code.

Selected presets:
- 81 / BLUNT IMPACT: expansion_fx_layer.gd, _draw_combat_blunt_impact.
- 85 / CRITICAL BREAK: expansion_fx_layer.gd, _draw_combat_critical_break.
- 115 / REFRACTION RING: scripts/screen_vfx_canvas.gd, _draw_refraction_ring.

UPSTREAM_EXCERPTS.txt retains the original selected geometry and timing functions for attribution and comparison. Other presets, editor tools, demo scenes, model shells and unrelated textures were not imported.

Adaptation:
- FrameRoninImpactMeshes.gd retains the source geometry routines; normalizes their reference centers to the death anchor; fixes the contact star plane; caches twelve growth poses per preset instead of rebuilding ImmediateMesh every frame. Source 1.6s repeating anticipation is retimed into one 0.34s fatal-hit accent. Pressure-ring width is reduced and UV-tagged so that rings release within 0.13s while the core and fragments remain readable.
- coin_burst_flash.gdshader adapts the source expansion_signature vertex-color shader to the transparent battle SubViewport and a per-instance fade. Flash accessibility and existing quality gates remain active.
- lane_clear_wave.gdshader ports preset 115's three segmented rings, twelve optical ticks and two delayed echoes to a clipped ground quad. Screen sampling is omitted; no other lane or HUD is refracted. Colors are retuned to gold / white to match coin feedback.
