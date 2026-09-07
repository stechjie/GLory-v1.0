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
cp backend/.env.example backend/.env
```

然后**自己**编辑 `backend/.env` 填入真实的值。`.env` 已在 `.gitignore` 里。
`.env.example` 只有键名没有值，那个是进 git 的。

从哪里拿这些值：Supabase Dashboard → Project Settings → API。

## 跑起来

```bash
cd backend && .venv/Scripts/python -m uvicorn app.main:app --reload --port 8099
```

然后打开 http://127.0.0.1:8099/health

没填 `.env` 也能起来 —— 这是刻意的，骨架要能在还没建 Supabase 项目时单独验证。
`/health` 会如实报告哪些配置项还缺：

```json
{"status":"ok","environment":"dev","configured":false,
 "missing_config":["GLORY_SUPABASE_URL","GLORY_SUPABASE_PUBLISHABLE_KEY","GLORY_SUPABASE_SECRET_KEY"]}
```

**它只报键名，绝不报值** —— health 端点通常对外可达。有一条测试专门钉着这件事。

开发模式下 http://127.0.0.1:8099/docs 有交互式接口文档。生产模式（`GLORY_ENVIRONMENT=prod`）会关掉它。

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
    config.py       环境变量读取。代码里不写任何密钥
    main.py         FastAPI 入口 + /health
  tests/
    test_health.py  第一条门禁
```

## 环境

Python 3.14.5 上验过。FastAPI 0.141 / uvicorn 0.52 / pydantic 2.13 都有对应 wheel。

Windows 上 `main.py` 会把 stdout/stderr 拧成 UTF-8 —— 默认的 cp1252 控制台
会把中文日志转义成 `以...`。

## 进度

| 步骤 | 状态 |
|---|---|
| 1. 骨架 + 配置 + `/health` | ✅ |
| 2. 接上 Supabase，验证三张表 | ⬜ |
| 3. `POST /v1/auth/anonymous` | ⬜ |
| 4. JWT 验签 + `GET /v1/me` | ⬜ |
| 5. Godot `AccountManager.gd` | ⬜ |
| 6. 完整门禁 | ⬜ |
