# 战斗服务器的 DTLS 私钥部署（C14）

部署的是 **③ 战斗服务器**（Godot headless + ENet），**不是**账号后端。
账号后端看 `deploy/README.md`，那是另一套流程、另一个端口、另一个进程。

背景与实测证据在 `docs/联机审计与整改方案.md` 的 `C14` 行；
实现与"为什么这么设计"在 `scripts/multiplayer/NetTLS.gd`。

---

## 这一步为什么必须人工做

`NetworkConfig.USE_DTLS = true` 之后，战斗服务器启动时要拿私钥。
**拿不到就拒绝启动** —— 这是刻意的，见 `NetTLS.gd` 的 fail closed 一节：
静默退回明文比启动失败糟得多，因为前者没有任何症状。

私钥不能进 git、不能进客户端包，所以它只能靠仓库外的渠道送上去。
和 `export_presets.cfg` 里的 keystore 密码、`/opt/glory/backend.env` 里的
Supabase 密钥是同一类东西。

### ⚠️ 私钥不能重新生成

客户端 pin 的是 `scripts/multiplayer/NetTLSCert.gd` 里那张**配对的**证书。
在服务器上重跑 `tools/dtls_make_cert.tscn` 会生成新的一对，
**所有已发出去的客户端立刻连不上**。

私钥的唯一副本在生成它的那台机器上：

```
%APPDATA%\Godot\app_userdata\Glory Beta 0.04\glory_server_key.pem
```

**先把它备份到密码管理器或别的安全地方，再往下走。** 丢了它 = 必须重新生成
证书 + 重新发版客户端。

---

## 步骤

### 0. 先确认 glory-server 跑在哪个用户下

私钥要放的位置取决于**跑这个进程的那个用户**，所以先查：

```bash
systemctl cat glory-server --no-pager
```

看 `User=` 那一行。（`systemctl show -p User` 也行，但它会进分页器并截断长行 ——
按 `q` 退出，别按 Ctrl+C。）

> **2026-09-09 实测结果**（glory-server-2，asia-southeast1-a）：
> `User=nins17121`，`WorkingDirectory=/home/nins17121/Glory`，
> 项目目录 `/home/nins17121/Glory/Beta 0.04`。

### 1. 传私钥上去

用你平时传 `glory_server_pNN.zip` 的同一条路（GCP 网页 SSH 的 **UPLOAD FILE**
最省事）。本机那份在 `%APPDATA%\Godot\app_userdata\Glory Beta 0.04\glory_server_key.pem`。

### 2. 放进那个用户的 Godot 目录

代码里默认路径是 `user://glory_server_key.pem`，在 Linux 上展开成
`~/.local/share/godot/app_userdata/Glory Beta 0.04/`。**放对地方就不用改 systemd** ——
这是最省事、也最不容易出错的做法。

```bash
sudo mkdir -p ~/.local/share/godot/app_userdata/"Glory Beta 0.04"
sudo mv ~/glory_server_key.pem ~/.local/share/godot/app_userdata/"Glory Beta 0.04"/glory_server_key.pem
sudo chown -R 服务用户:服务用户 ~/.local/share/godot
sudo chmod 600 ~/.local/share/godot/app_userdata/"Glory Beta 0.04"/glory_server_key.pem
```

`server_flags.json` 和房间快照 `server_rooms.bin.N` 也在这个目录，所以它多半已经存在。

### 3. 检查

```bash
ls -l ~/.local/share/godot/app_userdata/"Glory Beta 0.04"/glory_server_key.pem
```

必须是 `-rw-------` 且属主是服务用户：

```
-rw------- 1 nins17121 nins17121 1675 ... glory_server_key.pem
```

显示 `root root` 就再跑一次上面那条 `chown`，否则服务器读不到。

> **备选：绝对路径。** 不想依赖 `user://` 的话，把私钥放 `/etc/glory/battle_key.pem`，
> 然后 `sudo systemctl edit --full glory-server`，在 `ExecStart` 末尾加
> `--tls-key=/etc/glory/battle_key.pem`（**必须等号形式**，空格形式会被静默忽略），
> 再 `sudo systemctl daemon-reload`。服务用户以后会变的话，这条更稳。

### 4. 先清掉同名旧包 ⚠️

**本次改动没有顶协议号，所以新包和旧包同名**（都是 `glory_server_p17.zip`）。
`make_server_zip.ps1` 的注释里记着这个事故：家目录躺着同名的昨天的包，肉眼分不出来。

```bash
mkdir -p ~/old_zips
mv ~/glory_server_p17.zip ~/glory_server_upload*.zip ~/old_zips/ 2>/dev/null
ls ~/*.zip
```

最后一条应当报 `No such file` —— 家目录干净了，接下来传上去的一定是新的。

### 5. 打包

**双击项目根目录的 `make_server_zip.bat`。** 就这一步。

脚本会自己找 Godot（2026-09-10 起），不用再传路径。它按这个顺序找：

| 顺序 | 来源 |
|---|---|
| 1 | `-Godot "<路径>"` 参数 |
| 2 | `GLORY_GODOT` 环境变量 |
| 3 | `tools\godot_path.txt`（本机设一次，已在 .gitignore 里） |
| 4 | 自动扫描：下载 / 桌面 / OneDrive 桌面 / Program Files，深度 2 层 |

