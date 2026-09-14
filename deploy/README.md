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

> `GLORY_ENVIRONMENT=prod` 会关掉 `/docs`、`/redoc`、**`/openapi.json`** 与 `/v1/debug/*`。
> 生产上不该把接口形状和表结构白送出去。
>
> `openapi.json` 那一条是部署后从外网实测才发现漏掉的 —— 只关 `/docs` 看着像关严了，
> 实际最完整的那份清单还开着。现在三个由同一个开关决定，且有测试钉着。

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

## 在线人数上限与排队

登录着的玩家超过上限时，新打开游戏的人停在启动画面排队（`backend/app/admission.py`）。
**默认上限 1000 是暂定值，还没按这台机器的实测容量校准。**

### 改上限（不用重启）

```bash
echo '{"online_limit": 400}' | sudo tee /opt/glory/admission.json
```

5 秒内生效，日志里会有一行 `在线上限 1000 -> 400`。删掉这个文件就回到默认值。
写错格式（不是正整数）会保留原来的上限，并打一条警告。

**不要为了改上限去重启。** 名额表和队列都在进程内存里，重启会清空排队顺序；
已经在游戏里的玩家重连时照样进得来，排队的人要按重连先后重新排。

### 看现在多少人

```bash
sudo journalctl -u glory-backend --since "10 min ago" | grep 在线
```

有人排队时每分钟一行：`在线 N（连着 N）/ 上限 N，排队 N（连着 N）`。
「连着」之外的那部分是刚断线、名额还在宽限期里的人（180 秒）。

### 部署顺序

账号后端**先**更新，再发带排队的客户端。反过来的话新客户端连上旧后端收不到名额消息，
会在启动画面等 10 秒后按「旧版服务器」放行 —— 能进，但这段时间没有排队保护。

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

## 限流按真实来源 IP 计

Caddy 用 `header_up X-Forwarded-For {remote_host}` **覆盖**（不是追加）这个头，
玩家自己塞的假值在这一层就被丢掉；后端的 `_client_ip()` 再确认一次请求确实
来自本机回环才采信，直连 8099 的请求一律按真实对端计。两层加起来，
伪造这个头没有意义。有测试钉着（`backend/tests/test_client_ip.py`）。

**仍然挡不住的**（按 IP 限流的固有边界，不是本实现的缺陷）：

- 同一出口 IP 的人共用额度 —— 办公室、校园网，手机运营商 NAT 尤其严重
- 手上有大量 IP 的攻击者

真要解决得靠设备标识或人机验证，那是以后的事。

⚠️ **若以后在 Caddy 前面再加一层**（Cloudflare 之类），`X-Forwarded-For`
会变成一串 IP，后端取第一段的做法要重新评估 —— 改之前先看 `_client_ip()`
的注释。取错了会让全体又共用一个额度，而且不会报错。

---

## 部署之后要改客户端

`scripts/account/AccountConfig.gd`：

```gdscript
const DEFAULT_BACKEND_URL := "https://你的域名"
```

以及考虑把 `AUTO_LOGIN_DEFAULT` 翻成 `true` —— 那个开关关着的理由正是
"后端还没部署"（见该文件注释）。部署完就不成立了。

**翻之前先确认**：新的客户端包要能真的连上，否则每个玩家都会看到一次登录失败。
