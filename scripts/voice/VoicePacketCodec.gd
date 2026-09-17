extends RefCounted

# 语音网络包的格式 —— 电脑版语音用（docs/聊天系统设计.md 第九节）。
#
# 🔴 与安卓插件 android_plugins/glory_voice/src/com/glory/voice/VoicePacket.java 完全一致，
# 电脑和手机发的包要能互相解。常量由 tools/voice_check 拿 Java 源码对账。
#
# v2（现在发的）：[u8 版本=2][u8 标志][u16 首帧序号 LE][u8 帧数][u8 编码] + 帧数 × ([u8 帧长][帧])
# v1（09-13 第一版，只有 ADPCM）：[u8 版本=1][u8 标志][u16 首帧序号 LE][u8 帧数] + 帧数 × 163 字节
#
# 战斗服务器不解析这个格式，只限总长度（NetworkService.VOICE_MAX_PACKET_BYTES = 512）。

const Adpcm := preload("res://scripts/voice/VoiceAdpcm.gd")

const VERSION_V1 := 1
const VERSION := 2
const V1_HEADER_BYTES := 5
const HEADER_BYTES := 6
# 一段话的第一个包。收的一方据此重新攒缓冲，而不是把两段话之间的静音当成丢包。
const FLAG_SPURT_START := 1
const MAX_FRAMES := 3
const MAX_FRAME_BYTES := 255
const MAX_PACKET_BYTES := 494
# 与 FrameCodec.java 的 ADPCM / OPUS 一致。
const CODEC_ADPCM := 0
const CODEC_OPUS := 1


static func size_of(frames: Array[PackedByteArray]) -> int:
	var total := HEADER_BYTES
	for frame in frames:
		total += 1 + frame.size()
	return total


static func build(seq: int, spurt_start: bool, codec: int, frames: Array[PackedByteArray]) -> PackedByteArray:
	var packet := PackedByteArray()
	packet.resize(size_of(frames))
	packet[0] = VERSION
	packet[1] = FLAG_SPURT_START if spurt_start else 0
	packet[2] = seq & 0xff
	packet[3] = (seq >> 8) & 0xff
	packet[4] = frames.size()
	packet[5] = codec
	var offset := HEADER_BYTES
	for frame in frames:
		packet[offset] = frame.size()
		offset += 1
		for i in frame.size():
			packet[offset + i] = frame[i]
		offset += frame.size()
	return packet


# 合法就返回 {seq, spurt_start, codec, frames}，不合法返回空字典。
# 规则逐条照抄 VoicePacket.parse：长度必须**正好**对上，帧长为 0、帧数与实际不符都算坏包 ——
# 只看声明不看实际字节，一个改过的包就能让解码读越界。
static func parse(packet: PackedByteArray) -> Dictionary:
	if packet.size() < V1_HEADER_BYTES + 1:
		return {}
	var version := packet[0]
	var count := packet[4]
	if count < 1 or count > MAX_FRAMES:
		return {}
	var seq := packet[2] | (packet[3] << 8)
	var spurt_start := (packet[1] & FLAG_SPURT_START) != 0
	var frames: Array[PackedByteArray] = []
	if version == VERSION_V1:
		if packet.size() != V1_HEADER_BYTES + count * Adpcm.BLOCK_BYTES:
			return {}
		for i in count:
			var start := V1_HEADER_BYTES + i * Adpcm.BLOCK_BYTES
			frames.append(packet.slice(start, start + Adpcm.BLOCK_BYTES))
		return {"seq": seq, "spurt_start": spurt_start, "codec": CODEC_ADPCM, "frames": frames}
	if version != VERSION or packet.size() < HEADER_BYTES + 2:
		return {}
	var codec := packet[5]
	if codec != CODEC_ADPCM and codec != CODEC_OPUS:
		return {}
	var offset := HEADER_BYTES
	for i in count:
		if offset >= packet.size():
			return {}
		var length := packet[offset]
		offset += 1
		if length == 0 or offset + length > packet.size():
			return {}
		if codec == CODEC_ADPCM and length != Adpcm.BLOCK_BYTES:
			return {}
		frames.append(packet.slice(offset, offset + length))
		offset += length
	if offset != packet.size():
		return {}
	return {"seq": seq, "spurt_start": spurt_start, "codec": codec, "frames": frames}
