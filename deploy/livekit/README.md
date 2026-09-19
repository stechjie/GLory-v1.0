# 语音服务器（LiveKit）部署手册

方案与理由见 [docs/语音LiveKit方案.md](../../docs/语音LiveKit方案.md)。这里只讲在服务器上怎么装。

```
玩家 ──wss:443──> Caddy ──> LiveKit 信令 127.0.0.1:7880        （新增站点：语音域名）
玩家 ──UDP 7882 / TCP 7881──> LiveKit 媒体（直连，不经过 Caddy）
战斗服务器 ──http://127.0.0.1:7880──> LiveKit 管理接口（踢人、删房间）
```

LiveKit 和账号服务器、战斗服务器**跑在同一台机器上**，是第三个程序，不是第三台机器。
语音挂了只影响语音，登录、房间、对战、文字聊天照常。

---

## 一、准备（人工，只做一次）

### 1. 语音域名

DuckDNS 再加一个子域名（现在用的是 `glorytd-voice`），**IP 要填服务器的 `34.142.168.170`**。

⚠️ DuckDNS 新加子域名时，会自动填上**你正在用的这台电脑的 IP**（家里或公司的网络），不是服务器的 IP。
加完要把 IP 改成服务器的，再点 **update ip**。安装脚本第一步会检查这件事，没改对就停下来提示。

### 2. GCP 防火墙

放开 **tcp:7881** 和 **udp:7882**。在 GCP 控制台右上角的 Cloud Shell（`>_` 图标）里跑：

```bash
gcloud compute firewall-rules create glory-voice-livekit --network=default --direction=INGRESS --action=ALLOW --rules=tcp:7881,udp:7882 --source-ranges=0.0.0.0/0
```

报 `already exists` 说明以前已经加过了，不用再加。检查：

```bash
gcloud compute firewall-rules describe glory-voice-livekit --format="value(allowed)"
```

应当显示 tcp 7881 和 udp 7882。7880 **不要**开（只给本机和 Caddy 用）；80 / 443 早就开着。

---

## 二、安装（一个文件、一条命令）

1. GCP 控制台 → Compute Engine → 虚拟机实例 → `glory-server-2` 那一行点 **SSH**，会打开一个网页终端。
2. 网页终端右上角点 **上传文件**（UPLOAD FILE），选电脑上的
   `GLory-v1.0\deploy\livekit\install_livekit.sh`。它会传到你的主目录。
3. 在网页终端里跑：

   ```bash
   sudo bash install_livekit.sh glorytd-voice.duckdns.org
   ```

脚本会做七件事，**任何一步不对就停下来并说明原因**：
1. 检查语音域名是不是指到这台机器；
2. 下载固定版本（v1.13.7），核对校验和；
3. 生成密钥写进 `/etc/livekit.yaml`，已有就保留；
4. 装 systemd 服务 `livekit` 并启动；
5. 写 Caddy 站点 `/etc/caddy/glory-voice.caddy`。主配置里没有 `import /etc/caddy/glory-voice*.caddy` 就自动加上：先备份，校验不过就还原，不会把账号服务器弄挂；
6. 把战斗服务器要用的语音配置写到服务用户的 Godot 目录（`livekit_voice.json`，权限 600）。服务用户从 `glory-server` 服务里自动读，不用自己查；
7. 从外面访问一次 `https://语音域名`，确认证书和转发都通了。

最后一行显示「装好了」就行。装好之后，现在的战斗服务器（p30）还不会用它，**玩家那边什么都不会变**。

密钥只在服务器上的两个文件里，**不进仓库、不进客户端、不进服务器包**。

## 三、之后（部署 p31 时）

1. 部署 **p31** 的战斗服务器包（`make_server_zip.ps1` 打的 `glory_server_p31.zip`），重启 `glory-server`。
2. 战斗服务器日志里要看到这两行：
   ```
   voice configured (LiveKit) path=user://livekit_voice.json url=wss://glorytd-voice.duckdns.org
   server started protocol=31
   ```
   看到的如果是 `voice not configured: …`，说明配置文件没放对。服务器照常开，只是没有语音。
3. 查 LiveKit 本身：
   ```bash
   systemctl status livekit --no-pager
   journalctl -u livekit -n 30 --no-pager
   curl -sS https://glorytd-voice.duckdns.org
   ```
   最后一条应当返回 `OK`。

## 换密钥

```bash
sudo rm /etc/livekit.yaml
sudo bash install_livekit.sh glorytd-voice.duckdns.org
sudo systemctl restart glory-server
```

## 卸载 / 回滚

```bash
sudo systemctl disable --now livekit
sudo rm /etc/caddy/glory-voice.caddy && sudo systemctl reload caddy
```

主配置里那行 import 留着也没关系：通配符匹配不到文件时，Caddy 只打一条警告，照常启动。
战斗服务器那份 `livekit_voice.json` 删掉，再重启 `glory-server`，就回到「照常开服、没有语音」。

## 以后

- **中继（TURN）**先不开，理由见方案 3.5；马来西亚各家网络实测有连不上的再开。
- **人多了**：LiveKit 可以原样搬到单独一台机器，改的只是 Caddy 站点指向和战斗服务器那份配置里的 `admin_url`。
