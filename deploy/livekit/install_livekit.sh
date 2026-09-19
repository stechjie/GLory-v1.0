#!/usr/bin/env bash
# 在游戏服务器那台 GCP 机器上装语音服务器 LiveKit（docs/语音LiveKit方案.md 3.1；说明见同目录 README.md）。
#
# 只有这一个文件，不依赖服务器上的仓库：可以用 GCP 网页 SSH 的「上传文件」传上去直接跑。
#
# 用法：
#   sudo bash install_livekit.sh <语音域名> [战斗服务器运行用户]
# 例：
#   sudo bash install_livekit.sh glorytd-voice.duckdns.org
# 第二个参数不写，就从 glory-server 服务里读 User=（deploy/BATTLE_SERVER_KEY.md 第 0 步查的就是它）。
#
# 它做这些事，任何一步不对就停下并说明原因：
#   1. 检查语音域名是不是指到这台机器（不是的话，证书申请不下来）
#   2. 下载固定版本的 LiveKit 并核对校验和
#   3. 生成密钥写进 /etc/livekit.yaml（已有就保留原密钥）
#   4. 装 systemd 服务 livekit 并启动
#   5. 写 Caddy 站点 /etc/caddy/glory-voice.caddy；主配置里没有 import 那一行就加上
#      （先备份，校验不过就还原，不会把账号服务器弄挂）
#   6. 把战斗服务器要用的语音配置写到服务用户的 Godot 目录（livekit_voice.json，权限 600）
#   7. 最后从外面访问一次 https://语音域名，确认证书与转发都通了
#
# 可以重复跑：会升级程序、重写配置，**已有的密钥不换**（换了的话战斗服务器手里那份就作废了）。
# 要换密钥：先删 /etc/livekit.yaml 再跑，然后重启 glory-server。
set -euo pipefail

VERSION="1.13.7"
CONF=/etc/livekit.yaml
UNIT=/etc/systemd/system/livekit.service
CADDY_MAIN=/etc/caddy/Caddyfile
CADDY_SITE=/etc/caddy/glory-voice.caddy
CADDY_IMPORT="import /etc/caddy/glory-voice*.caddy"
# project.godot 的 config/name；战斗服务器的 user:// 在 ~/.local/share/godot/app_userdata/ 下的这个目录。
APP_DIR_NAME="Glory Beta 0.04"
# 下载用的临时目录（全局变量：退出时的清理要看得到它）。
TMP=""

