class_name BoardReadabilityStyle
extends Resource

@export_group("Shared Palette")
@export var friendly_color := Color(0.28, 0.86, 0.86, 1.0)
@export var enemy_color := Color(0.94, 0.38, 0.28, 1.0)
@export var selection_color := Color(1.0, 0.78, 0.24, 1.0)
@export var range_color := Color(0.98, 0.66, 0.22, 1.0)
@export var guide_text_color := Color(0.94, 0.90, 0.72, 0.78)
@export var guide_shadow_color := Color(0.02, 0.025, 0.02, 0.82)

@export_group("Prep Board")
@export_range(0.0, 0.30, 0.005) var prep_rest_fill_alpha := 0.055
@export_range(0.0, 1.0, 0.01) var prep_rest_line_alpha := 0.52
@export_range(0.0, 0.40, 0.005) var prep_drag_fill_alpha := 0.12
@export_range(0.0, 1.0, 0.01) var prep_drag_line_alpha := 0.76
@export_range(0.0, 0.40, 0.005) var prep_range_fill_alpha := 0.07
@export_range(0.0, 1.0, 0.01) var prep_range_line_alpha := 0.38
@export_range(0.0, 0.50, 0.005) var prep_selected_fill_alpha := 0.16
@export_range(0.0, 1.0, 0.01) var prep_selected_line_alpha := 0.96
@export_range(1.0, 8.0, 0.25) var prep_line_width := 2.0

@export_group("Battlefield")
@export_range(0.0, 0.20, 0.002) var battle_zone_fill_alpha := 0.026
@export_range(0.0, 0.50, 0.005) var battle_zone_line_alpha := 0.07
@export_range(0.0, 0.30, 0.005) var battle_range_fill_alpha := 0.045
@export_range(0.0, 1.0, 0.01) var battle_range_line_alpha := 0.42
@export_range(1.0, 8.0, 0.25) var battle_line_width := 2.0
@export_range(1.0, 8.0, 0.25) var target_line_width := 2.25
@export var low_quality_zone_fills := false
