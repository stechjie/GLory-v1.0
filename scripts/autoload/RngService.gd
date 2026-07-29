extends Node

# 警告：rng 只允许模拟代码（BattleSim* / DamageService）消费。
# compute_team_replay_async 分帧计算依赖这一点——如果未来任何 UI/特效逻辑
# 也来抽这个 rng，await 期间的穿插消费会让 pvp 的 replay_a/replay_b 悄悄不一致。
var rng := RandomNumberGenerator.new()

# --- 战斗种子派生（C23a）-----------------------------------------------------
# 旧实现是 `JSON.stringify(parts).hash()`，两个问题：
#   ① `String.hash()` 只有 **32 位**。一局 21 回合 × 两队 = 42 个种子，碰撞概率虽小，
#      但种子同时是"服务端复现某场战斗 bug"的唯一钥匙 —— 32 位空间下没法保证
#      "这个种子只对应这一场"。
#   ② `JSON.stringify` 的输出依赖 Godot 的 JSON 实现（浮点表示、转义规则），
#      跨版本不保证逐字节一致。种子变了 = 整场战斗变了，而且不会有任何报错。
#
# 现在改成**固定编码 + FNV-1a 64 位**，编码规则写死在这里，不依赖任何库的输出格式。
#
# ⚠️ 这个改动会**改变所有战斗结果**（同阵容打出的和以前不一样）。
# 现在没有玩家、没有赛季，是唯一能改的窗口。

# 0xcbf29ce484222325 / 0x100000001b3，按 int64 有符号表示
const FNV64_OFFSET_BASIS := -3750763034362895579
const FNV64_PRIME := 1099511628211

# 把 parts 编成「类型标记 + 值」的规范字符串。
# 带类型标记是为了让 `1`（int）和 `"1"`（String）产生不同种子，否则两者会撞。
static func canonical_parts(parts: Array) -> String:
	var out := PackedStringArray()
	for p in parts:
		match typeof(p):
			TYPE_INT:
				out.append("i:%d" % int(p))
			TYPE_BOOL:
				out.append("b:%d" % (1 if bool(p) else 0))
			TYPE_STRING, TYPE_STRING_NAME:
				out.append("s:%s" % str(p))
			TYPE_FLOAT:
				# 浮点的十进制表示跨平台/跨版本不保证一致，直接编 IEEE 位模式。
				# 种子参数里本来就不该出现浮点，这里只是兜底。
				out.append("d:%d" % _float_bits(float(p)))
			_:
				# 其余类型没有稳定编码保证，出现即视为调用方的 bug。
				push_warning("RngService: unstable seed part type %d" % typeof(p))
				out.append("?:%s" % str(p))
	return "|".join(out)

static func _float_bits(v: float) -> int:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_double(0, v)
	return buf.decode_s64(0)

# FNV-1a 64。GDScript 的 int 是有符号 64 位，溢出按二进制补码回绕 ——
# 这正是 FNV 需要的行为，不用额外掩码。
static func fnv1a64(text: String) -> int:
	var h := FNV64_OFFSET_BASIS
	for b in text.to_utf8_buffer():
		h ^= int(b)
		h *= FNV64_PRIME
	return h

func seed_from_parts(parts: Array) -> int:
	var seed_value := fnv1a64(canonical_parts(parts))
	rng.seed = seed_value
	return seed_value

func randf_det() -> float:
	return rng.randf()

func randi_range_det(from: int, to: int) -> int:
	return rng.randi_range(from, to)
