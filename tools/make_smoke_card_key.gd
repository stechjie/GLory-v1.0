extends SceneTree

# 打包冷启动测试用：生成一次性出战名片公钥，并可生成一次性 DTLS 密钥与证书。
#
# 专服没有出战名片公钥就拒绝启动（scripts/multiplayer/BattleCard.gd），而冷启动测试
# 只要证明「起得来」、不验任何名片。名片只写公钥；可选 DTLS 私钥仅写入冒烟目录，绝不进正式 ZIP。
# 调用方是 make_server_zip.ps1 的第 5 步。
#
# 用法：
#   godot --headless --path <目录> --script res://tools/make_smoke_card_key.gd -- --out=<绝对路径>
#   可选：--tls-key=<冒烟目录私钥> --cert-script=<冒烟目录 NetTLSCert.gd>
#
# 只用 Crypto，不碰任何 autoload —— 在刚解压的服务器包里也能跑。

const OUT_ARG := "--out="


func _initialize() -> void:
	var out := ""
	var tls_key_out := ""
	var cert_script_out := ""
	for arg in OS.get_cmdline_user_args():
		if str(arg).begins_with(OUT_ARG):
			out = str(arg).substr(OUT_ARG.length()).strip_edges()
		elif str(arg).begins_with("--tls-key="):
			tls_key_out = str(arg).trim_prefix("--tls-key=").strip_edges()
		elif str(arg).begins_with("--cert-script="):
			cert_script_out = str(arg).trim_prefix("--cert-script=").strip_edges()
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
	if tls_key_out.is_empty() != cert_script_out.is_empty():
		print("[SMOKE_KEY] FATAL: --tls-key and --cert-script must be supplied together")
		quit(2)
		return
	if not tls_key_out.is_empty():
		var tls_key := Crypto.new().generate_rsa(2048)
		var tls_cert := Crypto.new().generate_self_signed_certificate(
			tls_key, "CN=glory-smoke-only,O=Test", "20200101000000", "20400101000000")
		if tls_key == null or tls_cert == null or tls_key.save(tls_key_out) != OK:
			print("[SMOKE_KEY] FATAL: cannot write disposable TLS key")
			quit(2)
			return
		var raw_pem := tls_cert.save_to_string()
		const END_CERT := "-----END CERTIFICATE-----"
		var pem_end := raw_pem.find(END_CERT)
		if pem_end < 0:
			print("[SMOKE_KEY] FATAL: disposable TLS certificate is invalid")
			quit(2)
			return
		var cert_file := FileAccess.open(cert_script_out, FileAccess.WRITE)
		if cert_file == null:
			print("[SMOKE_KEY] FATAL: cannot write disposable TLS pin")
			quit(2)
			return
		var clean_pem := raw_pem.substr(0, pem_end + END_CERT.length()) + "\n"
		cert_file.store_string("extends RefCounted\nconst PEM := " + JSON.stringify(clean_pem) + "\n")
		cert_file.close()
		print("[SMOKE_KEY] wrote disposable TLS key and pin in smoke copy")
	print("[SMOKE_KEY] wrote %s" % out)
	quit(0)
