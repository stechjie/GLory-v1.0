extends Node
# 资料页的离线预览。**不连后端** —— 注入一份假数据直接渲染两种模式，
# 用来看排版、看两种模式的差异，也用来出截图给产品看。
#
# 与 UnitActorReview / BoardReadabilityReview 同类：审查用，不进玩家路径。
#
# 跑（会开窗口）：
#   Godot_v4.7.1-stable_win64.exe --path . scenes/debug/ProfileScreenReview.tscn \
#       --resolution 1280x900 -- --shot=self
#   ... -- --shot=public
#
# 不带 --shot 就只是开着让人手动看。

const PROFILE_SCENE := "res://scenes/menu/ProfileScreen.tscn"
const OUT_DIR := "res://reports"

# 假数据。字段名必须与后端 SelfProfileResponse / PublicProfileResponse 一致 ——
# 对不上的话这个预览就会在骗人。
const FAKE_SELF := {
	"friend_code": "7K2M9Q4B",
	"player_name": "Leno",
	"avatar": "preset:avatar_005",
	"avatar_frame": "preset:frame_default",
	"showcase_pet": "pet_rabbit",
	"days_since_created": 128,
	"gender": "male",
	"birth_month": 3,
	"birth_day": 14,
	"region": "MY",
	"signature": "今天也要加油",
	"gender_visibility": "public",
	"birth_visibility": "public",
	"region_visibility": "public",
	"rename_available_at": null,
}
# 公开视图：性别与生日被对方设成了不显示，所以**这两个键根本不存在** ——
# 不是值为 null。后端就是这么发的，预览必须照着模拟，否则看不出真实效果。
const FAKE_PUBLIC := {
	"friend_code": "7K2M9Q4B",
	"player_name": "Leno",
	"avatar": "preset:avatar_005",
	"avatar_frame": "preset:frame_default",
	"showcase_pet": "pet_rabbit",
	"days_since_created": 128,
	"region": "MY",
	"signature": "今天也要加油",
}

# 全新玩家的真实状态：什么都没填，可空字段全是 JSON null。
# **这是最该看的一张** —— 第一版就是在这个状态下把 "<null>" 画到界面上的。
const FAKE_EMPTY := {
	"friend_code": "P4X7T2WD",
	"player_name": "Player",
	"avatar": "preset:avatar_001",
	"avatar_frame": "preset:frame_default",
	"showcase_pet": null,
	"days_since_created": 1,
	"gender": null,
	"birth_month": null,
	"birth_day": null,
	"region": null,
	"signature": null,
	"gender_visibility": "public",
	"birth_visibility": "public",
	"region_visibility": "public",
	"rename_available_at": null,
}

var _shot := ""

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot = arg.substr("--shot=".length())
	_run()

func _run() -> void:
	var public := _shot == "public"
	var screen := (load(PROFILE_SCENE) as PackedScene).instantiate() as Control
	if public:
		screen.call("configure_public", "7K2M9Q4B")
	else:
		screen.call("configure_self")
	add_child(screen)

	# _ready 里的 _load() 会立刻拿到 401（没登录，_request 本地就判掉了）。
	# 等它走完再注入，否则状态行会把我们的数据盖掉。
	await get_tree().process_frame
	await get_tree().process_frame
	var payload := FAKE_SELF
	if public:
		payload = FAKE_PUBLIC
	elif _shot == "empty":
		payload = FAKE_EMPTY
	screen.set("_data", payload)
	screen.call("_set_status", "")
	screen.call("_refresh")

	if _shot.is_empty():
		return
	# 等一帧让布局落定再截。
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/profile_%s.png" % [OUT_DIR, _shot]
	var err := image.save_png(path)
	print("PROFILE_SHOT path=%s err=%d" % [path, err])
	get_tree().quit(0 if err == OK else 1)
