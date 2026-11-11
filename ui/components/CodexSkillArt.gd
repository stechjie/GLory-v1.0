extends RefCounted
# Five preloaded atlases keep export dependency discovery explicit.
const ATLASES := {
	"god": preload("res://assets/ui/codex/painted/skills_god.png"),
	"human": preload("res://assets/ui/codex/painted/skills_human.png"),
	"dark": preload("res://assets/ui/codex/painted/skills_dark.png"),
	"undead": preload("res://assets/ui/codex/painted/skills_undead.png"),
	"crimson": preload("res://assets/ui/codex/painted/skills_crimson.png"),
}
const UNITS := {
	"god": ["god_priest", "god_priestess", "god_guard", "god_aurora", "god_angel", "god_arbiter", "god_archangel", "god_king"],
	"human": ["human_militia", "human_merchant", "human_archer", "human_swordsman", "human_mage", "human_cleric", "human_death_servant", "human_king"],
	"dark": ["dark_imp", "dark_mage", "dark_fear", "dark_queen", "dark_scythe", "dark_suc", "dark_doom", "dark_dragon"],
	"undead": ["undead_small", "undead_poison", "undead_parasite", "undead_spike", "undead_fly", "undead_bomb", "undead_titan", "undead_mother"],
	"crimson": ["crimson", "dancer", "drumer", "hunter", "armbreaker", "Icey", "skypierce", "lattern"],
}
static var _cache: Dictionary = {}

static func for_entry(entry: Dictionary) -> Texture2D:
	var raw: Dictionary = entry.get("raw", {})
	var id := str(entry.get("id", raw.get("id", "")))
	if _cache.has(id):
		return _cache[id]
	for race: String in UNITS:
		var slot: int = UNITS[race].find(id)
		if slot < 0:
			continue
		var source: Texture2D = ATLASES[race]
		var cell := Vector2(source.get_width() / 4.0, source.get_height() / 2.0)
		var texture := AtlasTexture.new()
		texture.atlas = source
		# Transparent gutters isolate filtering; crop only through AtlasTexture, not source pixels.
		texture.region = Rect2(Vector2(slot % 4, slot / 4) * cell + cell * 0.065, cell * 0.87)
		texture.filter_clip = true
		_cache[id] = texture
		return texture
	return null

