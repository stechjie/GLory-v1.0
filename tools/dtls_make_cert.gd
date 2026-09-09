extends Node

# 生成战斗服务器的 DTLS 密钥对（C14）。**开发/运维工具，不在游戏里跑。**
#
# 产出两样东西，去处不同，这个分工是整件事的安全边界：
#
#   私钥  -> user://glory_server_key.pem      只放服务器，**永不进 git、永不进客户端包**
#   证书  -> scripts/multiplayer/NetTLSCert.gd 公开的，进 git、进客户端包（客户端靠它认服务器）
#
# 为什么证书写成 .gd 常量而不是 .pem 文件：
#   export_presets 的 include_filter 只列了三个 json，exclude_filter 还排掉了 tools/*。
#   一个 res://certs/*.pem 在编辑器里读得到、导出成 APK 之后**读不到** ——
#   而那正是"本机全绿、真机连不上"的经典形状。GDScript 一定会被导出，没有这个问题。
#
# 换证书 = 客户端要重新发版（证书是 pin 在包里的）。这是自签名 pin 的固有代价，
# 已知并接受：见 docs/联机审计与整改方案.md C14 一节。
#
# 跑：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/dtls_make_cert.tscn
#   加 --force 覆盖已有的密钥（默认拒绝覆盖 —— 覆盖了就换了服务器身份，
#   所有 pin 了旧证书的客户端立刻连不上）。

const CERT_SCRIPT_PATH := "res://scripts/multiplayer/NetTLSCert.gd"
const KEY_PATH := "user://glory_server_key.pem"
const SUBJECT := "CN=glory-battle,O=Glory,OU=BattleServer"
const VALID_YEARS := 10


func _ready() -> void:
	var force := false
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if str(a) == "--force":
			force = true
	var key_abs := ProjectSettings.globalize_path(KEY_PATH)
	if FileAccess.file_exists(KEY_PATH) and not force:
		print("[dtls_make_cert] 已存在私钥：%s" % key_abs)
		print("[dtls_make_cert] 覆盖它会更换服务器身份，所有 pin 了旧证书的客户端会立刻连不上。")
		print("[dtls_make_cert] 确实要换，加 --force。")
		get_tree().quit(1)
		return

	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var now := Time.get_datetime_dict_from_system(true)
	var not_before := "%04d%02d%02d000000" % [int(now["year"]), int(now["month"]), int(now["day"])]
	var not_after := "%04d%02d%02d000000" % [int(now["year"]) + VALID_YEARS, int(now["month"]), int(now["day"])]
	var cert := crypto.generate_self_signed_certificate(key, SUBJECT, not_before, not_after)
	if key == null or cert == null:
		print("[dtls_make_cert] FATAL: 生成失败")
		get_tree().quit(2)
		return

	if key.save(KEY_PATH) != OK:
		print("[dtls_make_cert] FATAL: 私钥写不出去：%s" % key_abs)
		get_tree().quit(2)
		return

	var pem := _clean_pem(cert.save_to_string())
	if pem.is_empty():
		print("[dtls_make_cert] FATAL: save_to_string 没给出完整的 PEM")
		get_tree().quit(2)
		return
	if not _write_cert_script(pem, not_before, not_after):
		get_tree().quit(2)
		return

	print("[dtls_make_cert] 私钥  -> %s   ← 只放服务器，别进 git" % key_abs)
	print("[dtls_make_cert] 证书  -> %s" % CERT_SCRIPT_PATH)
	print("[dtls_make_cert] 有效期 %s .. %s" % [not_before, not_after])
	print("[dtls_make_cert] 下一步：跑 tools/dtls_check.tscn 验一遍，再把私钥拷到服务器。")
	get_tree().quit(0)


func _write_cert_script(pem: String, not_before: String, not_after: String) -> bool:
	var f := FileAccess.open(CERT_SCRIPT_PATH, FileAccess.WRITE)
	if f == null:
		print("[dtls_make_cert] FATAL: 写不了 %s" % CERT_SCRIPT_PATH)
		return false
	f.store_string("""extends RefCounted

# 战斗服务器的**公开证书**，由 tools/dtls_make_cert.tscn 生成。不要手改。
#
# 客户端把它 pin 在包里，用来认"对面那台真的是我们的服务器"（C14）。
# 证书是公开信息，进 git 是对的；配对的私钥在服务器上，绝不进这里。
#
# 生成于 %s，有效期至 %s。
# 换证书 = 重新跑生成工具 + 客户端重新发版 + 服务器换私钥，三件事必须一起做。

const PEM := \"\"\"%s\"\"\"
""" % [not_before, not_after, pem])
	f.close()
	return true


# save_to_string() 末尾会多带一个 NUL 字节（实测 4.7.1）。原样塞进 .gd 里，
# 生成出来的脚本就带一个不可见的 U+0000，Godot 解析时报
# "Unexpected NUL character" —— 而那是**警告不是错误**，脚本照样加载，
# 于是这个坑会一路活到运行时。这里按结束标记截断，只留干净的 PEM。
func _clean_pem(raw: String) -> String:
	const MARKER := "-----END CERTIFICATE-----"
	var end := raw.find(MARKER)
	if end < 0:
		return ""
	return raw.substr(0, end + MARKER.length()) + "
"
