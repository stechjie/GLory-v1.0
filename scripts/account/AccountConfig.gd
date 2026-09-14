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

# 线上账号后端。部署与运维见 deploy/README.md。
#
# **必须是 https。** 这条链路上跑的是账号凭证（JWT 与 refresh token），
# 明文过公网等于把账号发出去。而且 Android 9+ 默认就禁止明文 HTTP。
#
# 本机联调不改这里，用命令行覆盖：
#   --backend-url=http://127.0.0.1:8099          （开发机自己）
#   --backend-url=http://192.168.x.x:8099        （手机连开发机，需临时放开明文）
const DEFAULT_BACKEND_URL := "https://glorytd-api.duckdns.org"

# 命令行覆盖，方便在不改代码的前提下切环境（同 DeviceHarness 的 --device-baseline）。
const BACKEND_URL_FLAG := "--backend-url="

# --- 启动时自动登录 -----------------------------------------------------------
#
# **2026-09-09 起默认开启。** 之前关着的理由是「后端还没部署」，
# 后端上线并从外网验证通过之后那条不再成立。
#
# 打开之后的实际行为，需要知道：
#   1. 玩家首次启动会**自动注册一个匿名账号**（本地没凭证 → /v1/auth/anonymous）。
#      账号目前不承载任何东西，所以这只意味着 players 表会开始攒行、
#      Supabase 的 MAU 额度会被占用。
#   2. **2026-09-14 起登录是进游戏的必经之路**：启动画面要等登录成功、并且账号后端
#      放行（同时在线上限与排队，backend/app/admission.py）才进主界面。登录失败或
#      连不上账号后端时停在启动画面自动重试，**不放行**（已定：连不上就不让进）。
#      --no-account 会连这道门一起关掉，只给本机调试用。
#
# 单次关闭用 --no-account（关的优先级高于 --account）。
const AUTO_LOGIN_DEFAULT := true
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
