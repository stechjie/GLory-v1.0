extends Node

# 守住 Main.gd 里那几个界面场景「确实加载得起来」。
#
# 为什么需要它：这些路径原本是 preload()，而 preload 会在脚本**加载时**解析 ——
# 路径错了或场景坏了，Main.gd 直接编译不过，等于有一道免费的编译期保证。
# 2026-08-28 为了把引擎启动从 ~3181 ms 降到 ~1655 ms，这 8 处改成了运行时 load()
# （详见 Main.gd 里 _load_screen 上方的注释），那道保证也就没了：路径写错会变成
# 玩家点开某个界面时才炸，而且是在 null 上 .instantiate()。
#
# 所以把它换成一道门禁。这里比原来的 preload **更严**：
#   * 路径存在（asset_manifest_check 也管这一层）
#   * load() 真能返回资源，不是 null —— 场景内部依赖坏掉时 asset_manifest 看不出来
#   * 拿到的是 PackedScene，不是别的资源
#   * can_instantiate() 为真
#
# 路径不写死，从 Main.gd 源码里现扫。写死的话，以后加一个新界面就漏一个 ——
# 而漏掉的那个正是没人测过的那个。
#
# 刻意**不**真的 instantiate()：preload 当初保证的也只是「资源能加载」。
# PrepScreen 这类界面脱离宿主实例化会有自己的副作用，那是 panel_scene_check
# 那类检查的范围，不该混进来。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "main_screen_scenes"

const MAIN_PATH := "res://scenes/main/Main.gd"
# Main.gd 里用来取界面场景的两个 helper。
const LOADER_MARKERS: PackedStringArray = ["_instantiate_screen(", "_load_screen("]
# 少于这个数就说明扫描逻辑失效了（helper 改名、路径改成拼接等），
# 而不是「界面变少了」。空检查集比红灯更危险。
const MIN_EXPECTED_SCREENS := 6

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var source := FileAccess.get_file_as_string(MAIN_PATH)
	if not _h.expect(not source.is_empty(), "main_unreadable", "读不到 %s" % MAIN_PATH):
		_h.finish(get_tree())
		return

	var paths := _screen_paths(source)
	_h.expect(paths.size() >= MIN_EXPECTED_SCREENS,
		"too_few_screens",
		"只从 Main.gd 扫到 %d 个界面场景（至少应有 %d）—— 多半是 helper 改名或路径改成了拼接，扫描逻辑已失效"
			% [paths.size(), MIN_EXPECTED_SCREENS])

	for path_value in paths:
		var path := str(path_value)
		if not _h.expect(ResourceLoader.exists(path), "screen_missing",
				"Main.gd 引用的界面场景不存在：%s" % path):
			continue
		var res: Resource = ResourceLoader.load(path)
		if not _h.expect(res != null, "screen_load_null",
				"load() 返回 null：%s —— 玩家点开这个界面时会在 null 上 instantiate 崩掉" % path):
			continue
		var scene := res as PackedScene
		if not _h.expect(scene != null, "screen_not_packed_scene",
				"%s 不是 PackedScene，而是 %s" % [path, res.get_class()]):
			continue
		_h.expect(scene.can_instantiate(), "screen_not_instantiable",
			"PackedScene 无法实例化：%s" % path)

	_h.note("从 Main.gd 扫到 %d 个界面场景：%s" % [paths.size(), ", ".join(paths)])
	_check_helpers_still_guard_null(source)
	_h.finish(get_tree())


# 从 helper 调用里取出字符串字面量参数。只认第一个参数是字面量的写法 ——
# 拼接出来的路径本来就没法静态校验，硬取会拿到半截前缀然后误报。
func _screen_paths(source: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for raw_line in source.split("\n"):
		var line := str(raw_line)
		if line.strip_edges().begins_with("#"):
			continue
		for marker_value in LOADER_MARKERS:
			var marker := str(marker_value)
			var from := 0
			while true:
				var at := line.find(marker, from)
				if at < 0:
					break
				from = at + marker.length()
				if from >= line.length() or line.substr(from, 1) != "\"":
					continue
				var end := line.find("\"", from + 1)
				if end < 0:
					continue
				var path := line.substr(from + 1, end - from - 1)
				if path.begins_with("res://") and not out.has(path):
					out.append(path)
	return out


# helper 存在的全部意义就是把 null 变成一条指名道姓的错误。
# 哪天有人把 push_error 删了，这道门禁就退化成只测「场景能加载」，
# 而运行时又变回静默的 null 崩溃。
func _check_helpers_still_guard_null(source: String) -> void:
	var at := source.find("func _load_screen(")
	if not _h.expect(at >= 0, "helper_missing",
			"Main.gd 里找不到 _load_screen() —— 界面加载又绕开了统一入口"):
		return
	var body := source.substr(at, 400)
	_h.expect(body.contains("push_error"),
		"helper_no_error",
		"_load_screen() 不再对 null 报错 —— 路径写错会退回成静默的 null 崩溃")
