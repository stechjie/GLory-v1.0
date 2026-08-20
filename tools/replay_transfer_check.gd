extends Node

# ReplayTransferService 的独立门禁（D1 验收条款：每个子服务有独立 headless 测试）。
#
# 先说清覆盖范围。原始 README 给这个服务定了四件事：**压缩、分块、确认、重试**。
# 当前仓库里**只实现了压缩**：
#   * 分块 —— 只有 NetworkService.gd:1659 一句注释"信封里保留 chunk 字段但可以先不实现"
#   * 确认 —— 全仓搜不到任何 replay ack
#   * 重试 —— 同上
# 这和 README 自己的说法一致（P1 第 4 条把"回放传输恢复"列为未完成，D1 验收也写着
# "掉线回放重传…另有明确状态"）。所以本检查**只测压缩**，另外三件在下面留了一条
# 显式的未覆盖声明 —— 一个只测了四分之一却叫"ReplayTransfer 全绿"的门禁，
# 比没有门禁更容易让人误判。
#
# 压缩这半为什么值得单独测：它是**明文链路上的解析入口**，输入完全由对端控制。
#   * 长度头当防护门 -> 没有它，几 KB 的包能声称解出几 GB，服务器当场 OOM
#   * decompress_dynamic 不支持 ZSTD（实测踩过）-> 所以必须自带长度头
#   * bytes_to_var 而不是 with_objects -> 后者能从字节流构造对象，等于给中间人执行面
#   * 头与实际对不上要安静失败 -> 损坏/截断/被改过的包不该让服务器崩

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TransferScript := preload("res://scripts/multiplayer/ReplayTransferService.gd")
const CHECK_NAME := "replay_transfer"

var _h: RefCounted
var _logs: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_round_trip()
	_check_compression_actually_shrinks()
	_check_empty_and_short_inputs()
	_check_bomb_guard()
	_check_corrupt_and_truncated()
	_check_no_object_construction()
	_check_clear()
	_note_unimplemented_scope()
	_h.finish(get_tree())


func _make() -> RefCounted:
	var svc: RefCounted = TransferScript.new()
	svc.configure(func(msg: String) -> void: _logs.append(msg))
	return svc


# 造一份形状接近真实 replay 的数据：嵌套、数组、浮点、字符串都有。
func _sample_replay(frames: int) -> Dictionary:
	var out := {"roster": {}, "frames": [], "result": {"player_wins": true, "reason": "hp"}}
	for u in 12:
		out["roster"]["unit_%d" % u] = {"id": "human_militia", "max_hp": 100 + u, "team": "player" if u < 6 else "enemy"}
	for f in frames:
		var row: Array = []
		for u in 12:
			row.append(["unit_%d" % u, float(f) * 1.5, float(u) * 2.25, 100 - f, f % 2 == 0])
		out["frames"].append(row)
	return out


# --- 压缩往返 -----------------------------------------------------------------

func _check_round_trip() -> void:
	var svc := _make()
	var replay := _sample_replay(40)
	var packed: PackedByteArray = svc.pack(replay)
	_h.expect(packed.size() > TransferScript.PACK_HEADER_BYTES,
		"pack_empty", "打包结果应大于头长度")
	var back: Dictionary = svc.unpack(packed)
	_h.expect(str(back) == str(replay),
		"round_trip_mismatch", "解包结果与原始 replay 不一致 —— 回放对不上等于两端看到不同的战斗")
	_h.expect(int(packed.decode_u64(0)) == var_to_bytes(replay).size(),
		"header_length", "长度头应写入未压缩字节数；decompress() 要求预先知道输出大小")


# 压缩不是可选的：实测最坏一场 replay 原始 5.32 MiB，不压直接从 ENet 推过去
# 会把通道堵住（channel_check 那条 200 KB 大包用例就是为此存在的）。
func _check_compression_actually_shrinks() -> void:
	var svc := _make()
	var replay := _sample_replay(120)
	var raw_size := var_to_bytes(replay).size()
	var packed: PackedByteArray = svc.pack(replay)
	_h.expect(packed.size() < raw_size,
		"no_compression", "打包后应比原始小，实际 %d -> %d" % [raw_size, packed.size()])
	_h.expect(float(packed.size()) < float(raw_size) * 0.5,
		"weak_compression", "回放高度重复，压缩比不该差于 2:1（%d -> %d）" % [raw_size, packed.size()])


func _check_empty_and_short_inputs() -> void:
	var svc := _make()
	_h.expect((svc.pack({}) as PackedByteArray).is_empty(),
		"pack_empty_input", "空 replay 应打包成空字节，不该产出一个只有头的包")
	_h.expect((svc.unpack(PackedByteArray()) as Dictionary).is_empty(),
		"unpack_empty", "空输入应返回空字典")
	var short := PackedByteArray()
	short.resize(TransferScript.PACK_HEADER_BYTES)
	_h.expect((svc.unpack(short) as Dictionary).is_empty(),
		"unpack_header_only", "只有头没有数据的包应被拒 —— 边界是 <= 头长度，不是 <")


# --- 防护 ---------------------------------------------------------------------

