class_name GameConstants
extends RefCounted

const BOARD_ROWS := 4
const BOARD_COLUMNS := 4
const CELL_COUNT := BOARD_ROWS * BOARD_COLUMNS
const NORMAL_UNIT_CAP := 7
const MAX_STAR := 3

# 升星所需份数：1 星要 2 个同名同星，2 星要 3 个。
#
# 放在这里而不是 GameState，是因为**服务端账本也要用**。
# EconomyLedger 的设计原则明确写着「不读 GameState」——
# 那条原则防的是全局可变状态串房间，而这里是纯常量，不涉及任何房间状态。
#
# 之前这张表只有客户端有（GameState），服务端账本写的是一个平坦的
# `STAR_UPGRADE_COPIES := 2`，于是：
#   * 2 个二星在服务端就能换一个三星（客户端要 3 个）—— 白捡一个单位
#   * 客户端合法的「3 个二星升三星」在服务端反而被拒（bad_merge_count）
const STAR_UPGRADE_COPIES := {1: 2, 2: 3}

# 星级不在表里时返回 3 —— 保守取大值。返回小值意味着"更容易升星"，
# 而这是漏配时最不该发生的方向。
static func copies_to_upgrade(star: int) -> int:
	return int(STAR_UPGRADE_COPIES.get(star, 3))

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
