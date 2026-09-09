extends RefCounted

# 战斗链路的 DTLS 配置 —— docs/联机审计与整改方案.md 的 **C14**。
#
# C14 说的是：Godot ↔ 战斗服务器那条 ENet 链路是明文 UDP，没有加密、
# 没有服务端身份认证、没有完整性保护。账号那条（HTTPS → FastAPI）不在此列。
#
# ## 审计文档里那条"做不了"的记录已被证伪（2026-09-09 实测）
#
# 原记录（第五节"想过的捷径"表）：
#   > ENet + DTLS：API 存在但 host 只有 getter、create_client() 已开始连接、
#   > 配置须在 connect_to_host() 前，便利构造插不进去，需最小原型。降 P2
#
# 实测 Godot 4.7.1：**插得进去**。ENet 的 connect_to_host 只把 connect 命令排进
# 队列，真正发包在第一次 service()，而 service() 要等 multiplayer_peer 被赋值
# 之后才开始。所以 create_client() 与第一个包之间存在窗口，dtls_client_setup()
# 落在这个窗口里，返回 OK 且实际生效。服务端更简单 —— create_server() 只 bind
# 和 listen，压根没握过手。
#
#   ⚠️ 顺序是这条实现的全部要害：**必须在 `multiplayer.multiplayer_peer = peer`
#   之前调 apply_*()**。放到之后就不再返回错误、也不报警，只是没加密 —— 
#   典型的静默失效。tools/dtls_check.tscn 钉着这条。
#
# ## 为什么是 client_unsafe 而不是 client
#
# NetworkConfig.SERVER_IP 是写死的 IP，不是域名（那是 C15），所以主机名校验
# 永远过不了。client_unsafe 的"unsafe"**只指不校验 CN，不指不校验证书**：
# 实测换一张自签证书接上去，客户端报 mbedtls -0x2700（X509 证书校验失败）并
# 拒绝连接。也就是说 pin 证书这条路，服务端身份认证是**真的**成立的。
# 门禁里有这个反例用例，不是靠这段注释保证。
#
# ## fail closed
#
# 开关关着 = 明文，行为与改动上线前逐字节相同。
# 开关开着但密钥/证书拿不到 = **拒绝启动 / 拒绝连接**，绝不静默退回明文。
# 后者才是最坏结果：你以为加密了，其实没有，而且没有任何症状。

const NetTLSCert := preload("res://scripts/multiplayer/NetTLSCert.gd")

# 服务器私钥的默认位置。**只在服务器上存在**，不进 git（见 .gitignore）、
# 不进客户端包。用 --tls-key=<绝对路径> 覆盖。
const DEFAULT_KEY_PATH := "user://glory_server_key.pem"
const KEY_ARG := "--tls-key="

# 传给 dtls_client_setup 的主机名。走 client_unsafe 时不参与校验，
# 留一个可读的值只为日志。
const PIN_HOSTNAME := "glory-battle"


static func server_key_path() -> String:
	# **两个来源都要查。** `--` 之后的参数只出现在 get_cmdline_user_args()，
	# 不在 get_cmdline_args() 里。只查一个的后果是 --tls-key= 被静默忽略、
	# 回落到 user://，然后服务器报「缺私钥」—— 而你明明传了那个参数。
	# tools/handshake_check_node.gd 的 _arg() 踩过同一个坑。
	for source in [OS.get_cmdline_args(), OS.get_cmdline_user_args()]:
		for arg in source:
			if str(arg).begins_with(KEY_ARG):
				var v := str(arg).substr(KEY_ARG.length()).strip_edges()
				if not v.is_empty():
					return v
	return DEFAULT_KEY_PATH


# 客户端 pin 的那张证书。拿不到返回 null —— 调用方必须当失败处理，不能当"跳过加密"。
static func pinned_cert() -> X509Certificate:
	var pem := str(NetTLSCert.PEM).strip_edges()
	if pem.is_empty():
		return null
	var cert := X509Certificate.new()
	if cert.load_from_string(pem) != OK:
		return null
	return cert


# 服务端。**在 multiplayer_peer 赋值之前调。** 返回空串 = 成功，否则是可读的失败原因。
static func apply_server(peer: ENetMultiplayerPeer) -> String:
	var cert := pinned_cert()
	if cert == null:
		return "客户端固定证书为空或解析失败（scripts/multiplayer/NetTLSCert.gd）"
	var path := server_key_path()
	if not FileAccess.file_exists(path):
		return "缺服务器私钥 %s —— 跑 tools/dtls_make_cert.tscn 生成，或用 --tls-key= 指定" % path
	var key := CryptoKey.new()
	if key.load(path) != OK:
		return "服务器私钥读不出来：%s" % path
	var host := peer.get_host()
	if host == null:
		return "create_server 之后拿不到 ENetConnection"
	var err := host.dtls_server_setup(TLSOptions.server(key, cert))
	if err != OK:
		return "dtls_server_setup 失败：%s" % error_string(err)
	return ""


# 客户端。**在 multiplayer_peer 赋值之前调。** 返回空串 = 成功。
static func apply_client(peer: ENetMultiplayerPeer) -> String:
	var cert := pinned_cert()
	if cert == null:
		return "客户端固定证书为空或解析失败（scripts/multiplayer/NetTLSCert.gd）"
	var host := peer.get_host()
	if host == null:
		return "create_client 之后拿不到 ENetConnection"
	var err := host.dtls_client_setup(PIN_HOSTNAME, TLSOptions.client_unsafe(cert))
	if err != OK:
		return "dtls_client_setup 失败：%s" % error_string(err)
	return ""