# 解压炸弹：几 KB 的包声称解出几 GB。只看头 8 字节就能判掉，全程不解压、不分配。
#
# 实测记一笔：把这道防护整个拆掉后，红的是 bomb_not_logged 而**不是** bomb_accepted ——
# 第二道防线（头与实际内容不符）兜住了返回值。也就是说单看返回值是抓不到防护被拆的。
# 真正的危害是**分配**：decompress 会先去申请声明的那么多字节，而"有没有申请过 4 GB"
# 在这里测不了。所以日志断言是这条的主要抓手，不是附带的。
func _check_bomb_guard() -> void:
	var svc := _make()
	var bomb := PackedByteArray()
	bomb.resize(TransferScript.PACK_HEADER_BYTES)
	bomb.encode_u64(0, TransferScript.MAX_UNCOMPRESSED_BYTES + 1)
	bomb.append_array(PackedByteArray([1, 2, 3, 4]))
	_logs.clear()
	_h.expect((svc.unpack(bomb) as Dictionary).is_empty(),
		"bomb_accepted", "超过上限的声明长度必须拒收 —— 否则几 KB 的包能让服务器分配几 GB")
	var logged := false
	for line in _logs:
		if line.contains("rejected"):
			logged = true
	_h.expect(logged, "bomb_not_logged", "拒收应留日志 —— 线上被打时这是唯一线索")

	# 声明 0 或负数同样要拒：0 会让 decompress 分配 0 字节后拿到空结果，
	# 负数在 int 语境下更危险。
	for bad in [0, -1]:
		var weird := PackedByteArray()
		weird.resize(TransferScript.PACK_HEADER_BYTES)
		weird.encode_u64(0, bad)
		weird.append_array(PackedByteArray([9, 9, 9, 9]))
		_h.expect((svc.unpack(weird) as Dictionary).is_empty(),
			"bomb_nonpositive", "声明长度为 %d 时必须拒收" % bad)


func _check_corrupt_and_truncated() -> void:
	var svc := _make()
	var packed: PackedByteArray = svc.pack(_sample_replay(20))

	# 截断：头说的长度还在，数据没了
	var truncated := packed.slice(0, packed.size() / 2)
	_logs.clear()
	_h.expect((svc.unpack(truncated) as Dictionary).is_empty(),
		"truncated_accepted", "截断的包必须安静失败，不该崩也不该返回半份回放")

	# 头被改过：声明长度和实际内容对不上
	var tampered := packed.duplicate()
	tampered.encode_u64(0, int(tampered.decode_u64(0)) + 1000)
	_h.expect((svc.unpack(tampered) as Dictionary).is_empty(),
		"tampered_accepted", "头与实际内容对不上时必须拒收")

	# 数据段被改：解压本身会失败
	var flipped := packed.duplicate()
	if flipped.size() > TransferScript.PACK_HEADER_BYTES + 2:
		flipped[TransferScript.PACK_HEADER_BYTES + 1] = (int(flipped[TransferScript.PACK_HEADER_BYTES + 1]) + 137) % 256
		_h.expect((svc.unpack(flipped) as Dictionary).is_empty(),
			"flipped_accepted", "压缩数据被改动后必须拒收，不该把垃圾当回放喂进战斗")


# 用 bytes_to_var 而不是 bytes_to_var_with_objects：后者能从字节流里构造对象，
# 在明文链路上（C14 未做）等于给中间人一个执行面。
#
# 做成源码断言：要行为化地证明"没有构造对象"，得先造一份带对象的字节流，
# 而那本身就要用 var_to_bytes_with_objects —— 把攻击面搬进测试不是好主意。
func _check_no_object_construction() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/multiplayer/ReplayTransferService.gd")
	_h.expect(not source.is_empty(), "source_read", "读不到 ReplayTransferService.gd 源码")
	# 逐行判并跳过注释：直接 contains 会命中源码里那句"用 bytes_to_var 而不是
	# bytes_to_var_with_objects"的**注释**，把解释这个决定的文字当成违反它的代码。
	# 这是同一个坑第二次踩（room_service_check 的 while 断言也是这样），
	# 所以这里把做法写下来：源码级断言一律先滤掉注释行。
	var offending := false
	for raw_line in source.split("\n"):
		var line := str(raw_line).strip_edges()
		if line.begins_with("#"):
			continue
		if line.contains("bytes_to_var_with_objects"):
			offending = true
	_h.expect(not offending,
		"unpack_with_objects", "解包必须用 bytes_to_var；with_objects 能从字节流构造对象，等于给中间人执行面")
	_h.expect(source.contains("bytes_to_var("), "unpack_missing", "找不到 bytes_to_var 调用，断言可能已失效")


func _check_clear() -> void:
	var svc := _make()
	svc.team_replay = {"a": 1}
	svc.team_replay_rival = {"b": 2}
	svc.clear()
	_h.expect((svc.team_replay as Dictionary).is_empty(), "clear_replay", "clear 应清空本方回放")
	_h.expect((svc.team_replay_rival as Dictionary).is_empty(), "clear_rival", "clear 应清空敌方回放")


# 显式声明未覆盖的部分。
#
# 这条不是断言，是记录：README 给本服务定了压缩/分块/确认/重试四件事，当前只实现了
# 压缩。把"没实现"和"实现了但没测"区分开，才不会有人看着全绿以为四件都有。
func _note_unimplemented_scope() -> void:
	_h.note("覆盖范围：只测了压缩。分块/确认/重试在当前仓库里未实现"
		+ "（NetworkService.gd:1659 只有一句「信封里保留 chunk 字段但可以先不实现」，"
		+ "全仓搜不到 replay ack 或重传）。这与 README P1 第 4 条「回放传输恢复未完成」一致。")
