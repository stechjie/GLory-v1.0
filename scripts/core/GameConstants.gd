class_name GameConstants
extends RefCounted

const BOARD_ROWS := 4
const BOARD_COLUMNS := 4
const CELL_COUNT := BOARD_ROWS * BOARD_COLUMNS
const NORMAL_UNIT_CAP := 7
const MAX_STAR := 3

# Per-slot player identity colors for 3v3 (slots A,B,C,1,2,3 = 0..5).
# Used in the lobby, the prep ready indicator, and the battle foot rings.
const TEAM_SLOT_COLORS := [
	Color(0.90, 0.27, 0.24),  # A 红
	Color(0.26, 0.56, 0.96),  # B 蓝
	Color(0.30, 0.78, 0.38),  # C 绿
	Color(0.96, 0.80, 0.24),  # 1 黄
	Color(0.66, 0.42, 0.92),  # 2 紫
	Color(0.97, 0.56, 0.20),  # 3 橙
]

static func team_slot_color(slot: int) -> Color:
	if slot >= 0 and slot < TEAM_SLOT_COLORS.size():
		return TEAM_SLOT_COLORS[slot]
	return Color(0.7, 0.7, 0.7)
