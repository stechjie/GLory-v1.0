#!/usr/bin/env bash
# 更新账号后端到 origin/main 的最新代码。
#
#   sudo bash /opt/glory/repo/deploy/update.sh
#
# 首次安装用 bootstrap.sh；这个脚本假设那一步已经做过。
set -euo pipefail

BASE=/opt/glory
REPO="$BASE/repo"
SERVICE_USER=glory

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
[[ -d "$REPO/.git" ]] || { echo "$REPO 不是 git 仓库，先跑 bootstrap.sh" >&2; exit 1; }

BEFORE=$(git -C "$REPO" rev-parse --short HEAD)

say "拉取最新代码"
# 用 git 而不是解压覆盖：git 会**删掉**新版本里已经移除的文件。
# 审计文档第八节点名批评过 `unzip -o` 覆盖在线目录 —— 它留下的是新旧混合版本，
# 而混合版本的故障最难查。git reset --hard 没有这个问题。
git -C "$REPO" fetch --quiet origin
git -C "$REPO" reset --hard --quiet origin/main
chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO"

AFTER=$(git -C "$REPO" rev-parse --short HEAD)
echo "$BEFORE -> $AFTER"
if [[ "$BEFORE" == "$AFTER" ]]; then
	echo "代码没变化"
fi

say "同步依赖"
sudo -u "$SERVICE_USER" "$REPO/backend/.venv/bin/pip" install --quiet -r "$REPO/backend/requirements.txt"

say "更新 systemd 单元（如有改动）"
if ! cmp -s "$REPO/deploy/glory-backend.service" /etc/systemd/system/glory-backend.service; then
	install -m 644 "$REPO/deploy/glory-backend.service" /etc/systemd/system/glory-backend.service
	systemctl daemon-reload
	echo "已更新"
fi

say "重启"
systemctl restart glory-backend
sleep 2

say "验收"
# 只看 127.0.0.1：这一步验的是后端进程本身，不掺 Caddy 与证书的问题。
if curl -fsS --max-time 10 http://127.0.0.1:8099/health; then
	echo
	echo "OK"
else
	echo
	echo "❌ /health 打不开。看日志："
	echo "   sudo journalctl -u glory-backend -n 50 --no-pager"
	exit 1
fi
