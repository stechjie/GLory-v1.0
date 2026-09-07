extends RefCounted

# 账号后端（Glory Backend / FastAPI）的地址。
#
# 与 NetworkConfig 同样的定位：**这里只放公开信息，绝不放任何密钥。**
# publishable key、secret key、数据库密码一律不进 Godot 工程 —— 客户端不直连
# Supabase，一切经过后端（见 docs/账号系统RFC.md 第三节）。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md，
# 以及 SessionContext.gd 顶部同样的说明）。

# 本机开发默认值。上线前必须换成真实域名。
#
# ⚠️ 真机上这个地址是连不通的：
#   1. 127.0.0.1 在手机上指的是手机自己，不是你的开发机；
#   2. Android 9+ 默认禁止明文 HTTP。
# 真机联调用 --backend-url=http://<开发机局域网IP>:8099，并临时放开明文；
# 正式环境一律 https。
const DEFAULT_BACKEND_URL := "http://127.0.0.1:8099"

# 命令行覆盖，方便在不改代码的前提下切环境（同 DeviceHarness 的 --device-baseline）。
const BACKEND_URL_FLAG := "--backend-url="

# --- 启动时自动登录 -----------------------------------------------------------
#
# **默认关闭。** 同 ServerFlags 对 P1 经济账本的做法：功能先接上、开关先关着。
#
# 现在打开是错的，两条具体理由：
#   1. 后端只在开发机的 localhost 上跑。默认打开的话，任何没起后端的人
#      （你同事、CI、拿到包的测试）每次启动都会看到一次登录失败。
#   2. 账号目前**不承载任何东西** —— 没有云端资料、没有账号 UI。
#      真出包的话，每个玩家会白建一个 Supabase 账号，一点用都没有，
#      还要占 MAU 额度。
#
# 翻成 true 的前提：后端已经部署，且 DEFAULT_BACKEND_URL 指向它（联机审计的
# C15 部署那一步）。在那之前用 --account 单次打开来联调。
const AUTO_LOGIN_DEFAULT := false
const AUTO_LOGIN_ON_FLAG := "--account"
const AUTO_LOGIN_OFF_FLAG := "--no-account"

static func auto_login_enabled() -> bool:
	var args := OS.get_cmdline_args()
	# 关的优先：显式说了不要，就绝不要。
	if AUTO_LOGIN_OFF_FLAG in args:
		return false
	if AUTO_LOGIN_ON_FLAG in args:
		return true
	return AUTO_LOGIN_DEFAULT

# 单次请求超时。比战斗链路宽松 —— 这些请求发生在启动阶段，
# 宁可多等两秒也不要在弱网上把玩家直接判成登录失败。
const REQUEST_TIMEOUT_SEC := 15.0

static func backend_url() -> String:
	for arg in OS.get_cmdline_args():
		if arg.begins_with(BACKEND_URL_FLAG):
			var value := arg.substr(BACKEND_URL_FLAG.length()).strip_edges()
			if not value.is_empty():
				return value.rstrip("/")
	return DEFAULT_BACKEND_URL.rstrip("/")

static func endpoint(path: String) -> String:
	return backend_url() + path
