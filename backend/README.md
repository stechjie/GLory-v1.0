# Glory Backend

四层架构里的 **②**（见 `docs/账号系统RFC.md` 第三节）：

```
① Godot ── HTTPS ──> ② 这里 ──> ④ Supabase (Auth + PostgreSQL)
① Godot ── ENet  ──> ③ 战斗服务器（另一条链路）
```

## 三条不能破的规矩

1. **Godot 永远不直连 Supabase。** 客户端只认 `AccountManager` 这一个门面，打到这里。
   换后端时要改的是这一层，不是几十个 `.gd` 文件。
2. **金币 / 钻石 / 抽卡 / 商城 / Rank / 奖励只能由这一层修改。** 客户端和 RLS 都不是权威。
3. **secret key 只存在这台服务器上。** 不进 Godot、不进 APK、不进 git。它绕过 RLS。

## 首次设置

```bash
python -m venv backend/.venv
backend/.venv/Scripts/python -m pip install -r backend/requirements.txt
```

然后把 `backend/.env.example` 复制一份成 `backend/.env`：

| shell | 命令 |
|---|---|
| Git Bash / macOS / Linux | `cp backend/.env.example backend/.env` |
| Windows cmd.exe | `copy backend\.env.example backend\.env` |
| PowerShell | `Copy-Item backend\.env.example backend\.env` |

然后**自己**编辑 `backend/.env` 填入真实的值。`.env` 已在 `.gitignore` 里。
`.env.example` 只有键名没有值，那个是进 git 的。

从哪里拿这些值：URL 与两个 key 在 Dashboard → Project Settings → API Keys；
数据库连接串在顶部的 **Connect** 按钮里。

## 跑起来

```bash
cd backend && .venv/Scripts/python -m uvicorn app.main:app --reload --port 8099
```

然后打开 http://127.0.0.1:8099/health

没填 `.env` 也能起来 —— 这是刻意的，骨架要能在还没建 Supabase 项目时单独验证。
`/health` 会如实报告哪些配置项还缺：

```json
{"status":"ok","environment":"dev","configured":false,
 "missing_config":["GLORY_SUPABASE_URL","GLORY_SUPABASE_PUBLISHABLE_KEY",
                   "GLORY_SUPABASE_SECRET_KEY","GLORY_DATABASE_URL"]}
```

**它只报键名，绝不报值** —— health 端点通常对外可达。有一条测试专门钉着这件事。

开发模式下 http://127.0.0.1:8099/docs 有交互式接口文档。生产模式（`GLORY_ENVIRONMENT=prod`）会关掉它。

## 自检：`/v1/debug/schema`

**只在 `GLORY_ENVIRONMENT=dev` 时挂载。**

```
http://127.0.0.1:8099/v1/debug/schema
```

它不是"随便看看"的调试口，而是把 RFC 第三节的两条硬规则变成一眼能验证的东西：

1. `database/` 下的三张表都建出来了
2. 每张都开了 RLS，且 **policy 数为 0**

第 2 条尤其值得自动检查。零 policy 是刻意的 —— Godot 不直连 Supabase，一切经
FastAPI（secret key 绕过 RLS），所以零 policy 意味着通过 Data API 谁都读不到。
哪天有人在 Dashboard 上顺手加一条 policy「临时调试一下」，这里会立刻显示，
而不是等数据被客户端读走才发现。

全对时：

```json
{"ok": true, "problems": [],
 "tables": [{"table":"players","exists":true,"rls_enabled":true,"policy_count":0}, ...]}
```

没配 `GLORY_DATABASE_URL` 时返回 **503**（配置问题），不是 500（服务器出错）。
这个区分是刻意的：503 告诉你少配了东西，500 会让人去翻代码找 bug。

## 为什么直连 PostgreSQL，不走 PostgREST

账号层以后要做钱包与充值，那些是「要么全做、要么不做」的多语句事务 ——
同 `scripts/multiplayer/EconomyLedger.gd` 的设计原则 3：

> 任何一步校验失败都返回 `ok=false` 且**不修改 prep**。半执行的交易是账本类
> 代码最经典的坑。

PostgREST 给不了多语句事务。直连还让迁移只需要换一条连接串，符合 RFC 第二节
「尽量使用标准 PostgreSQL」。

**Supabase Auth 仍然走它自己的 REST 接口。** 这正是 RFC 的分工：
Auth 是可替换的身份提供方，数据库是标准 PostgreSQL。

连接串选 **Session pooler** 或 **Direct connection**，不要 Transaction
pooler（端口 6543）—— 那是 pgbouncer transaction 模式，与 asyncpg 的预编译
语句缓存冲突，症状是随机的 `prepared statement ... does not exist`，很难查。
`db.py` 检测到 6543 会自动关掉语句缓存兜底，但选对那条更省事。

## 登录接口

| 接口 | 什么时候调 |
|---|---|
| `POST /v1/auth/anonymous` | 客户端**手上没有** refresh token 时（第一次装、或清了数据） |
| `POST /v1/auth/refresh` | 之后每次启动 |

```
有 refresh token -> /refresh；失败(401)或没有 -> /anonymous
```

⚠️ **`/anonymous` 天然不幂等** —— 每次调用都在 Supabase 建一个新的匿名用户，
也就多一个玩家。客户端拿到 refresh token 后必须走 `/refresh`，
否则每次启动都会多一个账号。

⚠️ **Supabase 默认轮换 refresh token** —— `/refresh` 返回的那个和传入的不同。
客户端必须存回返回的那个，否则下次刷新失败。

请求可以带上客户端签发的 `player_id`（`SaveSchema.new_player_id`）。带了的好处是
本地存档与服务器账号从第一天起就是同一个 id，不会出现「两个 player_id」的歧义。
它**不是**身份凭证 —— 能不能登录完全由 Supabase 的 auth_uid 决定；
如果那个 id 已被占用，返回 409 让客户端重签，而不是接管别人的账号。

