extends RefCounted
class_name EffectDatabase

const EFFECT_SCENES := {
	"HIT_MELEE": preload("res://effects/scenes/hit_melee.tscn"),
	"HIT_RANGED": preload("res://effects/scenes/hit_ranged.tscn"),
	"DEATH_EXPLOSION": preload("res://effects/scenes/death_explosion.tscn"),
	"PROJECTILE_ARROW": preload("res://effects/projectiles/projectile_arrow.tscn"),
	"PROJECTILE_MAGIC": preload("res://effects/projectiles/projectile_magic.tscn"),
	"HOLY_HEAL": preload("res://effects/scenes/holy_heal.tscn"),
	"HOLY_SHIELD": preload("res://effects/scenes/holy_shield.tscn"),
	"LIGHTNING_STRIKE": preload("res://effects/scenes/lightning_strike.tscn"),
	"DARK_EXPLOSION": preload("res://effects/scenes/dark_explosion.tscn"),
	"BLACK_HOLE": preload("res://effects/scenes/black_hole.tscn"),
	"TELEPORT_SLASH": preload("res://effects/scenes/teleport_slash.tscn"),
	"SOUL_CHAIN": preload("res://effects/scenes/soul_chain.tscn"),
	"GROWTH_AURA": preload("res://effects/scenes/growth_aura.tscn"),
	"FEAR_SKULL": preload("res://effects/scenes/fear_skull.tscn"),
	"POISON_CLOUD": preload("res://effects/scenes/poison_cloud.tscn"),
	"STUN_RING": preload("res://effects/scenes/stun_ring.tscn"),
	"SKILL_TEXTURE": preload("res://effects/scenes/skill_texture_vfx.tscn")
}

static func get_scene(vfx_id: String) -> PackedScene:
	return EFFECT_SCENES.get(vfx_id, null)