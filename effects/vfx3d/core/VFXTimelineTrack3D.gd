extends Resource
class_name VFXTimelineTrack3D

@export var track_id := "layer"
@export var phase := "Impact"
@export_range(0.0, 20.0, 0.01) var start_time := 0.0
@export_range(0.01, 20.0, 0.01) var duration := 0.5
@export_range(0.0, 5.0, 0.01) var fade_in := 0.06
@export_range(0.0, 5.0, 0.01) var fade_out := 0.16
@export_range(0.05, 4.0, 0.05) var time_scale := 1.0
@export var loop := false
@export var trigger_once := true
@export var module_script: Script
@export var profile: VFXProfile3D
