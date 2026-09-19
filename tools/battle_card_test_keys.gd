extends RefCounted

# 测试用的出战名片钥匙与名片（BattleCard.gd）。
#
# 🔴 **钥匙一律在运行时现场生成，绝不进仓库。** make_server_zip.ps1 会把整个 tools/
# 打进战斗服务器包，这里只能有代码。
#
# 起真服务器的工具（persist_check / channel_check）没有公钥就起不来。它们把现场生成的
# 公钥写到 TEST_PUBLIC_PATH，回归脚本再用 --battle-card-key= 把这条路径传给服务器。
#
# **绝不写默认路径 user://battle_card_public.pem。** 开发机上那里可能放着线上那把公钥
# （本机起专服、连真账号服务器时要用），测试把它覆盖掉，下一次本机联调就会莫名其妙
# 全部 card_bad_signature。所以命令行没指到测试路径时，install_for_server 直接报错，不去碰它。
#
# 签名格式与 backend/app/loadout.py 的 sign() 一致：base64(JSON 字节).base64(签名)，
# RSA-2048 / PKCS#1 v1.5 / SHA-256。

const BattleCard := preload("res://scripts/multiplayer/BattleCard.gd")

const TEST_PUBLIC_PATH := "user://test_battle_card_public.pem"
# 只给两进程的 channel_check 用：服务端进程生成，客户端进程读来签名。
const TEST_PRIVATE_PATH := "user://test_battle_card_private.pem"
const KEY_ARG_VALUE := BattleCard.KEY_ARG + TEST_PUBLIC_PATH


static func generate() -> CryptoKey:
	return Crypto.new().generate_rsa(2048)


static func public_pem(key: CryptoKey) -> String:
	return key.save_to_string(true)


# 给要起真服务器的工具用：生成一把钥匙，公钥写到 TEST_PUBLIC_PATH
# （write_private 时私钥也写，给另一个进程签名）。返回空串 = 成功，否则是可读的原因。
static func install_for_server(write_private: bool = false) -> String:
	if BattleCard.server_key_path() != TEST_PUBLIC_PATH:
		return "要带 %s 运行（服务器现在读的是 %s；见 tools/multiplayer_regression.sh）" % [
			KEY_ARG_VALUE, BattleCard.server_key_path()]
	var key := generate()
	if not _write(TEST_PUBLIC_PATH, public_pem(key)):
		return "写不了 %s" % TEST_PUBLIC_PATH
	if write_private and not _write(TEST_PRIVATE_PATH, key.save_to_string(false)):
		return "写不了 %s" % TEST_PRIVATE_PATH
	return ""


# 另一个进程读回 install_for_server(true) 写下的私钥。读不到返回 null。
static func load_private() -> CryptoKey:
	if not FileAccess.file_exists(TEST_PRIVATE_PATH):
		return null
	var key := CryptoKey.new()
	if key.load_from_string(FileAccess.get_file_as_string(TEST_PRIVATE_PATH), false) != OK:
		return null
	return key


# 用完就删。私钥虽然是一次性的，也不该在用户目录里常驻。
static func remove_files() -> void:
	for path in [TEST_PUBLIC_PATH, TEST_PRIVATE_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# 一张字段齐全、此刻有效的名片（字段名同 loadout.card_payload）。overrides 覆盖任意字段。
static func card(pid: String, overrides: Dictionary = {}) -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	var out := {
		"v": BattleCard.VERSION, "pid": pid, "code": "TESTCODE", "name": "Tester",
		"avatar": "", "frame": "", "pet": "",
		"races": ["god", "dark", "undead", "human"],
		"iat": now, "exp": now + 60,
		"jti": Crypto.new().generate_random_bytes(16).hex_encode(),
	}
	out.merge(overrides, true)
	return out


# 按账号服务器的线格式签一张名片。body_override 非空时直接签这串字节（造「签名对但内容坏」的名片用）。
static func sign(key: CryptoKey, card_fields: Dictionary, body_override: PackedByteArray = PackedByteArray()) -> String:
	var body := body_override if not body_override.is_empty() else JSON.stringify(card_fields).to_utf8_buffer()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	var signature := Crypto.new().sign(HashingContext.HASH_SHA256, ctx.finish(), key)
	return Marshalls.raw_to_base64(body) + "." + Marshalls.raw_to_base64(signature)


static func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true
