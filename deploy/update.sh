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
# 组队房（排位 / 休闲开局前）的语音钥匙由账号服务器签（backend/app/party_voice.py），
# 用的是和战斗服务器**同一个 LiveKit、同一把钥匙**。两个服务在同一台机器上，这里直接把
# 战斗服务器那份配置（deploy/livekit/install_livekit.sh 第 6 步写的）复制给账号服务器。
#
# 原来要人手动复制（deploy/README.md「组队房语音」）。2026-10-08 线上一直没配，
# 组队房始终显示「队伍语音尚未配置」—— 这一步就是为了不再依赖人记得做。
#
# 找不到就说清楚、继续更新：语音不该挡住整个后端的更新。
sync_party_voice() {
	local battle_user battle_home key
	local target="$BASE/party_voice.json"
	local env_file="$BASE/backend.env"
	battle_user="$(systemctl show -p User --value glory-server 2>/dev/null || true)"
	if [[ -z "$battle_user" ]] || ! id -u "$battle_user" >/dev/null 2>&1; then
		echo "⚠️  读不到战斗服务器（glory-server）的运行用户，组队房语音没配。"
		return 0
	fi
	battle_home="$(getent passwd "$battle_user" | cut -d: -f6)"
	# 目录名 = project.godot 的 config/name（同 install_livekit.sh 的 APP_DIR_NAME）。
	key="$battle_home/.local/share/godot/app_userdata/Glory Beta 0.04/livekit_voice.json"
	if [[ ! -f "$key" ]]; then
		echo "⚠️  没找到战斗服务器的语音配置：$key"
		echo "   组队房语音没配。先按 deploy/livekit/README.md 把语音装好，再跑一次本脚本。"
		return 0
	fi
	if ! cmp -s "$key" "$target"; then
		install -m 600 -o "$SERVICE_USER" -g "$SERVICE_USER" "$key" "$target"
		echo "已从战斗服务器复制：$key"
	fi
	if grep -q '^GLORY_PARTY_VOICE_CONFIG_FILE=' "$env_file" 2>/dev/null; then
		sed -i "s|^GLORY_PARTY_VOICE_CONFIG_FILE=.*|GLORY_PARTY_VOICE_CONFIG_FILE=$target|" "$env_file"
	else
		# 先补换行：文件最后一行没有换行时直接追加，会粘到上一个设置后面把它改坏
		# （例如 GLORY_ENVIRONMENT=prod 变成 prodGLORY_...，生产就被当成开发环境）。
		[[ -s "$env_file" && -n "$(tail -c1 "$env_file")" ]] && echo >> "$env_file"
		echo "GLORY_PARTY_VOICE_CONFIG_FILE=$target" >> "$env_file"
		echo "已写入 $env_file"
	fi
	echo "组队房语音：$target"
}

main() {
	[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
	[[ -d "$SRC/backend" ]] || { echo "$SRC 下没有 backend/，先跑 bootstrap.sh" >&2; exit 1; }

	if [[ "${1:-}" == "--after-pull" ]]; then
		say "拉取最新代码（已拉过，新版 update.sh 接着跑）"
	elif [[ -d "$SRC/.git" ]]; then
		say "拉取最新代码"
		local self_before
		self_before="$(sha256sum "$SRC/deploy/update.sh" | cut -d' ' -f1)"
		BEFORE=$(git -C "$SRC" rev-parse --short HEAD)
		git -C "$SRC" fetch --quiet origin
		git -C "$SRC" reset --hard --quiet origin/main
		AFTER=$(git -C "$SRC" rev-parse --short HEAD)
		echo "$BEFORE -> $AFTER"
		[[ "$BEFORE" == "$AFTER" ]] && echo "代码没变化"
		# 本脚本自己也更新了：正在跑的这一份是旧版（见文件头），新加的步骤它根本不认识，
		# 原来要人再跑一遍才生效（2026-10-08 组队语音那一步就差点这样漏掉）。
		# 换成新版从这里接着跑；--after-pull 让新版跳过拉取，不会再进到这里。
		if [[ "$(sha256sum "$SRC/deploy/update.sh" | cut -d' ' -f1)" != "$self_before" ]]; then
			echo "update.sh 本身有更新，换新版接着跑"
			exec bash "$SRC/deploy/update.sh" --after-pull
		fi
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
	# 商城与七日登录还需要三份配置：
	#   data/shop.json       商品目录。**不在这份目录里的内容一律免费**，
	#                        所以漏了它不是「商城空了」，是所有付费内容变免费。
	#   data/pets/pets.json  宠物 id 与 starter_ids。服务端与客户端刻意读同一份 ——
	#                        starter_ids 有两处定义的话，迟早出现
	#                        「客户端让选、服务端说不是新手宠物」。
	#   data/seven_day_login.json  七天奖励与服务器游戏日时区。
	#   data/balance/final_status.json  与客户端、专服核对的数值版本。
	#
	# **只复制后端需要的文件，不复制整个 data/。** 运行目录只放后端真正要用的东西 ——
	# 整个 data/ 是全套游戏数值表（单位、宝物、回合、AI 曲线），后端一个都不读，
	# 复制过去只是白白多一份暴露面。理由同 bootstrap 里 src 与 repo 分家那段。
	mkdir -p "$REPO/data"
	# 列表里允许带子目录（pets/pets.json），所以每个文件各自 mkdir 一次父目录 ——
	# 上面那个 mkdir 只建了 data/ 本身。
	for f in avatars.json blocked_words.txt shop.json seven_day_login.json pets/pets.json balance/final_status.json; do
		if [[ -f "$SRC/data/$f" ]]; then
			mkdir -p "$(dirname "$REPO/data/$f")"
			rsync -a "$SRC/data/$f" "$REPO/data/$f"
		fi
	done

	chown -R root:root "$REPO"
	chmod -R a+rX "$REPO"

	say "维护公告目录"
	# Caddy 从这里直接给 /status.json（docs/公告系统设计.md「维护公告」），账号服务器停了也读得到。
	# 目录归 root，文件由管理员用 sudo tee 写。
	mkdir -p "$BASE/public"
	chmod 755 "$BASE/public"
	# 本脚本不改 Caddy 配置（要域名，而且改错了全体玩家连不上）。旧配置照样能跑，但要提醒。
	if ! grep -q "status.json" /etc/caddy/Caddyfile 2>/dev/null; then
		echo "⚠️  /etc/caddy/Caddyfile 还是旧版（没有 /status.json 与 /media/*）："
		echo "   账号服务器停机时维护公告读不到；公告图片改由后端自己给（能用，多过一道 Python）。"
		echo "   更新一次（把「你的域名」换掉）："
		echo "   sed \"s|GLORY_API_DOMAIN_PLACEHOLDER|你的域名|\" $REPO/deploy/Caddyfile > /etc/caddy/Caddyfile && systemctl reload caddy"
	fi

	say "同步依赖"
	"$VENV/bin/pip" install --quiet -r "$REPO/backend/requirements.txt"
	chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV"

	say "更新 systemd 单元（如有改动）"
	if ! cmp -s "$REPO/deploy/glory-backend.service" /etc/systemd/system/glory-backend.service; then
		install -m 644 "$REPO/deploy/glory-backend.service" /etc/systemd/system/glory-backend.service
		systemctl daemon-reload
		echo "已更新"
	fi

	say "组队房语音配置"
	sync_party_voice

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
