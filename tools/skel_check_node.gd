extends Node

# 验证「三个动作 FBX 能否合成一套 mesh + 三条动画」。
#
# 走 Godot 的 Import As: Animation Library 这条路的前提是：
#   1. 三个 FBX 里的 Skeleton3D 骨骼名单完全一致（动画轨道按骨骼名寻址）
#   2. 层级（每根骨头的父节点）一致
#   3. rest pose 一致 —— 不一致的话动画套上去会变形，得走 retarget
#   4. Skeleton3D 在场景里的相对路径一致（轨道 NodePath 要对得上）
# 任何一条不满足，就只能走 Blender 重导出。

func _ready() -> void:
	var units := _collect_units()
	print("[SKEL] 待检查单位 %d 个" % units.size())
	var ok := 0
	var bad := 0
	var detail: Array[String] = []
	for id in units:
		var actions: Dictionary = units[id]
		var res := _check_unit(str(id), actions)
		if res.is_empty():
			continue
		if bool(res.get("ok", false)):
			ok += 1
		else:
			bad += 1
			detail.append("%s: %s" % [id, str(res.get("why", ""))])
	print("[SKEL] ===== 骨骼一致 %d 个，不一致 %d 个 =====" % [ok, bad])
	for d in detail:
		print("[SKEL]   x %s" % d)
	get_tree().quit()


# 从 42 个空壳脚本里读出 ACTION_SCENES
func _collect_units() -> Dictionary:
	var out := {}
	for base in ["res://assets/models/units", "res://assets/models/mercenaries",
			"res://assets/models/bosses", "res://assets/models/allies",
			"res://assets/models/monsters"]:
		for p in _walk(base):
			if not p.ends_with(".tscn"):
				continue
			for d in ResourceLoader.get_dependencies(p):
				var dp: String = d.split("::")[-1]
				if not dp.ends_with(".gd"):
					continue
				var sc := ResourceLoader.load(dp) as GDScript
				if sc == null:
					break
				var cm: Dictionary = sc.get_script_constant_map()
				if cm.has("ACTION_SCENES"):
					var acts: Dictionary = cm["ACTION_SCENES"]
					if acts.size() >= 2:
						out[p.get_file().get_basename()] = acts
				break
	return out


func _check_unit(id: String, actions: Dictionary) -> Dictionary:
	var sigs := {}
	for key in actions:
		var path := str(actions[key])
		if not ResourceLoader.exists(path):
			return {"ok": false, "why": "FBX 不存在 %s" % path.get_file()}
		var ps := ResourceLoader.load(path) as PackedScene
		if ps == null:
			return {"ok": false, "why": "FBX 加载失败 %s" % path.get_file()}
		var root := ps.instantiate()
		var skel := _find_skeleton(root)
		if skel == null:
			sigs[key] = {"none": true, "path": ""}
			root.queue_free()
			continue
		var names: Array[String] = []
		var parents: Array[int] = []
		var rests: Array[String] = []
		for i in skel.get_bone_count():
			names.append(skel.get_bone_name(i))
			parents.append(skel.get_bone_parent(i))
			var t := skel.get_bone_rest(i)
			rests.append("%.4f,%.4f,%.4f" % [t.origin.x, t.origin.y, t.origin.z])
		sigs[key] = {
			"count": skel.get_bone_count(),
			"names": "|".join(names),
			"parents": str(parents),
			"rests": "|".join(rests),
			"path": str(root.get_path_to(skel)),
		}
		root.queue_free()

	var keys := sigs.keys()
	if keys.size() < 2:
		return {}
	var ref_key = keys[0]
	var ref: Dictionary = sigs[ref_key]
	if ref.get("none", false):
		return {"ok": false, "why": "%s 里没有 Skeleton3D" % ref_key}
	for k in keys.slice(1):
		var s: Dictionary = sigs[k]
		if s.get("none", false):
			return {"ok": false, "why": "%s 里没有 Skeleton3D" % k}
		if s["count"] != ref["count"]:
			return {"ok": false, "why": "骨骼数不同 %s=%d vs %s=%d" % [ref_key, ref["count"], k, s["count"]]}
		if s["names"] != ref["names"]:
			return {"ok": false, "why": "骨骼名单不同（%s vs %s）" % [ref_key, k]}
		if s["parents"] != ref["parents"]:
			return {"ok": false, "why": "骨骼层级不同（%s vs %s）" % [ref_key, k]}
		if s["rests"] != ref["rests"]:
			return {"ok": false, "why": "rest pose 不同（%s vs %s）—— 需要 retarget" % [ref_key, k]}
		if s["path"] != ref["path"]:
			return {"ok": false, "why": "Skeleton3D 路径不同 %s=%s vs %s=%s" % [ref_key, ref["path"], k, s["path"]]}
	print("[SKEL] OK %-32s 骨骼 %d 根, 路径 %s, 动作 %d 个" % [id, ref["count"], ref["path"], keys.size()])
	return {"ok": true}


func _find_skeleton(n: Node) -> Skeleton3D:
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is Skeleton3D:
			return cur as Skeleton3D
		for c in cur.get_children():
			stack.append(c)
	return null


func _walk(d: String) -> Array[String]:
	var out: Array[String] = []
	var stack: Array[String] = [d]
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		var dir := DirAccess.open(cur)
		if dir == null:
			continue
		for nm in dir.get_directories():
			stack.append(cur + "/" + nm)
		for nm in dir.get_files():
			if nm.ends_with(".tscn"):
				out.append(cur + "/" + nm)
	return out
