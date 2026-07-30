class_name BattleAssetService
extends RefCounted

# 战斗资源的统一加载与所有权管理。
#
# 解决三个实测问题：
#
# 1) 预取与释放互相对冲
#    以前按「是不是玩家阵容」二分：回合末把所有非玩家资源清掉。但备战期为未来
#    3 轮预取的怪同样不属于玩家阵容，于是每回合结束都把刚预取好的扔掉，下回合
#    重新加载。实测每轮战斗中仍现加载 96–426 MB 贴图。
#    改成 owner/lease：一个资源只要还有任一 owner 就不释放。
#
# 2) 备战棋盘和战斗各有一套缓存
#    PrepBoardModels 有 _prep_model_scene_cache，BattleUI 有 _model_scene_cache，
#    互不知情 —— 同一个模型加载两遍。实测放下第一个棋子冻结 3.3 秒（tex +11.1 MB）。
#    两边统一走这里。
#
# 3) 缓存随场景销毁
#    Main._show_battle() 每回合重建 BattleScreen，实例变量缓存跟着没。这里全部
#    static，跨场景存活。
#
# 所有权约定：
#   OWNER_PLAYER      玩家阵容，整局持有
#   OWNER_BATTLE      本回合正在打的内容，回合末释放
#   owner_future(n)   为第 n 轮预取，等真打到那轮转成 OWNER_BATTLE 后才放

const OWNER_PLAYER := "run/player"
const OWNER_BATTLE := "battle/current"

static func owner_future(round_index: int) -> String:
	return "future/round/%d" % round_index

static var _scenes: Dictionary = {}      # path -> PackedScene
static var _owners: Dictionary = {}      # path -> { owner: true }
static var _requested: Dictionary = {}   # path -> true（线程请求已发出，尚未收割）

# --- 所有权 -------------------------------------------------------------------

# 声明「我要用这个资源」。未加载则发起后台加载（不阻塞）。
static func acquire(path: String, owner: String) -> void:
	if path.is_empty() or owner.is_empty():
		return
	var set: Dictionary = _owners.get_or_add(path, {})
	set[owner] = true
	if _scenes.has(path) or _requested.has(path):
		return
	if not ResourceLoader.exists(path):
		return
	if ResourceLoader.load_threaded_request(path) == OK:
		_requested[path] = true

static func acquire_many(paths: Array, owner: String) -> void:
	for p in paths:
		acquire(str(p), owner)

# 摘掉某个 owner。owner 全空的资源才真正释放。
static func release_owner(owner: String) -> int:
	var freed := 0
	for path in _owners.keys():
		var set: Dictionary = _owners[path]
		if not set.has(owner):
			continue
		set.erase(owner)
		if not set.is_empty():
			continue
		_owners.erase(path)
		_scenes.erase(path)
		_requested.erase(path)
		freed += 1
	return freed

# 未来回合真打到了：把 future/round/N 转成 battle/current，资源全程不落地。
static func promote_future_to_battle(round_index: int) -> void:
	var from := owner_future(round_index)
	for path in _owners.keys():
		var set: Dictionary = _owners[path]
		if set.has(from):
			set.erase(from)
			set[OWNER_BATTLE] = true

# --- 取用 ---------------------------------------------------------------------

# 备战棋盘和战斗都走这里。命中缓存 = 纯字典查找。
static func get_scene(path: String) -> PackedScene:
	if path.is_empty():
		return null
	var cached: PackedScene = _scenes.get(path)
	if cached != null:
		_stat_hit += 1
		return cached
	# 后台请求已完成就直接收割，比再起一次冷读便宜得多。
	if _requested.has(path):
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			var got := ResourceLoader.load_threaded_get(path) as PackedScene
			_requested.erase(path)
			if got != null:
				_scenes[path] = got
			_stat_harvest += 1
			return got
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			# 还在加载中就同步等 —— **这条会阻塞主线程**，是预取漏掉时的兜底。
			var t0 := Time.get_ticks_usec()
			var got2 := ResourceLoader.load_threaded_get(path) as PackedScene
			var us := Time.get_ticks_usec() - t0
			_requested.erase(path)
			if got2 != null:
				_scenes[path] = got2
			_stat_wait += 1
			_stat_block_us += us
			if us > 50000:
				print("[ASSET] 阻塞等待 %.0fms  %s" % [us / 1000.0, path.get_file()])
			return got2
		_requested.erase(path)
	if not ResourceLoader.exists(path):
		return null
	# 完全没预取到：整段同步读盘。这是最贵的一条路，必须能看见。
	var t1 := Time.get_ticks_usec()
	var packed := load(path) as PackedScene
	var cold_us := Time.get_ticks_usec() - t1
	_stat_cold += 1
	_stat_block_us += cold_us
	if cold_us > 50000:
		print("[ASSET] 冷加载 %.0fms  %s" % [cold_us / 1000.0, path.get_file()])
	if packed != null:
		_scenes[path] = packed
		_owners.get_or_add(path, {})[OWNER_BATTLE] = true
	return packed

# --- 统计：区分「命中缓存」和「阻塞主线程」------------------------------------
#
# 之前用「战斗中贴图涨幅」当验收指标是错的：实测有一轮涨了 277 MB 却完全不卡
# （后台线程加载不阻塞主线程）。真正该盯的是下面这两个 —— 走了同步路径几次、
# 总共堵了多久。
static var _stat_hit := 0        # 命中缓存，零成本
static var _stat_harvest := 0    # 后台已完成，直接收割，便宜
static var _stat_wait := 0       # 后台还在跑，同步等 —— 阻塞
static var _stat_cold := 0       # 完全没预取，整段冷读 —— 最贵
static var _stat_block_us := 0

static func stats_line() -> String:
	return "hit=%d harvest=%d wait=%d cold=%d 阻塞合计=%.0fms" % [
		_stat_hit, _stat_harvest, _stat_wait, _stat_cold, _stat_block_us / 1000.0]

static func reset_stats() -> void:
	_stat_hit = 0
	_stat_harvest = 0
	_stat_wait = 0
	_stat_cold = 0
	_stat_block_us = 0

# --- 进度 ---------------------------------------------------------------------

# 逐帧调用：收割已完成的，返回还剩几个在加载。读条靠这个数字走。
static func harvest() -> int:
	var pending := 0
	for path in _requested.keys():
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			var got := ResourceLoader.load_threaded_get(path) as PackedScene
			if got != null:
				_scenes[path] = got
			_requested.erase(path)
		elif st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			pending += 1
		else:
			_requested.erase(path)   # 失败的不要一直挂着
	return pending

static func pending_count() -> int:
	return _requested.size()

static func cached_count() -> int:
	return _scenes.size()

# 整局结束时叫一次，别让上一局的阵容留到下一局。
static func reset_run() -> void:
	_scenes.clear()
	_owners.clear()
	_requested.clear()