自动扫描优先挑 **4.7.x**（`project.godot` 的 `config/features` 写的是 4.7），
同版本取最新。必须是 **console 版** —— 普通版在 Windows 上不把日志写到 stdout，
冒烟测试会收到空输出，然后把「起服成功」误判成失败。

自动找不到时报错会直接告诉你怎么办。想固定一个版本（比如让它和线上服务器的
Godot 版本一致）就建这个文件：

```
tools\godot_path.txt
```

里面写一行完整路径，例如：

```
C:\Users\你\Desktop\GODOT4.7\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe
```

#### 输出

包名是 `glory_server_p<协议号>.zip`，协议号**从源码实读**，不接受手写 ——
手写的版本号会和内容漂移。记下输出里的 SHA-256，下一步要核对。

#### 打包失败是件好事

脚本在这些情况下会**拒绝出包**，并且**不覆盖上一个好包**：

- 冷启动起不来（解压到空目录 → headless 起服 → 必须打印 `server started protocol=N`）
- 冷启动的 stderr 里有 `SCRIPT ERROR` 或 `Failed to instantiate an autoload`
- zip 里有反斜杠路径分隔符（不符合 ZIP 规范，换个解压工具就会解成平铺文件）
- 缺 `scenes/server/ServerMain.tscn` 或 `.godot/global_script_class_cache.cfg`

红字出现时**不要绕过它**，包传上去只会静默挂住。

> 新增了 `class_name` 全局类之后要先重建缓存，否则服务器解析阶段直接挂：
> ```
> <Godot console> --headless --editor --quit --path .
> ```

### 6. 上传并替换项目目录

**不要 `unzip -o` 覆盖在线目录**（审计文档第八节判为废弃：它不删除新版本里
已移除的文件，中途失败会留下新旧混合版本，而混合版本的故障最难查）。
整个目录换掉，旧的留着当回滚点：

```bash
sha256sum ~/glory_server_p17.zip
sudo systemctl stop glory-server
cd ~/Glory
mv "Beta 0.04" "Beta 0.04.bak-$(date +%m%d-%H%M)"
mkdir -p "Beta 0.04"
unzip -q ~/glory_server_p17.zip -d "Beta 0.04"
sudo systemctl start glory-server
```

> 玩家存档、房间快照、`server_flags.json` 都在 `~/.local/share/godot/` 下，
> **不在项目目录里**，所以换目录不会丢任何数据。

### 7. 验证 —— 这一步不能省

```bash
journalctl -u glory-server -n 30 --no-pager | grep -E "server start|DTLS"
```

**必须看到两行**，缺一不可：

```
[NET] server starting protocol=17 shard=0 port=8080 max_fps=30 dtls=on key=user://glory_server_key.pem ...
[NET] server started protocol=17 port=8080 epoch=... rooms=0
```

⚠️ **两行的含义不一样，只看第一行会误判成功：**

| 行 | 什么时候打的 | 证明了什么 |
|---|---|---|
| `server starting` | `team_host()` **之前** | 只证明 `USE_DTLS` 开关是开的 |
| `server started` | `create_server` + `dtls_server_setup` **都成功之后** | **私钥真的读到了、DTLS 真的配上了** |

私钥缺失或读不出来时，第一行照样打印 `dtls=on`，然后你会看到
`DTLS server setup failed: ...` 而**没有** `server started`，服务随
`Restart=always` 反复重启。所以判据是**第二行**。

三种失败长什么样：

| 看到 | 意思 |
|---|---|
| `dtls=off` | 包是旧的（`USE_DTLS` 还是 false），重新打包 |
| 服务反复重启，日志说「缺服务器私钥」 | 第 2/3 步没到位，多半是属主不对 |
| `key=` 不是预期路径 | 用了备选方案但 `--tls-key=` 没生效，检查是不是写成了空格 |

**没看到 `dtls=on` 就不算部署完成。** 客户端连不上时的症状是卡住不报错，
到时候很难倒推回这一步。

### 8. 可选：让 ExecStart 与冒烟测试对齐

打包脚本的冷启动冒烟测试跑的是**带入口场景**的形式：

```
godot --headless --path <目录> res://scenes/server/ServerMain.tscn --server --port=8080
```

而线上 `ExecStart` 目前**没带入口场景**。实测两种都能正常起服、都能 `dtls=on`
（2026-09-09），差别只是不带场景时会去加载 UI 主场景，stderr 多一条启动图
加载失败（`.godot/imported/` 不进服务器包，是预期的）。

不是必须改，但改了之后**线上跑的配置就和冒烟测试验过的配置一致** ——
现在这两者其实是两条不同的启动路径，冒烟测试绿不代表线上那条路验过。

---

## 回滚

把 `NetworkConfig.gd` 的 `const USE_DTLS := true` 改回 `false`，
重新打包部署，客户端也要一起换。**两端必须一致** ——
不一致时客户端不会报错，只会卡在连接中直到超时。

---

## 以后换证书要做的三件事（必须一起做）

1. 本机跑 `tools/dtls_make_cert.tscn --force` 生成新的一对
2. 新私钥替换服务器上的 `/etc/glory/battle_key.pem`，重启
3. **客户端重新发版** —— 新证书在 `NetTLSCert.gd` 里，随包走

漏掉第 3 步 = 所有老客户端连不上。这是自签名 pin 证书的固有代价，
换成正式 CA 证书可以免掉，但那需要先有域名（见 `C15`：现在是硬编码 IP）。