`players` 与 `player_identities` 在**同一个事务**里创建。半执行的后果很具体：
只建了 players 没建映射，玩家下次登录就解析不到自己 —— 账号等于丢了，
而那行还占着。外键挡不住这个方向，只能靠事务。

## 令牌校验与 `GET /v1/me`

第 3 步是**发**令牌，这里是**收**。之后所有「需要知道你是谁」的接口都用同一条路：

```
Authorization: Bearer <access_token>
   -> 验签拿到 auth_uid (sub)
   -> 查 player_identities 拿到 player_id
   -> 之后一切游戏数据都用 player_id
```

实测这个项目签发的令牌是 **ES256 非对称签名**，公钥在
`/auth/v1/.well-known/jwks.json`。所以后端**不需要任何 JWT 密钥** ——
只用公钥验签，密钥轮换靠重拉 JWKS（收到未知 `kid` 时提前刷新，
但有最小间隔保护，否则随机 kid 的令牌就能让我们不停打 Supabase）。

### ⛔ 算法白名单绝不能加 HS256

`ALLOWED_ALGORITHMS = ["ES256", "RS256"]`。**改这一行前先想清楚。**

这是 JWT 最经典的洞（algorithm confusion）：验签方同时接受非对称和对称算法时，
攻击者可以拿那把**公开的**公钥当 HMAC 密钥去签一个 HS256 令牌。公钥就在
jwks.json 里人人可取 —— 于是任何人都能伪造任意 `sub`，也就是任意玩家的身份。

`test_hs256_forgery_is_rejected` 钉着这条。注意那个用例是**手工拼字节**造的
伪造令牌 —— PyJWT 在编码侧就拒绝拿 PEM 公钥当 HMAC 密钥，但那保护不了验签方，
攻击者不会用我们的库。

一并校验的还有 `iss`（挡别的 Supabase 项目签的令牌）、`aud`、`exp`，
以及 `require` 里那几个必需 claim（不给「某项恰好缺失所以被跳过」留空间）。

### `/v1/me` 只读不建

令牌有效但查不到玩家 → **404，不自动补建**。建账号只有
`/v1/auth/anonymous` 一条路，多一条就多一个可以绕开的入口。

## 日志

`main.py` 里的 `_configure_logging()` 给 `glory.*` 装 handler。**不做这一步，
应用自己的 `log.info()` 会被完全吞掉** —— uvicorn 只配置它自己的 logger，
只有 WARNING 以上才会经 logging 的 lastResort 漏到 stderr。

这个坑很安静：代码里写满 log.info，跑起来一条都看不到，而你以为记了。
实测踩过 —— 登录成功那条始终不出现，一度以为是没执行到。

登录日志**只记 `player_id`，不记任何 token**。实测审计过：
一次完整登录+刷新的日志里，`eyJ`（JWT 前缀）、`Bearer`、`sb_secret`、
`postgresql://` 全部零命中。

## 测试

```bash
cd backend && .venv/Scripts/python -m pytest -q
```

必须**从 `backend/` 目录跑** —— `pytest.ini` 在那里，`app` 包靠它的 `pythonpath` 才找得到。

`pytest.ini` 里 `filterwarnings = error`：警告一律当错误。理由和 `docs/CHECKS.md`
那套一样 —— 不留假绿，依赖弃用要当场看见，而不是在某次升级后突然炸掉。
例外只给我们改不了的第三方内部弃用，每条都写了出处，依赖升级后要回来重新确认。

## 目录

```
backend/
  .env.example      配置模板（只有键名）— 进 git
  .env              真实密钥 — 不进 git
  requirements.txt  锁定版本，pip freeze 生成
  pytest.ini        测试配置
  app/
    config.py         环境变量读取。代码里不写任何密钥
    db.py             asyncpg 连接池 + 表结构自检
    supabase_auth.py  **全后端唯一知道 Supabase 存在的文件**。换 Auth 只改这里
    jwt_verify.py     令牌验签（JWKS / ES256）。算法白名单在这里
    players.py        players / player_identities 的读写（含事务）
    main.py           FastAPI 入口 + /health + 日志配置
    routes/
      auth.py         /v1/auth/anonymous + /refresh
      me.py           /v1/me + current_claims 依赖
      debug.py        /v1/debug/schema（仅 dev）
  tests/
    test_health.py        /health 不泄漏密钥
    test_debug_schema.py  未配置时干净拒绝 + 迁移文件与检查清单一致
    test_auth.py          错误信息不带 token + 匿名登录没开时的提示
    test_jwt_verify.py    **算法混淆伪造被拒** + 签发方/受众/过期/未知 kid
```

## 环境

Python 3.14.5 上验过。FastAPI 0.141 / uvicorn 0.52 / pydantic 2.13 / asyncpg 0.31 都有对应 wheel。

Windows 上 `main.py` 会把 stdout/stderr 拧成 UTF-8 —— 默认的 cp1252 控制台
会把中文日志转义成 `以...`。

## 进度

| 步骤 | 状态 |
|---|---|
| 1. 骨架 + 配置 + `/health` | ✅ |
| 2. 接上 Supabase，验证三张表 | ✅ 实测通过（三张表 / RLS 全开 / policy 数 0） |
| 3. `POST /v1/auth/anonymous` + `/refresh` | ✅ 实测通过（真实 Supabase） |
| 4. JWT 验签 + `GET /v1/me` | ✅ 实测通过（真实令牌 + 四类反例） |
| 5. Godot `AccountManager.gd` | ✅ 实测通过（两次启动，第二次走 refresh） |
| 6. 完整门禁 | ⬜ |
