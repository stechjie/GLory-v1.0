extends Resource
class_name VFXRecipeV2

@export var recipe_id := "vfxv2_recipe"
@export var stage_ids: PackedStringArray = []
@export var stage_starts: PackedFloat32Array = []
@export var stage_durations: PackedFloat32Array = []
@export var quality_group := "gameplay"

func stage_count() -> int:
	return stage_ids.size()
