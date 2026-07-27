class_name GameConstants
extends RefCounted

const BOARD_ROWS := 4
const BOARD_COLUMNS := 4
const CELL_COUNT := BOARD_ROWS * BOARD_COLUMNS
const NORMAL_UNIT_CAP := 7
const MAX_STAR := 3

# Per-slot player identity colors for 3v3 (slots A,B,C,1,2,3 = 0..5).
# Used in the lobby, the prep ready indicator, and the battle foot rings.
# Blue sits on slot 3 rather than slot 1 so no identity color collides with the
# color of the OTHER team (see TEAM_COLORS below).
const TEAM_SLOT_COLORS := [
	Color(0.90, 0.27, 0.24),  # A 红
	Color(0.96, 0.80, 0.24),  # B 黄
	Color(0.30, 0.78, 0.38),  # C 绿
	Color(0.26, 0.56, 0.96),  # 1 蓝
	Color(0.66, 0.42, 0.92),  # 2 紫
	Color(0.97, 0.56, 0.20),  # 3 橙
]

static func team_slot_color(slot: int) -> Color:
	if slot >= 0 and slot < TEAM_SLOT_COLORS.size():
		return TEAM_SLOT_COLORS[slot]
	return Color(0.7, 0.7, 0.7)

# --- 3v3 队伍归属 ---
# 上排 A/B/C（槽位 0-2）= 红队，下排 1/2/3（槽位 3-5）= 蓝队。
#
# slot 是队伍归属和身份色的唯一真相来源，两者都必须现算，绝不另存一份：断线重连
# 是按 token -> slot 恢复座位的（NetworkService._token_seat），只要一切都从 slot
# 推导，玩家回来必然还在同一队、同一个颜色。存一份就多一个会漂移的真相来源。
const TEAM_RED := 0
const TEAM_BLUE := 1
const TEAM_SIDE_SIZE := 3
const TEAM_COLORS := [
	Color(0.88, 0.24, 0.22),  # 红队
	Color(0.24, 0.52, 0.94),  # 蓝队
]

# 未入座（slot < 0）按红队处理，跟收敛前各处 `0 if slot < 3 else 1` 的行为一致。
static func team_of_slot(slot: int) -> int:
	return TEAM_BLUE if slot >= TEAM_SIDE_SIZE else TEAM_RED

static func team_color(team: int) -> Color:
	if team >= 0 and team < TEAM_COLORS.size():
		return TEAM_COLORS[team]
	return Color(0.7, 0.7, 0.7)

static func team_color_of_slot(slot: int) -> Color:
	return team_color(team_of_slot(slot))

# 该队伍的首个槽位（红队 0、蓝队 3）。
static func team_first_slot(team: int) -> int:
	return TEAM_SIDE_SIZE if team == TEAM_BLUE else 0
