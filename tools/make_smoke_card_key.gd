extends SceneTree

# 打包冷启动测试用：生成一把**一次性**的出战名片公钥，写到 --out= 给的路径。
#
# 专服没有出战名片公钥就拒绝启动（scripts/multiplayer/BattleCard.gd），而冷启动测试
# 只要证明「起得来」、不验任何名片。所以现场生成一对，只写公钥，私钥根本不落盘。
# 调用方是 make_server_zip.ps1 的第 5 步。
#
# 用法：
#   godot --headless --path <目录> --script res://tools/make_smoke_card_key.gd -- --out=<绝对路径>
#
# 只用 Crypto，不碰任何 autoload —— 在刚解压的服务器包里也能跑。

const OUT_ARG := "--out="


func _initialize() -> void:
	var out := ""
	for arg in OS.get_cmdline_user_args():
		if str(arg).begins_with(OUT_ARG):
			out = str(arg).substr(OUT_ARG.length()).strip_edges()
	if out.is_empty():
		print("[SMOKE_KEY] FATAL: 缺 %s<路径>" % OUT_ARG)
		quit(2)
		return
	var key := Crypto.new().generate_rsa(2048)
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		print("[SMOKE_KEY] FATAL: 写不了 %s（%s）" % [out, error_string(FileAccess.get_open_error())])
		quit(2)
		return
	f.store_string(key.save_to_string(true))
	f.close()
	print("[SMOKE_KEY] wrote %s" % out)
	quit(0)