say() { printf '\n== %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

# 整个脚本包在 main 里：bash 边读边执行，脚本运行中被改写会读错位（deploy/update.sh 踩过）。
main() {
	[[ $EUID -eq 0 ]] || die "要用 sudo 跑：sudo bash $0 <语音域名>"
	local voice_domain="${1:-}"
	local battle_user="${2:-}"
	[[ -n "$voice_domain" ]] || die "用法：sudo bash $0 <语音域名> [战斗服务器运行用户]"
	for tool in curl tar sha256sum python3 caddy systemctl getent; do
		command -v "$tool" >/dev/null 2>&1 || die "这台机器上没有 $tool"
	done

	if [[ -z "$battle_user" ]]; then
		battle_user="$(systemctl show -p User --value glory-server 2>/dev/null || true)"
		[[ -n "$battle_user" ]] || die "读不到 glory-server 的运行用户。用 systemctl cat glory-server --no-pager 看 User= 那一行，再把它写在命令最后"
	fi
	id -u "$battle_user" >/dev/null 2>&1 || die "没有用户 $battle_user"
	local battle_home battle_dir
	battle_home="$(getent passwd "$battle_user" | cut -d: -f6)"
	battle_dir="$battle_home/.local/share/godot/app_userdata/$APP_DIR_NAME"
	echo "语音域名：$voice_domain"
	echo "战斗服务器用户：$battle_user（配置写到 $battle_dir）"

	say "1/7 检查语音域名是不是指到这台机器"
	local public_ip resolved
	public_ip="$(curl -fsS -m 5 -H 'Metadata-Flavor: Google' \
		http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || true)"
	resolved="$(getent ahostsv4 "$voice_domain" | awk '{print $1; exit}' || true)"
	[[ -n "$resolved" ]] || die "$voice_domain 查不到 IP。先到 DuckDNS 确认这个子域名存在"
	if [[ -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
		die "$voice_domain 现在指向 $resolved，不是这台机器（$public_ip）。
   到 DuckDNS 把它的 IP 改成 $public_ip，点 update ip，等一两分钟再跑这个脚本。"
	fi
	echo "OK：$voice_domain -> $resolved"

	say "2/7 下载 LiveKit v$VERSION 并核对校验和"
	local tar_name base_url
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	tar_name="livekit_${VERSION}_linux_amd64.tar.gz"
	base_url="https://github.com/livekit/livekit/releases/download/v${VERSION}"
	curl -fsSL -o "$TMP/$tar_name" "$base_url/$tar_name"
	curl -fsSL -o "$TMP/checksums.txt" "$base_url/checksums.txt"
	( cd "$TMP" && grep " $tar_name\$" checksums.txt | sha256sum -c - ) || die "校验和对不上，没有安装"
	tar -xzf "$TMP/$tar_name" -C "$TMP"
	[[ -f "$TMP/livekit-server" ]] || die "包里没有 livekit-server"
	install -m 755 "$TMP/livekit-server" /usr/local/bin/livekit-server
	id -u livekit >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin livekit

	say "3/7 密钥与配置 $CONF"
	local api_key api_secret
	if [[ -f "$CONF" ]]; then
		api_key="$(awk '/^keys:/{f=1;next} f&&/^  [^ #][^:]*: /{sub(/^  /,""); print substr($0,1,index($0,":")-1); exit}' "$CONF")"
		api_secret="$(awk '/^keys:/{f=1;next} f&&/^  [^ #][^:]*: /{sub(/^  /,""); print substr($0,index($0,": ")+2); exit}' "$CONF")"
		[[ -n "$api_key" && -n "$api_secret" ]] || die "$CONF 里读不出密钥；要重新生成就先删掉它"
		echo "已有密钥，保留（key=$api_key）"
	else
		api_key="API$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
		api_secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))')"
		echo "生成了新密钥（key=$api_key）"
	fi
	# 密钥只在这里和第 6 步那个文件里；这个仓库、客户端、服务器包里都没有（tools/voice_check 钉着）。
	cat > "$CONF" <<EOF
# 由 install_livekit.sh 生成（docs/语音LiveKit方案.md 3.1）。只有 root 和 livekit 用户可读。

# 信令 + 管理接口。防火墙不开这个端口：玩家经 Caddy（443，wss://$voice_domain）进来，
# 战斗服务器走本机 127.0.0.1:7880 踢人、删房间。
port: 7880

rtc:
  # UDP 被封时走的 TCP 通道。防火墙要开。
  tcp_port: 7881
  # 所有媒体走这一个 UDP 端口（一台机器够用）。防火墙要开。
  udp_port: 7882
  # GCP 的网卡是内网地址，靠 STUN 找到公网 IP 告诉客户端。
  use_external_ip: true

keys:
  $api_key: $api_secret

# 中继（TURN）先不开：443 已经给 Caddy 了，中继还要单独的域名和证书。
# 马来西亚各家网络实测有连不上的，再按 docs/语音LiveKit方案.md 3.5 开。
turn:
  enabled: false

logging:
  level: info
EOF
	chown root:livekit "$CONF"
	chmod 640 "$CONF"

	say "4/7 systemd 服务 livekit"
	cat > "$UNIT" <<'EOF'
# LiveKit voice server for Glory team voice (docs/语音LiveKit方案.md). Written by install_livekit.sh.
[Unit]
Description=LiveKit voice server (Glory team voice)
After=network-online.target
Wants=network-online.target

[Service]
User=livekit
Group=livekit
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit.yaml
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable livekit >/dev/null 2>&1
	systemctl restart livekit
	local ok=0
	for _ in $(seq 1 15); do
		if curl -fsS -m 2 http://127.0.0.1:7880 >/dev/null 2>&1; then ok=1; break; fi
		sleep 1
	done
	if [[ $ok -ne 1 ]]; then
		journalctl -u livekit -n 30 --no-pager || true
		die "livekit 没起来（看上面的日志）"
	fi
	echo "OK：livekit 在 127.0.0.1:7880 应答"

	say "5/7 Caddy：wss://$voice_domain -> 127.0.0.1:7880"
	cat > "$CADDY_SITE" <<EOF
# 由 install_livekit.sh 生成。语音服务器的信令（WebSocket）入口；
# 媒体不走这里（UDP 7882 / TCP 7881 直连这台机器）。
$voice_domain {
	reverse_proxy 127.0.0.1:7880
}
EOF
	local backup=""
	if ! grep -qF "$CADDY_IMPORT" "$CADDY_MAIN"; then
		backup="$CADDY_MAIN.bak-before-voice-$(date +%Y%m%d%H%M%S)"
		cp -p "$CADDY_MAIN" "$backup"
		printf '\n# 语音服务器（deploy/livekit/）。站点写在单独的文件里，由 install_livekit.sh 生成。\n%s\n' "$CADDY_IMPORT" >> "$CADDY_MAIN"
		echo "主配置里加了 import 那一行（原文件备份在 $backup）"
	fi
	if ! caddy validate --config "$CADDY_MAIN" --adapter caddyfile >"$TMP/caddy_validate.log" 2>&1; then
		cat "$TMP/caddy_validate.log" >&2
		if [[ -n "$backup" ]]; then
			cp -p "$backup" "$CADDY_MAIN"
			echo "已把 $CADDY_MAIN 还原成原来的样子" >&2
		fi
		rm -f "$CADDY_SITE"
		die "Caddy 配置校验没过，没有重载（账号服务器不受影响）。把上面的输出发给开发看"
	fi
	systemctl reload caddy
	echo "OK：Caddy 已重载"

	say "6/7 战斗服务器的语音配置 $battle_dir/livekit_voice.json"
	mkdir -p "$battle_dir"
	KEY_FILE="$battle_dir/livekit_voice.json" VOICE_DOMAIN="$voice_domain" API_KEY="$api_key" API_SECRET="$api_secret" \
		python3 - <<'PY'
import json, os
with open(os.environ["KEY_FILE"], "w", encoding="utf-8") as f:
    json.dump({
        "client_url": "wss://" + os.environ["VOICE_DOMAIN"],
        "admin_url": "http://127.0.0.1:7880",
        "api_key": os.environ["API_KEY"],
        "api_secret": os.environ["API_SECRET"],
    }, f)
PY
	chown -R "$battle_user:$battle_user" "$battle_home/.local/share/godot"
	chmod 600 "$battle_dir/livekit_voice.json"
	echo "OK"

	say "7/7 从外面访问 https://$voice_domain（第一次要等 Caddy 申请证书，最多一分钟）"
	local code=""
	for _ in $(seq 1 30); do
		code="$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "https://$voice_domain" 2>/dev/null || true)"
		[[ "$code" == "200" ]] && break
		sleep 2
	done
	if [[ "$code" == "200" ]]; then
		echo "OK：https://$voice_domain 返回 200，证书和转发都通了"
	else
		echo "!! https://$voice_domain 还没通（最后一次返回：${code:-无}）。"
		echo "   多半是证书还在申请。过几分钟再试：curl -sS https://$voice_domain"
		echo "   还不行就看：journalctl -u caddy -n 50 --no-pager"
	fi

	say "装好了"
	echo "  - 语音服务器（livekit）已经在跑；现在的战斗服务器（p30）还不会用它，玩家那边什么都不会变。"
	echo "  - 等 p31 的战斗服务器包部署并重启之后，journalctl -u glory-server -n 30 里要看到："
	echo "      voice configured (LiveKit) ... url=wss://$voice_domain"
	echo "  - 防火墙要放开 tcp:7881 和 udp:7882（glory-voice-livekit 那条规则）。"
}

main "$@"
