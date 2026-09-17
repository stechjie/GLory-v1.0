extends RefCounted

# IMA ADPCM，每 20 毫秒一块 —— 电脑版语音用（docs/聊天系统设计.md 第九节「电脑版语音」）。
#
# 🔴 必须与安卓插件 android_plugins/glory_voice/src/com/glory/voice/AdpcmCodec.java **逐字节一致**。
# 对不上不会报错：手机和电脑互相听到的只是杂音。tools/voice_check 拿 Java 跑出来的样本
# （tools/fixtures/voice_adpcm_golden.json，由 tools/voice_adpcm_golden.ps1 生成）对账，
# 编码结果与解码结果都要逐个相等。改这里或改 Java 之后都要重新对账。
#
# 一块（320 个采样 → 163 字节）：[s16 起始预测值 LE][u8 步长序号][160 字节，每字节两个 4 比特，低位在前]。
# 每块自带解码起点，任何一块都能单独解。
#
# 采样用 PackedInt32Array 装（GDScript 没有 16 位整数数组），值域是 -32768..32767。
# 不用 class_name：理由同 scripts/multiplayer/RateLimitService.gd（打包脚本与全局类缓存）。

const SAMPLE_RATE := 16000
const FRAME_SAMPLES := 320
const BLOCK_BYTES := 3 + FRAME_SAMPLES / 2

const INDEX_TABLE: Array[int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

const STEP_TABLE: Array[int] = [
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
	34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
	157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
	724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
	3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
	15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
]


# 编码器跨块延续的状态 [predictor, index]。块与块之间连续，音质才不会每 20 毫秒跳一下；
# 一段话开头要调 clear_state（同 Java 的 EncoderState.reset）。
# ⚠️ 不能叫 reset_state：Godot 的 Resource 自带同名方法，`Adpcm.reset_state(x)` 会调到脚本资源自己的
# 那个（0 个参数）并报错，2026-09-17 实测踩过。
static func new_state() -> Array[int]:
	return [0, 0]


static func clear_state(state: Array[int]) -> void:
	state[0] = 0
	state[1] = 0


# 把 pcm[offset..offset+320) 编成一块。
static func encode_block(pcm: PackedInt32Array, offset: int, state: Array[int]) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(BLOCK_BYTES)
	var predictor := state[0]
	var index := state[1]
	# 块头写的是**编这一块之前**的状态 —— 解码端从这里起步，才和编码端一致。
	out[0] = predictor & 0xff
	out[1] = (predictor >> 8) & 0xff
	out[2] = index
	var nibble_byte := 3
	for i in FRAME_SAMPLES:
		var diff := pcm[offset + i] - predictor
		var nibble := 0
		if diff < 0:
			nibble = 8
			diff = -diff
		var step := STEP_TABLE[index]
		var delta := step >> 3
		if diff >= step:
			nibble |= 4
			diff -= step
			delta += step
		step >>= 1
		if diff >= step:
			nibble |= 2
			diff -= step
			delta += step
		step >>= 1
		if diff >= step:
			nibble |= 1
			delta += step
		predictor += -delta if (nibble & 8) != 0 else delta
		predictor = clampi(predictor, -32768, 32767)
		index = clampi(index + INDEX_TABLE[nibble], 0, 88)
		if (i & 1) == 0:
			out[nibble_byte] = nibble
		else:
			out[nibble_byte] = out[nibble_byte] | (nibble << 4)
			nibble_byte += 1
	state[0] = predictor
	state[1] = index
	return out


# 解 data[offset..offset+163) 这一块，返回 320 个采样。不依赖任何前一块。
static func decode_block(data: PackedByteArray, offset: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(FRAME_SAMPLES)
	var predictor := data[offset] | (data[offset + 1] << 8)
	if predictor >= 32768:
		predictor -= 65536
	var index := mini(data[offset + 2], 88)
	var nibble_byte := offset + 3
	for i in FRAME_SAMPLES:
		var nibble := 0
		if (i & 1) == 0:
			nibble = data[nibble_byte] & 0x0f
		else:
			nibble = (data[nibble_byte] >> 4) & 0x0f
			nibble_byte += 1
		var step := STEP_TABLE[index]
		var delta := step >> 3
		if (nibble & 4) != 0:
			delta += step
		if (nibble & 2) != 0:
			delta += step >> 1
		if (nibble & 1) != 0:
			delta += step >> 2
		predictor += -delta if (nibble & 8) != 0 else delta
		predictor = clampi(predictor, -32768, 32767)
		index = clampi(index + INDEX_TABLE[nibble], 0, 88)
		out[i] = predictor
	return out


# 同 RemoteStream.java 的 rms：均方根，归一到 0..1。
static func rms(pcm: PackedInt32Array) -> float:
	if pcm.is_empty():
		return 0.0
	var total := 0.0
	for s in pcm:
		total += float(s) * float(s)
	return sqrt(total / pcm.size()) / 32768.0
