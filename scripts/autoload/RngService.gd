extends Node

# 警告：rng 只允许模拟代码（BattleSim* / DamageService）消费。
# compute_team_replay_async 分帧计算依赖这一点——如果未来任何 UI/特效逻辑
# 也来抽这个 rng，await 期间的穿插消费会让 pvp 的 replay_a/replay_b 悄悄不一致。
var rng := RandomNumberGenerator.new()

func seed_from_parts(parts: Array) -> int:
	var text := JSON.stringify(parts)
	var seed_hash := text.hash()
	rng.seed = seed_hash
	return seed_hash

func randf_det() -> float:
	return rng.randf()

func randi_range_det(from: int, to: int) -> int:
	return rng.randi_range(from, to)
