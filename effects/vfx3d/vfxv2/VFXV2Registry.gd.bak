extends RefCounted
class_name VFXV2Registry

const BINBUN := preload("res://effects/vfx3d/vfxv2/VFXBinbunReference3D.gd")
const EXTERNAL := preload("res://effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd")
const COMPOSER := preload("res://effects/vfx3d/vfxv2/core/VFXStageComposerV2.gd")
const FIRE_RECIPE := preload("res://effects/vfx3d/vfxv2/recipes/fire_projectile_v2.tres")
const LOOT_RECIPE := preload("res://effects/vfx3d/vfxv2/recipes/loot_burst_v2.tres")
const FIREBALL_STANDARD_RECIPE := preload("res://effects/vfx3d/vfxv2/recipes/fireball_standard_v2.tres")
const SILENCE_BOLT_RECIPE := preload("res://effects/vfx3d/vfxv2/recipes/silence_bolt_v2.tres")
const POISON_DART_RECIPE := preload("res://effects/vfx3d/vfxv2/recipes/poison_dart_v2.tres")
const METEOR_STRIKE_RECIPE := preload("res://effects/vfx3d/vfxv2/recipes/meteor_strike_v2.tres")
const SLASH_IMPACT_RECIPE := preload("res://effects/vfx3d/vfxv2/recipes/slash_impact_v2.tres")
const PORTAL_ARRIVAL_RECIPE := preload("res://effects/vfx3d/vfxv2/recipes/portal_arrival_v2.tres")

static func names() -> Array[String]:
	return ["Binbun Original Projectile", "Binbun Original Beam", "Binbun Original Slash", "Binbun Original Portal", "Binbun Original Loot", "Recipe V2: Fire Projectile Combo", "Recipe V2: Loot Burst Combo", "Starter Hit Impact 01", "Starter Hit Impact 02", "Starter Fire", "Starter Explosion", "Starter Ground Smoke", "Starter Ground Smoke Burst", "Starter Muzzle", "Starter Loot Ground 01", "Starter Loot Ground 02", "Demo Magic Orb Flash 03", "Demo Magic Orb Flash 04", "Template: Fireball Full Skill", "Template: Silence Bolt", "Template: Poison Dart", "Template: Meteor Strike", "Template: Slash Impact", "Template: Portal Arrival"]

static func create(index: int) -> Node3D:
	if index >= 18:
		return COMPOSER.new()
	if index >= 7:
		return EXTERNAL.new()
	if index >= 5:
		return COMPOSER.new()
	return BINBUN.new()

static func recipe(index: int) -> VFXRecipeV2:
	match index:
		18: return FIREBALL_STANDARD_RECIPE
		19: return SILENCE_BOLT_RECIPE
		20: return POISON_DART_RECIPE
		21: return METEOR_STRIKE_RECIPE
		22: return SLASH_IMPACT_RECIPE
		23: return PORTAL_ARRIVAL_RECIPE
		6: return LOOT_RECIPE
		_: return FIRE_RECIPE

static func profile(index: int) -> VFXProfile3D:
	var p := VFXProfile3D.new()
	p.profile_id = "vfxv2_%d" % index
	p.module_id = "vfxv2"
	p.size = 1.15
	p.duration = 0.72
	p.particle_count = 28
	p.emission_energy = 4.8
	match index:
		0, 1: p.dark_color = Color(0.01, 0.04, 0.16); p.main_color = Color(0.08, 0.42, 1.0); p.core_color = Color(0.72, 0.98, 1.0)
		2, 3: p.dark_color = Color(0.18, 0.02, 0.01); p.main_color = Color(1.0, 0.18, 0.035); p.core_color = Color(1.0, 0.88, 0.48)
		4: p.dark_color = Color(0.02, 0.14, 0.20); p.main_color = Color(0.10, 0.78, 0.88); p.core_color = Color(0.78, 1.0, 1.0)
		5: p.dark_color = Color(0.08, 0.02, 0.16); p.main_color = Color(0.62, 0.20, 1.0); p.core_color = Color(0.95, 0.70, 1.0)
		6: p.dark_color = Color(0.02, 0.12, 0.07); p.main_color = Color(0.10, 0.90, 0.52); p.core_color = Color(0.72, 1.0, 0.82)
		19: p.dark_color = Color(0.04, 0.01, 0.10); p.main_color = Color(0.42, 0.10, 0.82); p.core_color = Color(0.90, 0.66, 1.0)
		20: p.dark_color = Color(0.02, 0.08, 0.01); p.main_color = Color(0.24, 0.76, 0.06); p.core_color = Color(0.82, 1.0, 0.24)
		21: p.dark_color = Color(0.10, 0.018, 0.004); p.main_color = Color(0.92, 0.16, 0.018); p.core_color = Color(1.0, 0.82, 0.30)
		22: p.dark_color = Color(0.10, 0.018, 0.006); p.main_color = Color(0.92, 0.20, 0.025); p.core_color = Color(1.0, 0.86, 0.42)
		23: p.dark_color = Color(0.02, 0.04, 0.12); p.main_color = Color(0.12, 0.48, 0.92); p.core_color = Color(0.70, 0.94, 1.0)
		_: p.dark_color = Color(0.20, 0.06, 0.01); p.main_color = Color(1.0, 0.46, 0.06); p.core_color = Color(1.0, 0.92, 0.50)
	return p
