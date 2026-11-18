extends Node
## 仅供目检：把正式的伤害牌放大 2.5 倍，逐档截图（常驻特效 + 升档瞬间）。
## 不改玩家设置、战斗数据或正式资源。用法：
##   godot --path . --resolution 1600x720 res://tools/damage_aura_preview.tscn -- --out <新目录>
const HUD := preload("res://effects/runtime/presentation/BattleCombatFeedback.gd")
var _out := ""

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--out":
			_out = ProjectSettings.globalize_path(args[i + 1])
	if _out.is_empty() or DirAccess.dir_exists_absolute(_out):
		push_error("DAMAGE_AURA_PREVIEW requires fresh --out")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var bg := ColorRect.new()
	bg.color = Color("3d5a34")
	bg.size = Vector2(1600, 720)
	add_child(bg)
	var wrapper := Control.new()
	wrapper.size = Vector2(1600, 720)
	wrapper.scale = Vector2.ONE * 2.5
	wrapper.position = Vector2(60, -150)
	add_child(wrapper)
	var hud := HUD.new()
	wrapper.add_child(hud)
	var totals: Array = [9000]
	totals.append_array(HUD.DAMAGE_TIERS)
	for index in range(totals.size()):
		hud.show_damage(int(totals[index]), false, 11)
		# 每档停两个不同时刻，爆点是间歇的，单帧可能正好落在空档
		await get_tree().create_timer(0.75).timeout
		await _capture("tier%d_a" % index)
		await get_tree().create_timer(0.45).timeout
		await _capture("tier%d_b" % index)
	for tier in [2, 4, 6]:
		hud.show_damage(int(HUD.DAMAGE_TIERS[tier - 1]) - 1, false, 11)
		await get_tree().process_frame
		hud.show_damage(int(HUD.DAMAGE_TIERS[tier - 1]), true, 11)
		await get_tree().create_timer(0.10).timeout
		await _capture("promote%d_010" % tier)
		await get_tree().create_timer(0.14).timeout
		await _capture("promote%d_024" % tier)
	print("DAMAGE_AURA_PREVIEW PASS out=%s" % _out)
	get_tree().quit()

func _capture(shot: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join(shot + ".png"))
