extends Node

# ReplayTransferService 的独立门禁（D1 验收条款：每个子服务有独立 headless 测试）。
#
# 原始 README 给这个服务定了四件事：**压缩、分块、确认、重试**，现在四件都在了。
# （此前只有压缩，本文件当时留着一条显式的未覆盖声明，现已不再适用。）
#
# 分块这半的测试重心在**重组缓冲**：accept_chunk() 的输入完全由对端控制，
# 而它会为对端分配内存并保持到下一块到达。没有上限与过期的话，一个发一半就跑的
# 对端就能把内存钉死 —— 这和解压炸弹是同一类问题，所以拒收用例写得比正常路径多。
#
# 阈值也要钉住：典型局压缩后约 98 KiB，低于阈值就**不分块**、走原来的单包路径。
# 把阈值判断写反的后果是静默的（两条路径都能把回放送到），只会在大包时才爆，
# 所以必须有用例直接盯它。
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
	_check_long_dead_frames()
	_check_compression_actually_shrinks()
	_check_empty_and_short_inputs()
	_check_bomb_guard()
	_check_corrupt_and_truncated()
	_check_no_object_construction()
	_check_clear()
	_check_threshold()
	_check_split_reassemble_round_trip()
	_check_out_of_order_and_duplicates()
	_check_missing_chunks()
	_check_chunk_rejections()
	_check_inflight_caps()
	_check_reassembly_expiry()
	_check_clear_drops_inflight()
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


