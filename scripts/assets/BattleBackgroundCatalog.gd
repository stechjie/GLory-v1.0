extends RefCounted

# Explicit paths let the slim-build dependency scanner retain every variant.
# Keep paths as strings: only the selected background is loaded into memory.
const GRASS := [
	"res://assets/board/2_5d/battlefield_jungle_pve.png",
	"res://assets/board/2_5d/courtyard_grass.png",
	"res://assets/board/2_5d/fortress_grass.png",
	"res://assets/board/2_5d/sanctuary_grass.png",
]
const SNOW := [
	"res://assets/board/2_5d/battlefield_snow_pvp.png",
	"res://assets/board/2_5d/courtyard_snow.png",
	"res://assets/board/2_5d/fortress_snow.png",
	"res://assets/board/2_5d/sanctuary_snow.png",
]
const FINAL := "res://assets/board/2_5d/battlefield_final_round.png"

static func path_for(kind: String, round_index: int, final_round: int, match_key: String) -> String:
	# Final replays can carry kind=pvp; round number must take precedence.
	if round_index == final_round or kind == "final":
		return FINAL
	var pool: Array = SNOW if kind == "pvp" else GRASS
	var rng := RandomNumberGenerator.new()
	rng.seed = ("battle-background-v1|%s|%d" % [match_key, round_index]).hash()
	return pool[rng.randi_range(0, pool.size() - 1)]
