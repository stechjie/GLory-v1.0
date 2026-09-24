extends Node

# 跑 tools/synergy_0924_check.gd：
#   godot --headless --path . res://tools/synergy_0924_runner.tscn
# 用场景启动而不是 -s：-s 脚本在 autoload 注册前就编译，找不到 GameState 等全局名。
func _ready() -> void:
	var check = load("res://tools/synergy_0924_check.gd").new()
	check.run(self)
