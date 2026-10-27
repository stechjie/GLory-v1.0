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

    # Empty site keeps existing deployments unchanged until Firebase is provisioned.
    patch_firebase_site: str = ""
    patch_directory: str = "/var/lib/glory-patches"
    # Narrow unattended publisher credential; only patch draft creation/uploads use it.
    patch_automation_token: str = ""
    patch_deployment_id: str = ""
    patch_godot_binary: str = ""
    patch_enforce_versions: bool = False
    patch_gameplay_channel: str = "stable"
    patch_battle_desired: str = ""
    patch_battle_status: str = ""
    patch_battle_instance: str = "main"

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

    # --- 出战名片（app/loadout.py，docs/商城系统设计.md 第五节）------------------
    #
    # 给名片盖章用的 RSA 私钥文件（PEM）。战斗服务器只持对应的**公钥**
    # （它自己机器上的 battle_card_public.pem，见 scripts/multiplayer/BattleCard.gd），
    # 被拿下也伪造不了名片。
    #
    # 放文件而不是放进 backend.env：PEM 是多行的，systemd 的 EnvironmentFile
    # 处理多行值很别扭。生产上由 glory-backend.service 设成 /opt/glory/battle_card_key.pem，
    # 生成工具是 deploy/make_battle_card_key.py。
    #
    # ⚠️ 这把**可以**重新生成（旧名片最多再活一个有效期）—— 和战斗服务器那把
    # 绝不能重生成的 DTLS 私钥（deploy/BATTLE_SERVER_KEY.md）是两回事。
    # 空 = 没配置，发名片的接口回 503。
    battle_card_key_file: str = ""

    # --- 战报（app/battle_report.py，docs/排位系统设计.md 第七节）----------------
    #
    # 验战报用的 RSA **公钥**文件（PEM）。和上面那把名片私钥**方向正好相反**：
    # 名片是这边签、战斗服务器验；战报是战斗服务器签、这边验。
    # 所以战报的**私钥在战斗服务器那台机器上**，这边只有公钥，被拿下也伪造不了战报。
    #
    # 生成工具 deploy/make_battle_report_key.py 在**战斗服务器**上跑，
    # 把它打印出来的公钥送到这边。
    #
    # 空 = 没配置，交战报的接口回 503。此时对局照常进行，只是不记历史 ——
    # 战斗服务器那边缺私钥也是同样的态度（scripts/multiplayer/BattleReport.gd 的
    # 「没有钥匙不拒绝启动」一节）。
    battle_report_public_key_file: str = ""

    # --- 公告（app/announcements.py，docs/公告系统设计.md）-----------------------
    #
    # 公告图片所在的 Supabase Storage 桶。**必须设成公开**：服务器按公开地址取图，不带任何密钥。
    announcement_bucket: str = "announcements"

    # 服务器取回、检查过的公告图片放在哪。空 = 不处理图片（公告照常显示，只是没图，
    # 并在那一行的 problem 列里写明原因）。生产上由 glory-backend.service 的 StateDirectory 建好并设置。
    media_dir: str = ""

    # Same LiveKit JSON shape as the battle server; secret stays server-side.
    party_voice_config_file: str = ""

    # --- 测试开关：忽略排位时间窗口（app/ranked.py 的 accepting_now）------------
    #
    # True = 任何时候都能排位。和上面 disable_instance_lock 同类：
    # 它存在只为两件事 —— 跑测试，以及白天要调排位流程的时候。
    #
    # 🔴 **生产上打开它等于把排位时间窗口整个关掉**（docs/排位系统设计.md 第二节
    # 那条产品规则没了），而且没有任何报错 —— 症状就是「半夜也能排」。
    #
    # 它**不改** ranked.window_state()：那个函数继续如实返回真实时间表，
    # 所以 /v1/match/window 不会说谎、test_ranked.py 的逐小时断言也不受影响。
    # 读它的只有两道闸，都走 ranked.accepting_now()。
    ranked_window_always_open: bool = False

    # --- 排位全天开放（2026-10-19）---------------------------------------------
    #
    # 玩家还少，只开 19:00–23:00 的话新玩家多数时候根本排不了。True = 全天都能排位；
    # 人多了改回 False 就恢复时间窗口。与上面那个测试开关不同，这是**产品配置**：
    # /v1/match/window 会如实说「现在开着」，客户端不会出现倒计时与行为对不上。
    ranked_all_day: bool = True

    # --- 人少时 AI 补位（app/matchmaking.py「人少时 AI 补位」那节）--------------
    #
    # Enables AI fill for every queue. All modes form teams first.
    # Seedling waits 10 seconds; Normal and Ranked wait 30 seconds.
    # The legacy duration field is retained for config compatibility; mode deadlines are fixed.
    match_ai_fill: bool = True
    match_ai_fill_after_sec: float = 10.0

    # --- 组队开局人数（app/party.py 的 startable_sizes）------------------------
    #
    # True = 组队房只能单人或满 3 人开始匹配（docs/排位系统设计.md 第五节「不做 2 人车队」：
    # 2+1 里那个路人是局外人，队里还有语音）。休闲、排位同一个口径。
    #
    # 默认 False = 2 人也能开：10-15 用户定，现在玩家太少，先放开，人够了再打开。
    # 客户端按房间快照里的 startable_sizes 决定按钮灰不灰，所以翻这个开关**不用出新包**，
    # 改 .env 后重启账号服务器即可（重启会清空匹配队列，别在高峰期）。
    party_full_team_only: bool = False

    # --- 对局名册（app/service_control.py，OPS-05）------------------------------
    #
    # 战斗服务器每 5 秒往这里写一份「此刻谁真的在打」（同机文件，
    # 写方见 scripts/multiplayer/DedicatedServerService.gd 的 write_match_roster）。
    # 维护时判断谁不能踢，先认它；读不到或太旧就退回 match_entries 那个启发式。
    #
    # 两个服务在同一台机器上（glorytd-api / glorytd-battle 解析到同一个 IP），
    # 所以走文件而不是网络调用 —— 和补丁服务的 desired/status 桥同一个形状。
    # 空 = 不读，一切照旧（退回启发式）。
    battle_match_roster_file: str = ""

    # --- Steam 登录（app/steam_oidc.py，docs/三方登录设计.md 第八节）-------------------
    #
    # Supabase 不认识 Steam。账号服务器验完 Steam 的票之后，自己签一张短时的身份证明，
    # 交给 Supabase 里登记的自定义提供方 custom:steam —— Steam 就和 Google 走同一条路。
    #
    # 签名私钥（EC P-256，PEM）。由 deploy/update.sh 第一次跑时用 deploy/make_steam_oidc_key.py
    # 生成到 /opt/glory/steam_oidc_key.pem 并写进 backend.env。**可以重新生成**：身份证明签完
    # 当场就用掉，换钥匙不影响任何已登录的人。空 = 没配置，签发方的公开地址回 503。
    steam_oidc_key_file: str = ""
    # 签发方地址，必须和 Supabase 里登记的 Issuer 一字不差，形如 https://glorytd-api.duckdns.org/oidc/steam。
    # update.sh 从 Caddyfile 的域名推出来写进 backend.env。
    steam_oidc_issuer: str = ""
    # 身份证明里的 aud。和 Supabase 里那个自定义提供方的 Client ID 一致即可，不是密钥。
    steam_oidc_client_id: str = "glory-steam"

    # Steam 上的 App ID（Steamworks 后台的 Glory，公开数字）。验票时要带上。
    steam_app_id: int = 4919850
    # ⛔ 发行商 Web API 密钥（Steamworks → Users & Permissions → Manage Groups → 组页面 → Create WebAPI Key）。
    # 和 secret key 同级：只放服务器的 backend.env，绝不进 git、APK、聊天。空 = Steam 登录回 503。
    steam_web_api_key: str = ""
    # 游戏向 Steam 要票时填的 identity（GetAuthTicketForWebApi 的参数），两边必须一字不差。
    # Steam 只放行用同一个 identity 开出来的票，别的服务拿到这张票也用不了。
    steam_ticket_identity: str = "glory-account"

    # --- 充值（app/iap.py，docs/充值系统设计.md）----------------------------------------
    #
    # 每个平台一个开关，默认关。🔴 **关掉只挡「建新单」**：confirm、平台通知、定时对账一律照常 ——
    # 不然已经付了钱的单就卡死在半路。出了问题先关开关、重启账号服务器，不用出包。
    iap_google_enabled: bool = False
    iap_apple_enabled: bool = False
    iap_steam_enabled: bool = False

    # Play Console 里那个 App 的包名。
    google_play_package: str = "com.glory.game.google"
    # ⛔ Google Cloud 服务账号 glory-play-billing 的 JSON 密钥文件（里面有私钥）。
    # 放 /opt/glory/，只放服务器，绝不进 git、聊天。这个服务账号要在 Play Console 的
    # 「用户和权限」里给「查看财务数据」和「管理订单」。空 = Google 核实回 503。
    google_play_service_account_file: str = ""
    # Google 实时通知（Pub/Sub 推送到 /iap/google/rtdn）的身份：推送订阅里「启用身份验证」时选的
    # 服务账号邮箱，和填的「受众」（没填的话 Google 用推送地址本身）。两样都对上才认，
    # 不然谁都能往这个公开地址 POST 一条「已退款」。任一空着 = 推送回 503（Pub/Sub 会一直重试，配好后自动补上）。
    google_rtdn_service_account: str = ""
    google_rtdn_audience: str = ""

    # iOS 的 bundle id（tools/workspace/glory_ios_build.py 的 BUNDLE）。签名交易里的必须是它。
    apple_bundle_id: str = "com.superforge.glory"
    # Apple Root CA - G3 证书文件（https://www.apple.com/certificateauthority/AppleRootCA-G3.cer，
    # DER 或 PEM 都行）。验签名交易时钉住它：证书链必须一路签到这一张。公开文件，不是密钥。
    # 空 = Apple 核实回 503。
    apple_root_cert_file: str = ""

    # 走 Steam 沙盒（ISteamMicroTxnSandbox，不扣钱）的测试员 Steam 编号，逗号分隔。
    # 这些人下的单记成测试单（docs/充值系统设计.md 第八节）。
    steam_sandbox_steam_ids: str = ""

    # 测试单（许可测试员、TestFlight、Apple 审核员、Steam 沙盒）每个号 24 小时内最多入账几张。
    # 🔴 **正式上线前必须是 1。** TestFlight 上的人买东西不花钱，又连着正式服 —— 调大就是让他们多白拿。
    # 只在自己测充值流程、要连着买好几次的那几天调大，测完改回来、重启账号服务器。
    iap_test_orders_per_day: int = 1

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
