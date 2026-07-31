extends SceneTree

# 7 个骨骼数不一致的角色，逐个判断能不能照 67 个那样合并。
# 判据不是「骨骼数是否相等」，而是「attack/run 动画用到的每一根骨骼，
# idle 的骨架里是不是都有」——多出来的骨骼只要没被动画引用就无所谓。

const CHARS := {
	"pets/pet_rabbit": ["pet_rabbit_attack.fbx", "pet_rabbit_run.fbx"],
	"allies/formation_ally_2_animated": ["idle.fbx", "attack.fbx", "run.fbx"],
	"allies/formation_ally_4_animated": ["idle.fbx", "attack.fbx", "run.fbx"],
	"allies/formation_ally_5_animated": ["idle.fbx", "attack.fbx", "run.fbx"],
	"allies/abyss_beast_animated": ["idle.fbx", "attack.fbx", "run.fbx"],
	"units/dark_doom_animated": ["dark_doom_idle.fbx", "dark_doom_attack.fbx", "dark_doom_run.fbx"],
	"units/god_arbiter_animated": ["god_arbiter_idle.fbx", "god_arbiter_attack.fbx", "god_arbiter_run.fbx"],
}

func _init() -> void:
	for dir in CHARS.keys():
		var files: Array = CHARS[dir]
		var base := "res://assets/models/%s/%s" % [dir, files[0]]
		var idle_bones := _bones_of(base)
		if idle_bones.is_empty():
			print("%-38s idle 读不到骨架（%s）" % [dir.get_file(), files[0]])
			continue
		var verdict := "可合并"
		var detail: Array[String] = []
		for i in range(1, files.size()):
			var other := "res://assets/models/%s/%s" % [dir, files[i]]
			var missing = _missing_bones(other, idle_bones)
			if missing == null:
				detail.append("%s 读不到" % files[i]); verdict = "需人工"
			elif not missing.is_empty():
				detail.append("%s 引用了 idle 没有的骨骼 %d 根: %s" % [
					files[i], missing.size(), ", ".join(missing.slice(0, 4))])
				verdict = "需人工"
		print("%-38s idle骨骼=%-4d %s" % [dir.get_file(), idle_bones.size(), verdict])
		for d in detail:
			print("      " + d)
	quit(0)

func _bones_of(path: String) -> Dictionary:
	var out := {}
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null: return out
	var root := scene.instantiate()
	var skel := _find(root, "Skeleton3D") as Skeleton3D
	if skel != null:
		for i in skel.get_bone_count():
			out[skel.get_bone_name(i)] = true
	root.free()
	return out

# 返回 null 表示读不到；返回空数组表示动画用到的骨骼 idle 全都有。
func _missing_bones(path: String, idle_bones: Dictionary):
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null: return null
	var root := scene.instantiate()
	var player := _find(root, "AnimationPlayer") as AnimationPlayer
	if player == null:
		root.free(); return null
	var missing := {}
	for name in player.get_animation_list():
		if String(name).to_lower() == "reset": continue
		var anim := player.get_animation(name)
		for t in anim.get_track_count():
			var p := String(anim.track_get_path(t))
			var bone := p.get_slice(":", 1)
			if bone.is_empty() or not p.contains("Skeleton3D"): continue
			if not idle_bones.has(bone):
				missing[bone] = true
	root.free()
	return missing.keys()

func _find(node: Node, cls: String) -> Node:
	if node.get_class() == cls: return node
	for c in node.get_children():
		var f := _find(c, cls)
		if f != null: return f
	return null
