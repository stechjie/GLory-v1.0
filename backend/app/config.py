"""配置。全部从环境变量 / backend/.env 读，代码里不写任何密钥。

键名统一带 GLORY_ 前缀，避免和机器上别的服务撞名。模板见 backend/.env.example。
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_prefix="GLORY_",
        extra="ignore",
    )

    # 形如 https://abcdefghijkl.supabase.co
    supabase_url: str = ""

    # 可下发到客户端的公开 key。用于注册 / 登录这类公开操作。
    supabase_publishable_key: str = ""

    # ⛔ 服务端专用，绕过 RLS。绝不进 Godot / APK / git。
    supabase_secret_key: str = ""

    # PostgreSQL 连接串（含数据库密码）。⛔ 与 secret key 同级，绝不外泄。
    #
    # 直连 Postgres 而不是走 Supabase 的 PostgREST：账号层以后要做钱包与充值，
    # 那些是「要么全做、要么不做」的多语句事务，PostgREST 给不了。
    # 直连也让迁移只需要换这一条串。Auth 仍然走 Supabase 的 REST 接口 ——
    # 这正是 RFC 的分工：Auth 可替换，数据库是标准 PostgreSQL。
    database_url: str = ""

    environment: str = "dev"

    # 限流额度。默认对**账号创建**收得很紧 —— 一个正常玩家一辈子只需要注册一次，
    # 频繁注册只会是脚本或误接线（例如客户端把 refresh 走成了 anonymous）。
    # 刷新宽松得多：那是每次启动、以及令牌过期时的正常动作。
    # 本机调试要连开多个账号时把 anonymous 那个调大即可。
    rate_limit_anonymous_per_hour: int = 10
    rate_limit_refresh_per_hour: int = 120

    # --- WebSocket 单实例（docs/聊天系统设计.md 批次 B）------------------------
    #
    # WS 连接表在进程内存里，所以 ② 从此**必须单进程单实例**。
    # 启动时抢这个回环端口当令牌，抢不到就拒绝启动。理由见 app/single_instance.py。
    instance_lock_port: int = 48099

    # ⚠️ **生产上打开它等于把单实例保护整个关掉**，那时候的症状是
    # 「一部分玩家收不到消息」，而且没有任何报错。
    # 它存在只为两件事：跑测试，以及本机想同时开两份服务时。
    disable_instance_lock: bool = False

    # --- 同时在线上限与排队（app/admission.py）--------------------------------
    #
    # 数的是登录着、连着 WebSocket 的玩家；超过的人在启动画面排队。
    # ⚠️ 1000 是 2026-09-14 的暂定值，还没按线上机器实测校准。
    online_limit: int = 1000

    # 可热改的上限文件，内容形如 {"online_limit": 400}。每 5 秒看一次修改时间，改了就生效，
    # 不用重启（重启会清空队列）。空 = 不读文件。生产上由 glory-backend.service 设置。
    admission_file: str = ""

    @property
    def is_dev(self) -> bool:
        return self.environment != "prod"

    def missing_keys(self) -> list[str]:
        """返回还没配的必填项。用于启动自检与 /health 上报。

        只返回**键名**，永远不返回值 —— 这个结果会出现在日志和 HTTP 响应里。
        """
        required = {
            "GLORY_SUPABASE_URL": self.supabase_url,
            "GLORY_SUPABASE_PUBLISHABLE_KEY": self.supabase_publishable_key,
            "GLORY_SUPABASE_SECRET_KEY": self.supabase_secret_key,
            "GLORY_DATABASE_URL": self.database_url,
        }
        return [name for name, value in required.items() if not value.strip()]


@lru_cache
def get_settings() -> Settings:
    """进程内只读一次。测试里要换配置就 get_settings.cache_clear()。"""
    return Settings()
