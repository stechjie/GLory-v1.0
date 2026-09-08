#!/usr/bin/env bash
# 账号后端的**首次**安装。
#
# 把 glory-backend.tar.gz 传到服务器，解开，然后：
#
#   tar xzf glory-backend.tar.gz
#   sudo bash deploy/bootstrap.sh glorytd-api.duckdns.org
#
# 幂等：重复跑不会破坏已有状态，尤其**绝不覆盖已经填好的 backend.env**。
#
# 刻意**不用 git**：后端只有几十 KB 的几个文件，为了把它们搬上来而在服务器上
# 配私有仓库的部署密钥，是与账号系统本身无关的复杂度。以后更新频繁了再换 git。
#
# 它不碰战斗服务器（glory-server.service）的任何东西 —— 那是另一个进程、
# 另一个端口、另一套部署流程。
set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
	echo "用法: sudo bash deploy/bootstrap.sh <你的域名>" >&2
	echo "例如: sudo bash deploy/bootstrap.sh glorytd-api.duckdns.org" >&2
	exit 2
fi

# 源码目录 = 本脚本所在目录的上一级（也就是解压出来那个含 backend/ deploy/ 的目录）
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE=/opt/glory
REPO="$BASE/repo"
VENV="$BASE/venv"
ENV_FILE="$BASE/backend.env"
SERVICE_USER=glory

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
[[ -d "$SRC/backend" ]] || { echo "在 $SRC 下找不到 backend/ —— 是不是没解压，或路径不对？" >&2; exit 1; }

say "1/8 系统依赖"
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip curl rsync \
	debian-keyring debian-archive-keyring apt-transport-https

say "2/8 Caddy（自动 HTTPS）"
if ! command -v caddy >/dev/null; then
	curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
		| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
		| tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
	apt-get update -qq
	apt-get install -y -qq caddy
else
	echo "已安装，跳过"
fi

say "3/8 服务账号与目录"
# 专用低权限用户：这个进程持有 Supabase 的 secret key 与数据库密码，
# 不能以 root 跑 —— 被攻破时不该连整台机器一起交出去。
id -u "$SERVICE_USER" >/dev/null 2>&1 \
	|| useradd --system --home "$BASE" --shell /usr/sbin/nologin "$SERVICE_USER"
mkdir -p "$BASE" "$REPO"

say "4/8 复制代码"
# --delete：新版本删掉的文件也要在服务器上消失。
# 直接覆盖会留下新旧混合的目录，而混合版本的故障最难查
# （审计文档第八节点名批评过 unzip -o 覆盖在线目录）。
rsync -a --delete "$SRC/backend/" "$REPO/backend/"
rsync -a --delete "$SRC/deploy/" "$REPO/deploy/"
# 代码归 root、所有人可读：glory 用户只需要读，不需要写。
chown -R root:root "$REPO"
chmod -R a+rX "$REPO"

say "5/8 Python 虚拟环境"
# 放在仓库**外面**：代码目录归 root 只读，而 pip 要写。分开就不用在
# 权限上绕来绕去。
if [[ ! -x "$VENV/bin/python" ]]; then
	python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$REPO/backend/requirements.txt"
chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV"

say "6/8 密钥文件"
if [[ -f "$ENV_FILE" ]]; then
	echo "$ENV_FILE 已存在，**不覆盖**（里面是你填好的密钥）"
else
	# 只放键名，值留空 —— 和仓库里的 backend/.env.example 一样的规矩。
	# 真实的值由人手工填，任何脚本都不该经手。
	grep -E '^GLORY_[A-Z_]+=' "$REPO/backend/.env.example" > "$ENV_FILE"
	# 生产环境：关掉 /docs 与 /v1/debug/*，不把接口形状和表结构白送出去。
	sed -i 's/^GLORY_ENVIRONMENT=.*/GLORY_ENVIRONMENT=prod/' "$ENV_FILE"
	echo "已创建 $ENV_FILE（全是空值）"
fi
chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

say "7/8 systemd"
install -m 644 "$REPO/deploy/glory-backend.service" /etc/systemd/system/glory-backend.service
systemctl daemon-reload
systemctl enable --quiet glory-backend

say "8/8 Caddy 配置"
sed "s|GLORY_API_DOMAIN_PLACEHOLDER|$DOMAIN|" "$REPO/deploy/Caddyfile" > /etc/caddy/Caddyfile
mkdir -p /var/log/caddy && chown caddy:caddy /var/log/caddy
systemctl reload caddy || systemctl restart caddy

cat <<EOF

────────────────────────────────────────────────────────────
安装完成。**但服务还没起来** —— 密钥还是空的，这是刻意的。

下一步（手工，脚本不代劳）：

  sudo nano $ENV_FILE

填这四项（值从 Supabase Dashboard 取，和你本机 backend/.env 一样）：
  GLORY_SUPABASE_URL
  GLORY_SUPABASE_PUBLISHABLE_KEY
  GLORY_SUPABASE_SECRET_KEY
  GLORY_DATABASE_URL

nano 的存盘：Ctrl+O 回车，然后 Ctrl+X 退出。

保存后启动：

  sudo systemctl start glory-backend
  curl https://$DOMAIN/health

看到 "configured": true 就成了。
────────────────────────────────────────────────────────────
EOF
