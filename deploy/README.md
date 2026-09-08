# 账号后端部署手册

部署的是 **② Game Backend**（FastAPI），不是战斗服务器。

```
玩家手机 ──HTTPS:443──> Caddy ──> uvicorn(127.0.0.1:8099) ──> Supabase
玩家手机 ──ENet:8080──> Godot headless（战斗服务器，另一套流程）
```

**这两个跑在同一台机器上，但互不相干**：不同端口、不同进程、不同部署流程。
战斗服务器的打包与部署是 `docs/联机审计与整改方案.md` 第八节的 `C15`，与本文无关。

---

## 一次性准备（人工，脚本不代劳）

### 1. 域名

DuckDNS（免费）或自己的域名，A 记录指向服务器 IP。

证书由 Caddy 自动申请与续期 —— 你不用碰证书。**但它要求域名先解析到这台机器**，
不然申请会失败。先确认：

```bash
dig +short 你的域名        # 应当返回服务器 IP
```

### 2. 防火墙

GCP Console → VPC network → Firewall，放开 **tcp:80 和 tcp:443**。

- 80：Caddy 申请证书要用（HTTP-01 挑战）
- 443：对外服务

**8099 不要对外开放。** 后端只监听 `127.0.0.1`，外面本来也进不来 ——
开了反而是给自己开一个绕过 HTTPS 的明文入口。

---

### 3. 部署密钥（仓库是私有的）

服务器要拉私有仓库，得有一把钥匙。用 **deploy key** 而不是 token：
它只对这一个仓库有效、只读、不过期。服务器被攻破时，别人也只能读这个仓库，
碰不到 GitHub 账号的任何其它东西。

在服务器上生成：

```bash
sudo ssh-keygen -t ed25519 -C "glory-server deploy" -f /root/.ssh/glory_deploy -N ""
sudo tee -a /root/.ssh/config >/dev/null <<'EOF'
Host github.com
  IdentityFile /root/.ssh/glory_deploy
  IdentitiesOnly yes
EOF
sudo cat /root/.ssh/glory_deploy.pub
```

把最后打印的那一行（**公**钥，可以公开）加到
`https://github.com/stechjie/GLory-v1.0/settings/keys` →
**Add deploy key**，**不要勾 Allow write access**。

验证：

```bash
sudo ssh -T git@github.com
```

看到 `Hi stechjie/GLory-v1.0! You've successfully authenticated...` 就对了
（它接着会说 `does not provide shell access`，那是正常的）。

---

## 首次安装

在服务器上：

```bash
sudo git clone git@github.com:stechjie/GLory-v1.0.git /opt/glory/src
sudo bash /opt/glory/src/deploy/bootstrap.sh 你的域名
```

代码拉到 `/opt/glory/src`（git 检出，root 所有），
`bootstrap.sh` 再把 `backend/` 和 `deploy/` 复制到 `/opt/glory/repo` 作为运行目录。

分成两个目录是有理由的：git 检出里有整个游戏工程（客户端代码、美术引用），
运行目录只放后端真正要用的东西，少一份暴露面。

脚本做完之后**服务还不会起来** —— 密钥是空的。这是刻意的。

### 填密钥

```bash
sudo nano /opt/glory/backend.env
```

四项，值从 Supabase Dashboard 取（同本机 `backend/.env` 那四项）：

```
GLORY_SUPABASE_URL=
GLORY_SUPABASE_PUBLISHABLE_KEY=
GLORY_SUPABASE_SECRET_KEY=
GLORY_DATABASE_URL=
GLORY_ENVIRONMENT=prod
```

> `GLORY_ENVIRONMENT=prod` 会关掉 `/docs` 与 `/v1/debug/*`。
> 生产上不该把接口形状和表结构白送出去。

这个文件是 `chmod 600`、属主 `glory`。**不进 git，不要复制到别处，不要贴进聊天。**

### 启动

```bash
sudo systemctl start glory-backend
curl https://你的域名/health
```

看到 `"configured": true` 就成了。

---

## 日常更新

```bash
sudo bash /opt/glory/src/deploy/update.sh
```

它会 `git pull` 到最新，再同步到运行目录、装依赖、重启、验收。

用 `git reset --hard` 而不是解压覆盖：git 会**删掉**新版本里已移除的文件。
审计文档第八节点名批评过 `unzip -o` 覆盖在线目录 —— 它留下新旧混合版本，
而混合版本的故障最难查。

---

## 排查

| 症状 | 先看这里 |
|---|---|
| `curl https://域名/health` 超时 | 防火墙 80/443；`dig` 确认域名解析对了 |
| 证书申请失败 | `sudo journalctl -u caddy -n 50`。多半是 80 没开或域名没解析过来 |
| 502 Bad Gateway | 后端没起。`sudo systemctl status glory-backend` |
| `"configured": false` | `backend.env` 有项没填。**响应里只会报键名，不会报值** |
| 500 | `sudo journalctl -u glory-backend -n 50 --no-pager` |

后端日志只记 `player_id`，**不记任何 token**（有测试钉着）。

---

## 几处刻意的设计

**uvicorn 只监听 `127.0.0.1`。**
对外由 Caddy 终结 TLS。直接对外监听等于开一个明文 HTTP 端口，
任何人都能绕过 HTTPS 直连 —— 而这条链路上跑的是账号凭证。

**单 worker。**
限流计数在进程内存里（`backend/app/rate_limit.py`），多 worker 会让实际额度
按 worker 数翻倍。要加 worker 必须先把限流换成 Redis 或挪到代理层。
现阶段单进程的吞吐绰绰有余 —— 登录是每人每天几次，不是每帧都打的接口。

**不用 root 跑。**
这个进程持有 Supabase secret key 与数据库密码，被攻破时不该连整台机器一起交出去。

---

## ⚠️ 已知限制：限流现在是全体共用一个额度

后端**刻意不读** `X-Forwarded-For`（见 `backend/app/rate_limit.py` 顶部）——
那个头客户端可以随便写，盲信等于限流白做。

但过了 Caddy 之后，后端看到的来源 IP 全是 `127.0.0.1`，
于是**所有玩家共用一个限流额度**。

- 现在（内部测试）：无所谓
- **真开放注册前必须处理**：让后端只信任来自 `127.0.0.1` 的
  `X-Forwarded-For`，改完再打开 Caddyfile 里那一行

这是当前的已知限制，不是遗漏。

---

## 部署之后要改客户端

`scripts/account/AccountConfig.gd`：

```gdscript
const DEFAULT_BACKEND_URL := "https://你的域名"
```

以及考虑把 `AUTO_LOGIN_DEFAULT` 翻成 `true` —— 那个开关关着的理由正是
"后端还没部署"（见该文件注释）。部署完就不成立了。

**翻之前先确认**：新的客户端包要能真的连上，否则每个玩家都会看到一次登录失败。
