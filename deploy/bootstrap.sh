#!/usr/bin/env bash
# 账号后端的**首次**安装。在服务器上以 root 跑一次：
#
#   sudo bash deploy/bootstrap.sh glorytd-api.duckdns.org
#
# 幂等：重复跑不会破坏已有状态，尤其**绝不覆盖已经填好的 backend.env**。
#
# 它不碰战斗服务器的任何东西 —— 那是另一个进程、另一个端口、另一套部署流程
# （见 docs/联机审计与整改方案.md 第八节的 C15）。
set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
	echo "用法: sudo bash deploy/bootstrap.sh <你的域名>" >&2
	echo "例如: sudo bash deploy/bootstrap.sh glorytd-api.duckdns.org" >&2
	exit 2
fi

REPO_URL="${REPO_URL:-https://github.com/stechjie/GLory-v1.0.git}"
BASE=/opt/glory
REPO="$BASE/repo"
ENV_FILE="$BASE/backend.env"
SERVICE_USER=glory

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }

say "1/8 系统依赖"
apt-get update -qq
apt-get install -y -qq git python3-venv python3-pip curl debian-keyring debian-archive-keyring apt-transport-https

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
# 专用低权限用户：这个进程持有 secret key 与数据库密码，不能以 root 跑。
id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home "$BASE" --shell /usr/sbin/nologin "$SERVICE_USER"
mkdir -p "$BASE"
chown "$SERVICE_USER:$SERVICE_USER" "$BASE"

say "4/8 取代码"
if [[ -d "$REPO/.git" ]]; then
	git -C "$REPO" fetch --quiet origin
	git -C "$REPO" reset --hard --quiet origin/main
else
	# 私有仓库会在这里要凭据。那就先在服务器上配一个 deploy key 或
	# 用带 token 的 URL：REPO_URL=https://<token>@github.com/... sudo -E bash ...
	git clone --quiet --depth 1 "$REPO_URL" "$REPO"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO"

say "5/8 Python 虚拟环境"
sudo -u "$SERVICE_USER" python3 -m venv "$REPO/backend/.venv"
sudo -u "$SERVICE_USER" "$REPO/backend/.venv/bin/pip" install --quiet --upgrade pip
sudo -u "$SERVICE_USER" "$REPO/backend/.venv/bin/pip" install --quiet -r "$REPO/backend/requirements.txt"

say "6/8 密钥文件"
if [[ -f "$ENV_FILE" ]]; then
	echo "$ENV_FILE 已存在，**不覆盖**（里面是你填好的密钥）"
else
	# 只放键名，值留空 —— 和仓库里的 backend/.env.example 一样的规矩。
	# 真实的值由人手工填，任何脚本都不该经手。
	grep -E '^GLORY_[A-Z_]+=' "$REPO/backend/.env.example" > "$ENV_FILE"
	# 生产环境：关掉 /docs 与 /v1/debug/*
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
安装完成。**但服务还没起来** —— 密钥还是空的。

下一步（手工，脚本不代劳）：

  sudo nano $ENV_FILE

填这四项（值从 Supabase Dashboard 取）：
  GLORY_SUPABASE_URL
  GLORY_SUPABASE_PUBLISHABLE_KEY
  GLORY_SUPABASE_SECRET_KEY
  GLORY_DATABASE_URL

保存后启动：

  sudo systemctl start glory-backend
  systemctl status glory-backend
  curl https://$DOMAIN/health

/health 返回 "configured": true 就成了。
────────────────────────────────────────────────────────────
EOF
