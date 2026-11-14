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
# Materials named by wrapper scripts are runtime dependencies, not PackedScene
# dependencies. Retain them with the same lease so an unbought visible offer
# does not lose its warmed textures as soon as the loading screen disappears.
static var _runtime_resources: Dictionary = {}
static var _owners: Dictionary = {}      # path -> { owner: true }
static var _requested: Dictionary = {}   # path -> true（线程请求已发出，尚未收割）
# 排队等发出的后台请求（按先来后到）。见下面 MAX_IN_FLIGHT。
static var _queue: Array[String] = []

# 同时在后台加载的资源最多几个。🔴 **必须是 1。**
#
# 2026-11-14 实测：全新电脑（没有 shader 缓存）进自定义房间，大厅预载一口气发出 61 个
# load_threaded_request，Godot 把它们摊到十几个工作线程上同时跑。带脚本的单位
# （神族祭司 / 女祭司 / 光环，脚本互相 extends、preload）在多个线程里同时编译时互相等待，
# 整个进程死锁：CPU 0%、窗口「未响应」、永远不恢复。开发机有 shader 缓存，每个资源加载很快，
# 线程刚好错开，所以一直没被发现；两台测试电脑 + 本机清空缓存后都 100% 复现。
# 一次只跑一个，线程之间就没有可以互相等的对象。代价是预载变成串行、慢电脑上多花几秒 ——
# 大厅本来就在等人；没加载完的由 PrepScreen 读条兜底（同 FrameResourceLoader 的做法）。
const MAX_IN_FLIGHT := 1

# --- 所有权 -------------------------------------------------------------------

# 声明「我要用这个资源」。未加载则发起后台加载（不阻塞）。
static func acquire(path: String, owner: String) -> void:
	if path.is_empty() or owner.is_empty():
		return
	var set: Dictionary = _owners.get_or_add(path, {})
	set[owner] = true
	if _scenes.has(path) or _requested.has(path) or _queue.has(path):
		return
	if not ResourceLoader.exists(path):
		return
	# 不直接发请求：排队，由 _pump() 按 MAX_IN_FLIGHT 一个一个发（理由见 MAX_IN_FLIGHT）。
	_queue.append(path)
	_pump()


# 有空位就从队列里发下一个后台请求。acquire / harvest / get_scene 都会调。
static func _pump() -> void:
	while _requested.size() < MAX_IN_FLIGHT and not _queue.is_empty():
		var next: String = _queue.pop_front()
		if _scenes.has(next) or _requested.has(next):
			continue
		if ResourceLoader.load_threaded_request(next) == OK:
			_requested[next] = true

static func acquire_many(paths: Array, owner: String) -> void:
	for p in paths:
		acquire(str(p), owner)


# 还在排队或后台加载中（没加载完、也没失败）。
# 🔴 判断「加载失败」的地方必须先问这个：还在排队的资源从来没发过线程请求，
# ResourceLoader.load_threaded_get_status 会答 INVALID_RESOURCE —— 看起来像失败，其实只是没轮到。
static func is_pending(path: String) -> bool:
	return _queue.has(path) or _requested.has(path)


# 马上就要用的资源插到队伍最前面（战斗开打前、备战读条时）。不改所有权；已经加载好、
# 或者正在加载的不受影响。没有这一步，本回合的模型会排在大厅预载 / 未来回合预取后面，
# 慢电脑上等不到 BattleScreen 的 15 秒期限 —— 那会判负、不结算金币。
static func prioritize(paths: Array) -> void:
	var front: Array[String] = []
	for raw_path in paths:
		var path := str(raw_path)
		if _queue.has(path):
			_queue.erase(path)
			front.append(path)
	if front.is_empty():
		return
	front.append_array(_queue)
	_queue = front
	_pump()

# Adopt an already completed background load without requesting or waiting again.
static func retain_ready_resource(path: String, resource: Resource, owner: String) -> void:
	if path.is_empty() or resource == null or owner.is_empty():
		return
	_owners.get_or_add(path, {})[owner] = true
	if resource is PackedScene:
		_scenes[path] = resource
	else:
		_runtime_resources[path] = resource

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
		_runtime_resources.erase(path)
		_requested.erase(path)
		_queue.erase(path)
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
			_pump()
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
			_pump()
			return got2
		_requested.erase(path)
		_pump()
	# 还在排队、没轮到：从队列里拿掉，下面同步读（和完全没预取一样，统计成 cold）。
	_queue.erase(path)
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
	_pump()
	# 读条要算上还在排队的（以前全部请求一次发出，没有队列）。
	return _requested.size() + _queue.size()

static func pending_count() -> int:
	return _requested.size() + _queue.size()

static func cached_count() -> int:
	return _scenes.size()

# Read-only progress query for a caller-owned path list. Unlike get_scene(), this
# never waits or starts a cold load, so it is safe to call once per loading frame.
static func ready_count(paths: Array) -> int:
	var ready := 0
	for raw_path in paths:
		if _scenes.has(str(raw_path)):
			ready += 1
	return ready

# 整局结束时叫一次，别让上一局的阵容留到下一局。
static func reset_run() -> void:
	_scenes.clear()
	_runtime_resources.clear()
	_owners.clear()
	_requested.clear()
	_queue.clear()
