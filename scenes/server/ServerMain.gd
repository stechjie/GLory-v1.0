extends Node

# 专服的入口场景。
#
# 为什么需要它：`project.godot` 的主场景是 `Main.tscn`，那条路径会一路加载到
# `MainMenu.gd`，而后者 `preload()` 了一堆 `res://assets/ui/...` 的 PNG。
# 服务器包里没有 `assets/`（也不该有 —— 那是几 MB 的贴图，专服一张都不用），
# 于是 preload 变成 **parse error**，主场景加载不起来，进程**既不报错也不退出、
# 更不监听端口**，只是静默挂住。实测过：`--headless --server` 零输出、
# netstat 上看不到端口，看起来像"起来了"，其实什么都没干。
#
# 这个场景不引用任何美术资源，只把进程挂住让 NetworkService 跑它的主循环。
# 真正的启动逻辑在 `NetworkService._ready()` 里（看到 `--server` 就自己开）。
#
# 用法：
#   godot --headless --path <目录> res://scenes/server/ServerMain.tscn --server [--port=N] [--shard=N]
#
# 等号不能省：NetworkService._cmdline_int() 只匹配 `--port=` 前缀，写成 `--port N`
# 会被静默忽略，端口回落到 SERVER_PORT+shard。单分片时看不出来（值一样），
# 一开多分片就是几个进程一起去抢同一个端口。

func _ready() -> void:
	if not ("--server" in OS.get_cmdline_args() or "--dedicated-server" in OS.get_cmdline_args()):
		# 少了 --server 就只是个空场景挂在那里 —— 与其静默待机，不如直接说清楚。
		# 这正是上面那个"看起来起来了其实没监听"的坑，不能在这里再犯一次。
		push_error("ServerMain 需要 --server 参数；NetworkService 不会自动进入专服模式")
		print("[SERVER] FATAL: missing --server flag")
		get_tree().quit(2)
		return
	print("[SERVER] ServerMain ready (headless, no UI assets required)")
