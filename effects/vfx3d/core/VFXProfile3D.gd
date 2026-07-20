extends Resource
class_name VFXProfile3D

@export var profile_id := "default"
@export var module_id := ""
@export var curve_name := "explosive_out"
@export var dark_color := Color(0.03, 0.08, 0.22, 1.0)
@export var main_color := Color(0.16, 0.68, 1.0, 1.0)
@export var core_color := Color(0.72, 0.98, 1.0, 1.0)
@export_range(0.1, 4.0, 0.05) var size := 1.0
@export_range(0.05, 6.0, 0.05) var duration := 0.6
@export_range(1, 128, 1) var particle_count := 16
@export_range(0.0, 4.0, 0.05) var trail_length := 0.8
@export_range(0.0, 12.0, 0.1) var emission_energy := 3.0
@export var ground_aligned := false
@export var quality_group := "gameplay"
@export var parameters: Dictionary = {}

func duplicate_runtime() -> VFXProfile3D:
	return duplicate(true) as VFXProfile3D
