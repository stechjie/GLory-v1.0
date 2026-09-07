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
