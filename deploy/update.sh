#!/usr/bin/env bash
# 更新账号后端到最新代码。
#
#   sudo bash /opt/glory/src/deploy/update.sh
#
# 首次安装用 bootstrap.sh；这个脚本假设那一步已经做过。
#
# 两种取代码方式都支持：
#   /opt/glory/src 是 git 仓库 -> 先 git pull
#   不是（当初是传文件上来的）-> 跳过拉取，直接用当前内容重装
set -euo pipefail

BASE=/opt/glory
SRC="$BASE/src"
REPO="$BASE/repo"
VENV="$BASE/venv"
SERVICE_USER=glory

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ⚠️ **整个脚本包在 main() 里，最后一行才调用它。这不是风格问题。**
#
# 下面的 `git reset --hard` 会把**正在执行的这个文件本身**覆盖掉
# （deploy/update.sh 也在仓库里）。而 bash 是边读边执行的：它记着字节偏移，
# 文件在脚下换成了另一个长度不同的版本之后，它接着从旧偏移往下读 ——
# 读到的就是错位的内容。表现是「脚本跑了一半就没了」或者莫名其妙的语法错误，
# 而且**只在这个脚本自己有改动的那一次发生**，下一次跑又正常了，极难查。
#
# 实际咬过一次：新增的「复制后端要读的数据文件」那一段在 git reset 之后，
# 拉到它的那一次运行没执行到，服务器上就少了 data/avatars.json，
# 玩家一换头像就 500。
#
# 包成函数之后 bash 必须先把整个文件解析完才能调用 main，
# 之后文件怎么被改都与这次运行无关。
main() {
	[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
	[[ -d "$SRC/backend" ]] || { echo "$SRC 下没有 backend/，先跑 bootstrap.sh" >&2; exit 1; }

	if [[ -d "$SRC/.git" ]]; then
		say "拉取最新代码"
		BEFORE=$(git -C "$SRC" rev-parse --short HEAD)
		git -C "$SRC" fetch --quiet origin
		git -C "$SRC" reset --hard --quiet origin/main
		AFTER=$(git -C "$SRC" rev-parse --short HEAD)
		echo "$BEFORE -> $AFTER"
		[[ "$BEFORE" == "$AFTER" ]] && echo "代码没变化"
	else
		say "跳过拉取（$SRC 不是 git 仓库）"
	fi

	say "复制到运行目录"
	# --delete：新版本删掉的文件也要在服务器上消失。直接覆盖会留下新旧混合的
	# 目录，而混合版本的故障最难查（审计文档第八节点名批评过 unzip -o 覆盖在线目录）。
	rsync -a --delete "$SRC/backend/" "$REPO/backend/"
	rsync -a --delete "$SRC/deploy/" "$REPO/deploy/"

	say "复制后端要读的数据文件"
	# 后端要读 data/avatars.json（头像 id 的授权校验，见 backend/app/avatar_catalog.py）
	# 与可选的 data/blocked_words.txt（文本词表）。
	#
	# **只复制这两个文件，不复制整个 data/。** 运行目录只放后端真正要用的东西 ——
	# 整个 data/ 是全套游戏数值表（单位、宝物、回合、AI 曲线），后端一个都不读，
	# 复制过去只是白白多一份暴露面。理由同 bootstrap 里 src 与 repo 分家那段。
	mkdir -p "$REPO/data"
	for f in avatars.json blocked_words.txt; do
		if [[ -f "$SRC/data/$f" ]]; then
			rsync -a "$SRC/data/$f" "$REPO/data/$f"
		fi
	done

	chown -R root:root "$REPO"
	chmod -R a+rX "$REPO"

	say "同步依赖"
	"$VENV/bin/pip" install --quiet -r "$REPO/backend/requirements.txt"
	chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV"

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
}

main "$@"