# 分块用的样本：值带噪，压缩后仍然够大。
#
# 不能用 _sample_replay：它的值是 f * 1.5 这种高度可预测的序列，ZSTD 能把
# 400 帧压到一块以内 —— 那样所有"乱序/重复/缺块"用例都退化成 total=1，
# 看着在跑实际什么都没测。第一版就是这么碎的，症状是 dup_after_complete 变红：
# 单块传输里第一块就是最后一块。
#
# 固定种子：分块数量得是确定的，否则用例会时红时绿。
func _noisy_replay(frames: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260821
	var out := {"roster": {}, "frames": [], "result": {"player_wins": true, "reason": "hp"}}
	for u in 12:
		out["roster"]["unit_%d" % u] = {"id": "human_militia", "max_hp": 100 + u}
	for f in frames:
		var row: Array = []
		for u in 12:
			row.append(["u%d_%d" % [u, rng.randi()], rng.randf(), rng.randf(), rng.randi(), rng.randi() % 2 == 0])
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


func _wire(payload: Dictionary) -> PackedByteArray:
	var raw := var_to_bytes(payload)
	var result := PackedByteArray()
	result.resize(TransferScript.PACK_HEADER_BYTES)
	result.encode_u64(0, raw.size())
	result.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return result


func _check_long_dead_frames() -> void:
	var svc := _make()
	var replay := {"frames": [], "result": {"winner": 0}}
	for f in 128:
		var rows: Array = []
		for u in 100:
			# Death, revival, and a later changed dead row all round-trip exactly.
			rows.append(["unit_%d" % u, 1.25, 2.5, 0, f == 64,
				{"effect": "x".repeat(2048), "changed": f >= 100}])
		replay.frames.append(rows)
	var original := var_to_bytes(replay)
	_h.expect(original.size() > TransferScript.MAX_UNCOMPRESSED_BYTES,
		"long_fixture_small", "长战斗样本必须超过旧的 16 MiB 上限")
	var packed: PackedByteArray = svc.pack(replay)
	_h.expect(not packed.is_empty(), "long_pack_empty", "重复死亡帧应无损编码，不能返回空包")
	var back: Dictionary = svc.unpack(packed)
	_h.expect(var_to_bytes(back) == original, "long_roundtrip", "压缩不能改变浮点、帧顺序、复活或死亡状态")
	_h.expect(var_to_bytes(replay) == original, "pack_mutation", "编码不能修改模拟器原始回放")
	if not back.is_empty():
		back.frames[1][0][5].effect = "mutated"
		_h.expect(back.frames[0][0][5].effect != "mutated", "row_alias", "解码帧不能共享可变状态")
	var marker: String = TransferScript.DEAD_REFERENCE_KEY
	for frames in [[["missing"]], [[["u", 0, 0, 1, true]], ["u"]]]:
		var malformed := {"frames": frames}
		malformed[marker] = true
		_h.expect(svc.unpack(_wire(malformed)).is_empty(), "invalid_dead_ref", "未知或活棋子引用必须拒收")
	var bomb := {"frames": [[["u", 0, 0, 0, false, "x".repeat(1024 * 1024)]]]}
	bomb[marker] = true
	for i in 70:
		bomb.frames.append(["u"])
	_h.expect(svc.unpack(_wire(bomb)).is_empty(), "expansion_budget", "帧引用必须在复制前检查展开上限")


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

# --- 分块：阈值 ---------------------------------------------------------------

# 阈值写反的后果是**静默的**：两条路径都能把回放送到，只在大包时才炸。
# 所以直接钉住三种输入的判定结果。
func _check_threshold() -> void:
	var svc := _make()

	var small := PackedByteArray()
	small.resize(TransferScript.CHUNK_THRESHOLD_BYTES)
	_h.expect(not svc.should_chunk(small),
		"threshold_small_chunked", "等于阈值不该分块 —— 边界是 >，不是 >=")

	var big := PackedByteArray()
	big.resize(TransferScript.CHUNK_THRESHOLD_BYTES + 1)
	_h.expect(svc.should_chunk(big),
		"threshold_big_not_chunked", "超过阈值必须分块")

	# 典型局（实测压缩后约 98 KiB）必须走单包路径：分块只对离群大局生效。
	var typical := PackedByteArray()
	typical.resize(98 * 1024)
	_h.expect(not svc.should_chunk(typical),
		"threshold_typical_chunked", "98 KiB 的典型局不该分块，否则典型路径的行为被改了")

	# 强制模式：门禁与真机测试靠它把生产里几乎走不到的分块路径真的走一遍。
	_h.expect(svc.should_chunk(typical, true),
		"threshold_force_ignored", "force=true 时必须分块，否则分块路径没有任何东西在验")

	# 空包/只有头：没有可分的东西，force 也不该硬切。
	var empty := PackedByteArray()
	empty.resize(TransferScript.PACK_HEADER_BYTES)
	_h.expect(not svc.should_chunk(empty, true),
		"threshold_empty_chunked", "空包即使 force 也不该分块")


# --- 分块：切开再拼回来 -------------------------------------------------------

# 端到端跑一遍 pack -> split -> accept_chunk -> unpack，比对最终字典。
# 只测 split/accept 的字节往返是不够的：真正要保证的是**回放内容没变**，
# 回放对不上等于两端看到不同的战斗。
func _check_split_reassemble_round_trip() -> void:
	var svc := _make()
	var replay := _noisy_replay(900)
	var packed: PackedByteArray = svc.pack(replay)
	var chunks: Array = svc.split(packed, "room1:3:9", TransferScript.CHUNK_KIND_OWN)
	_h.expect(chunks.size() >= 3,
		"split_single_chunk", "本用例需要真的切出多块（实际 %d）—— total=1 时下面的断言全部退化" % chunks.size())

	var expected_total := int(ceil(float(packed.size()) / float(TransferScript.CHUNK_PAYLOAD_BYTES)))
	_h.expect(chunks.size() == expected_total,
		"split_count", "块数应为 %d，实际 %d" % [expected_total, chunks.size()])

	var result := {}
	for env in chunks:
		_h.expect(int((env as Dictionary).get("total", 0)) == expected_total,
			"split_total_field", "每块都要带一致的 total")
		_h.expect((env as Dictionary).get("data", PackedByteArray()).size() <= TransferScript.CHUNK_PAYLOAD_BYTES,
			"split_chunk_oversized", "单块不得超过 CHUNK_PAYLOAD_BYTES")
		result = svc.accept_chunk(env)

	_h.expect(bool(result.get("complete", false)),
		"reassemble_incomplete", "收齐所有块后应报 complete")
	var rebuilt: PackedByteArray = result.get("packed", PackedByteArray())
	_h.expect(rebuilt == packed,
		"reassemble_bytes", "重组出来的字节应与原包完全一致（%d vs %d）" % [rebuilt.size(), packed.size()])
	_h.expect(str(svc.unpack(rebuilt)) == str(replay),
		"reassemble_replay", "重组后解包应还原出同一份回放")
	_h.expect(svc.inflight_count() == 0,
		"reassemble_leak", "收齐后必须把重组槽释放掉，否则每传一次漏一条")


# 乱序到达是可靠通道也会有的正常情况（重试补发的块必然乱序），
# 重复块则是重试的直接产物 —— 两者都不能让重组出错或让字节记账虚高。
func _check_out_of_order_and_duplicates() -> void:
	var svc := _make()
	var replay := _noisy_replay(700)
	var packed: PackedByteArray = svc.pack(replay)
	var chunks: Array = svc.split(packed, "room2:1:1", TransferScript.CHUNK_KIND_RIVAL)
	_h.expect(chunks.size() >= 3, "ooo_too_few_chunks", "这个用例需要至少 3 块才有意义")

	# 倒着喂：收齐之前任何一步都不该报 complete
	var result := {}
	var completed_early := false
	var fed := 0
	for i in range(chunks.size() - 1, -1, -1):
		result = svc.accept_chunk(chunks[i])
		fed += 1
		if bool(result.get("complete", false)) and fed < chunks.size():
			completed_early = true
	_h.expect(not completed_early,
		"ooo_early_complete", "没收齐就报 complete —— 会把半份回放喂进战斗")
	_h.expect(bool(result.get("complete", false)),
		"ooo_incomplete", "乱序收齐后仍应报 complete")
	_h.expect((result.get("packed", PackedByteArray()) as PackedByteArray) == packed,
		"ooo_bytes", "乱序到达必须按 idx 拼回原顺序，不能依赖字典键序")

	# 收齐并释放后重喂一块：应当被当成一次新传输的第一块，不报错也不报 complete。
	var again: Dictionary = svc.accept_chunk(chunks[0])
	_h.expect(not bool(again.get("complete", false)),
		"dup_after_complete", "收齐释放后重喂单块不该直接报 complete")
	_h.expect(str(again.get("error", "")).is_empty(),
		"dup_after_complete_error", "重喂单块不该报错")

	# 同一条传输里的重复块：幂等，且不得重复计字节。
	var svc2 := _make()
	svc2.accept_chunk(chunks[0])
	for _i in 5:
		var dup: Dictionary = svc2.accept_chunk(chunks[0])
		_h.expect(not bool(dup.get("complete", false)), "dup_complete", "重复块不该凑出 complete")
		_h.expect(str(dup.get("error", "")).is_empty(), "dup_error", "重复块应幂等收下，不报错")
	var still_missing: PackedInt32Array = svc2.missing_chunks("room2:1:1", TransferScript.CHUNK_KIND_RIVAL)
	_h.expect(still_missing.size() == chunks.size() - 1,
		"dup_miscounted", "重复块不该改变缺块数（期望 %d，实际 %d）" % [chunks.size() - 1, still_missing.size()])


# --- 分块：缺块查询（确认与重试都靠它）---------------------------------------

func _check_missing_chunks() -> void:
	var svc := _make()
	var packed: PackedByteArray = svc.pack(_noisy_replay(700))
	var chunks: Array = svc.split(packed, "room3:2:5", TransferScript.CHUNK_KIND_OWN)
	_h.expect(chunks.size() >= 4, "missing_too_few", "这个用例需要至少 4 块")

	# 没见过的传输：返回空。调用方靠 has_inflight 区分"不缺"和"没开始"。
	_h.expect(svc.missing_chunks("nope", TransferScript.CHUNK_KIND_OWN).is_empty(),
		"missing_unknown", "未知传输应返回空缺块表")
	_h.expect(not svc.has_inflight("nope", TransferScript.CHUNK_KIND_OWN),
		"inflight_unknown", "未知传输不该报 has_inflight")

	# 只喂偶数块
	var expect_missing: Array = []
	for i in chunks.size():
		if i % 2 == 0:
			svc.accept_chunk(chunks[i])
		else:
			expect_missing.append(i)

	var missing: PackedInt32Array = svc.missing_chunks("room3:2:5", TransferScript.CHUNK_KIND_OWN)
	_h.expect(missing.size() == expect_missing.size(),
		"missing_count", "缺块数应为 %d，实际 %d" % [expect_missing.size(), missing.size()])
	for i in expect_missing:
		_h.expect(missing.has(int(i)), "missing_wrong_set", "缺块表应包含 idx=%d" % int(i))
	_h.expect(svc.has_inflight("room3:2:5", TransferScript.CHUNK_KIND_OWN),
		"inflight_missing", "未收齐的传输应报 has_inflight")


# --- 分块：拒收 ---------------------------------------------------------------

# accept_chunk 的输入完全由对端控制，每一条校验对应一种具体的滥用方式。
# 这些用例是本文件里最该存在的一批：漏掉任何一条，对端就能用一个包影响服务器/客户端
# 的内存分配。三条断言各有分工 —— 不报 complete、必须给出原因、**且不得留下重组槽**。
# 最后那条才是重点：拒收却已经分配了，等于没拒。
func _check_chunk_rejections() -> void:
	var base := {
		"battle_id": "room4:1:1",
		"kind": TransferScript.CHUNK_KIND_OWN,
		"idx": 0,
		"total": 4,
		"data": PackedByteArray([1, 2, 3]),
	}

	var cases := {
		"missing_battle_id": {"battle_id": ""},
		"bad_kind": {"kind": "evil"},
		"bad_total_zero": {"total": 0},
		"bad_total_negative": {"total": -3},
		"bad_total_huge": {"total": TransferScript.MAX_CHUNKS + 1},
		"bad_idx_negative": {"idx": -1},
		"bad_idx_overflow": {"idx": 4},
		"declared_too_large": {"total": TransferScript.MAX_CHUNKS},
	}
	for label in cases.keys():
		var svc := _make()
		var env: Dictionary = base.duplicate(true)
		for k in (cases[label] as Dictionary).keys():
			env[k] = (cases[label] as Dictionary)[k]
		var out: Dictionary = svc.accept_chunk(env)
		_h.expect(not bool(out.get("complete", false)),
			"reject_completed_%s" % label, "%s 不该报 complete" % label)
		_h.expect(not str(out.get("error", "")).is_empty(),
			"reject_silent_%s" % label, "%s 必须报出拒收原因" % label)
		_h.expect(svc.inflight_count() == 0,
			"reject_allocated_%s" % label, "%s 被拒后不得留下重组槽 —— 拒收却已分配等于没拒" % label)

	# 超长块：绕过"按块数算出来的上限"的直接手段。
	var svc2 := _make()
	var fat: Dictionary = base.duplicate(true)
	var payload := PackedByteArray()
	payload.resize(TransferScript.CHUNK_PAYLOAD_BYTES + 1)
	fat["data"] = payload
	var out2: Dictionary = svc2.accept_chunk(fat)
	_h.expect(not str(out2.get("error", "")).is_empty(),
		"reject_oversized_chunk", "超过 CHUNK_PAYLOAD_BYTES 的块必须拒收")
	_h.expect(svc2.inflight_count() == 0,
		"reject_oversized_allocated", "超长块被拒后不得留下重组槽")

	# total 中途变化：要么是 bug，要么是有人在搅记账。整条丢掉。
	var svc3 := _make()
	svc3.accept_chunk(base)
	var shifted: Dictionary = base.duplicate(true)
	shifted["idx"] = 1
	shifted["total"] = 9
	var out3: Dictionary = svc3.accept_chunk(shifted)
	_h.expect(str(out3.get("error", "")) == "total_changed",
		"reject_total_changed", "同一传输里 total 变化必须拒收")
	_h.expect(svc3.inflight_count() == 0,
		"reject_total_changed_kept", "total 变化后整条传输应丢掉，不能留着继续拼")

	# split 侧的拒收：坏 kind、超大包。
	var svc4 := _make()
	var nine := PackedByteArray()
	nine.resize(TransferScript.PACK_HEADER_BYTES + 4)
	_h.expect((svc4.split(nine, "r", "evil") as Array).is_empty(),
		"split_bad_kind", "split 遇到非法 kind 应返回空")
	var huge := PackedByteArray()
	huge.resize(TransferScript.MAX_TRANSFER_BYTES + 1)
	_h.expect((svc4.split(huge, "r", TransferScript.CHUNK_KIND_OWN) as Array).is_empty(),
		"split_oversized", "超过单次传输上限的包应拒绝切块，而不是切出上千块")


# --- 分块：并发条数与总字节上限 -----------------------------------------------

# 单条限死了、总量不限，等于允许对端开很多条把内存吃光。这两道闸都要有。
func _check_inflight_caps() -> void:
	var svc := _make()
	var chunk := PackedByteArray()
	chunk.resize(TransferScript.CHUNK_PAYLOAD_BYTES)

	# 条数上限：开满之后第 N+1 条必须被拒。
	for i in TransferScript.MAX_INFLIGHT_TRANSFERS:
		var out: Dictionary = svc.accept_chunk({
			"battle_id": "room:%d" % i, "kind": TransferScript.CHUNK_KIND_OWN,
			"idx": 0, "total": 4, "data": chunk,
		})
		_h.expect(str(out.get("error", "")).is_empty(),
			"cap_rejected_early", "第 %d 条传输不该被拒（上限是 %d）" % [i, TransferScript.MAX_INFLIGHT_TRANSFERS])
	var over: Dictionary = svc.accept_chunk({
		"battle_id": "room:overflow", "kind": TransferScript.CHUNK_KIND_OWN,
		"idx": 0, "total": 4, "data": chunk,
	})
	_h.expect(str(over.get("error", "")) == "too_many_inflight",
		"cap_inflight", "超过 MAX_INFLIGHT_TRANSFERS 必须拒收")
	_h.expect(svc.inflight_count() == TransferScript.MAX_INFLIGHT_TRANSFERS,
		"cap_inflight_grew", "被拒的传输不得占用槽位")

	# 总字节上限：在允许的条数内把总量堆到超限。
	var svc2 := _make()
	var tripped := ""
	var per_transfer := int(TransferScript.MAX_TRANSFER_BYTES / TransferScript.CHUNK_PAYLOAD_BYTES)
	# 每条都**故意不喂满**：收齐就会释放重组槽，总量回到零，
	# 预算闸永远碰不到。第一版就是这么写的，结果 cap_budget 一直不触发。
	for t in TransferScript.MAX_INFLIGHT_TRANSFERS:
		for i in per_transfer - 1:
			var out2: Dictionary = svc2.accept_chunk({
				"battle_id": "big:%d" % t, "kind": TransferScript.CHUNK_KIND_OWN,
				"idx": i, "total": per_transfer, "data": chunk,
			})
			if str(out2.get("error", "")) == "reassembly_budget":
				tripped = "reassembly_budget"
				break
		if not tripped.is_empty():
			break
	_h.expect(tripped == "reassembly_budget",
		"cap_budget", "总字节堆到 MAX_REASSEMBLY_BYTES 以上必须拒收，实际未触发")


# --- 分块：过期回收 -----------------------------------------------------------

# 重组缓冲不带过期 = 一个发一半就跑的对端能把内存钉死。
# 年龄用 tick 累加而不是墙钟，所以这里能直接把时间推过去，不用真的等。
func _check_reassembly_expiry() -> void:
	var svc := _make()
	var chunk := PackedByteArray()
	chunk.resize(1024)
	svc.accept_chunk({
		"battle_id": "stale:1", "kind": TransferScript.CHUNK_KIND_OWN,
		"idx": 0, "total": 4, "data": chunk,
	})
	_h.expect(svc.inflight_count() == 1, "expiry_setup", "用例前置：应有一条重组中的传输")

	# 没到期之前不能被收走，否则慢连接的正常传输会被误杀。
	svc.tick(TransferScript.REASSEMBLY_TTL_SEC * 0.5)
	_h.expect(svc.inflight_count() == 1,
		"expiry_too_eager", "未到 TTL 就回收会误杀慢连接的正常传输")

	# 新块到达要把年龄清零：只要还在传就不算过期。
	svc.accept_chunk({
		"battle_id": "stale:1", "kind": TransferScript.CHUNK_KIND_OWN,
		"idx": 1, "total": 4, "data": chunk,
	})
	svc.tick(TransferScript.REASSEMBLY_TTL_SEC * 0.6)
	_h.expect(svc.inflight_count() == 1,
		"expiry_no_refresh", "有新块到达应刷新年龄，否则正在传的大包会被中途丢掉")

	_logs.clear()
	svc.tick(TransferScript.REASSEMBLY_TTL_SEC + 1.0)
	_h.expect(svc.inflight_count() == 0,
		"expiry_never", "超过 TTL 的重组缓冲必须回收 —— 否则发一半就跑能把内存钉死")
	var logged := false
	for line in _logs:
		if line.contains("expired"):
			logged = true
	_h.expect(logged, "expiry_not_logged", "回收应留日志 —— 线上被打时这是唯一线索")


func _check_clear_drops_inflight() -> void:
	var svc := _make()
	var chunk := PackedByteArray()
	chunk.resize(512)
	svc.accept_chunk({
		"battle_id": "c:1", "kind": TransferScript.CHUNK_KIND_OWN,
		"idx": 0, "total": 3, "data": chunk,
	})
	_h.expect(svc.inflight_count() == 1, "clear_setup", "用例前置：应有一条重组中的传输")
	svc.clear()
	_h.expect(svc.inflight_count() == 0,
		"clear_inflight", "clear 必须一并丢掉重组中的分块，否则换局后旧槽占着名额")
