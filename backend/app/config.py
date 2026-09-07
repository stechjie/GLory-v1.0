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

    environment: str = "dev"

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
        }
        return [name for name, value in required.items() if not value.strip()]


@lru_cache
def get_settings() -> Settings:
    """进程内只读一次。测试里要换配置就 get_settings.cache_clear()。"""
    return Settings()
