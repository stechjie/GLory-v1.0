extends RefCounted
class_name VFXQualityBudget

enum Tier { LOW, MEDIUM, HIGH }

static var tier := Tier.MEDIUM

static func allow_dynamic_light() -> bool:
	return tier != Tier.LOW

static func flipbook_frame_limit(base_count: int) -> int:
	return mini(base_count, 12 if tier == Tier.LOW else (24 if tier == Tier.MEDIUM else 48))

static func distortion_layers(base_count: int) -> int:
	return mini(base_count, 1 if tier == Tier.LOW else (2 if tier == Tier.MEDIUM else 3))

static func max_simultaneous_effects() -> int:
	return 18 if tier == Tier.LOW else (30 if tier == Tier.MEDIUM else 48)

static func max_particles_per_effect() -> int:
	return 48 if tier == Tier.LOW else (96 if tier == Tier.MEDIUM else 160)

static func particle_count(base_count: int) -> int:
	match tier:
		Tier.LOW:
			return maxi(4, int(round(base_count * 0.52)))
		Tier.HIGH:
			return maxi(4, int(round(base_count * 1.25)))
		_:
			return maxi(4, base_count)

static func auxiliary_layers(base_count: int) -> int:
	match tier:
		Tier.LOW:
			return mini(base_count, 1)
		Tier.HIGH:
			return base_count
		_:
			return mini(base_count, 2)

static func shader_octaves(base_count: int) -> int:
	match tier:
		Tier.LOW:
			return mini(base_count, 3)
		Tier.HIGH:
			return base_count
		_:
			return mini(base_count, 5)
