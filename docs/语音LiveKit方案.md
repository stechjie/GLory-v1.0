# 语音改用 LiveKit：实施规格

> 2026-09-19 写。**状态：等他看过再动手。**
> 来由：09-18 他拿 LiveKit 问能不能三端都用 → 查实 LiveKit 本身成熟、但没有现成的 Godot 手机插件 →
> 09-19 定：LiveKit 自建 + 每个平台一层薄桥接 + 游戏里只有一个 `VoiceService` 入口；接受多跑一个服务程序。
> 讨论过程见 [聊天系统设计](聊天系统设计.md) 第九节末尾的指针；本文是照着做的那一份，给我或 Codex 都能用。

## 零、一句话

语音**不再**由我们自己录音、压缩、经战斗服务器转发。改成：

- 同一台 GCP 机器上多跑一个 **LiveKit 语音服务器**（第三个程序，不是第三台机器）；
- 安卓、苹果、电脑各写**一层很薄的桥接**，调用 LiveKit 官方开发包（它们自带录音、回声消除、降噪、Opus、抖动缓冲、断线重连）；
- 游戏里**只有 `VoiceService` 一个入口**，界面和游戏代码不管是哪个平台；
- 战斗服务器只做两件事：**发钥匙**（只能进本队语音房间）和**踢人**（换队、离开、关房时）。

## 一、已经定下来的

| 项 | 定了什么 | 谁定 / 何时 |
|---|---|---|
| 平台 | 安卓、苹果、电脑**都要做好** | 他，09-19 |
| 语音服务器 | LiveKit 自建，单个程序，和账号服务器、战斗服务器**同一台 GCP 机器**；不用 Redis、Kubernetes、LiveKit 官方云 | 他，09-19 |
| 房间 | 每个对局房间、每队一个语音房间；敌方拿不到本队的钥匙 | 09-19 |
| 发钥匙 | **战斗服务器**（只有它知道谁坐哪队）；账号服务器不动 | 09-19 |
| 模式 | 保留「关 / 只听 / 开麦」，直接开麦对话（不是按住说话） | 沿用 09-11 |
| 切后台 | 语音停，回来恢复原档位；**不申请后台音频**（苹果审核更简单） | 沿用 |
| 旧代码 | 自写的录音压缩、战斗服务器转发、电脑试用版**一次删干净**，不留两套 | 他的「没用就删」 |
| 协议号 | 30 → **31**（删两条语音转发消息、加两条钥匙消息） | — |
| 失败隔离 | LiveKit 挂了只有语音不能用；登录、房间、对战、文字聊天照常；**开局不等语音** | 09-19 |

## 二、整体结构

```
                         Glory 客户端
             ┌──────────────┼──────────────────┐
             │              │                  │
      HTTPS / WebSocket   ENet（UDP 8080）   WebRTC（wss 信令 + UDP 7882 / TCP 7881 媒体）
             │              │                  │
        账号服务器        战斗服务器  ──踢人──▶  LiveKit 语音服务器
   (FastAPI，不改)     (Godot 无界面)   (本机 HTTP)   (新增，同一台机器)
                          │
                          └── 发钥匙给客户端（只能进本队房间）

客户端内部：
  界面（VoiceControls / VoicePanel）
        │
  VoiceService.gd（唯一入口：档位、屏蔽、谁在说话、要钥匙、自动断开）
        │   Engine.get_singleton("GloryVoice") —— 三个平台同一个名字、同一套方法
   ┌────┼──────────────┬─────────────────┐
 安卓：Kotlin 插件    电脑：C++ 扩展       苹果：Swift 插件
 LiveKit Android SDK  LiveKit C++ SDK     LiveKit Swift SDK
```

## 三、服务器端

### 3.1 LiveKit 部署（同一台 GCP 机器）

- **版本固定**：LiveKit server `v1.13.7`（09-14 发布）。写死在安装脚本里，升级只改这一处。
- **新增文件**：`deploy/livekit/`
  - `README.md`：一次性准备与验证步骤（同 `deploy/README.md` 的写法）
  - `install_livekit.sh`：**只有这一个文件**，配置与 systemd 单元写在脚本里，可以直接用网页 SSH「上传文件」传上去跑。
    - 先查语音域名是否指到这台机器；
    - 下载固定版本、核对校验和、装到 `/usr/local/bin`；
    - 生成密钥、写配置、启用服务；
    - 给 Caddy 主配置补 import（先备份，校验不过就还原）；
    - 写战斗服务器那份配置，最后从外面访问一次确认证书。
- **配置要点**（`/etc/livekit.yaml`，只有 root 可读）：

```yaml
port: 7880                # 信令 + 管理接口；只给本机和 Caddy 用，防火墙不开
rtc:
  tcp_port: 7881          # UDP 被封时走 TCP
  udp_port: 7882          # 所有媒体走这一个 UDP 端口（单机够用）
  use_external_ip: true   # GCP 的网卡是内网地址，靠 STUN 找到公网 IP
keys:
  <API_KEY>: <API_SECRET> # 安装脚本随机生成
turn:
  enabled: false          # 先不开，见 3.5
logging:
  level: info
```

- **端口**：

| 端口 | 协议 | 对外？ | 用途 |
|---|---|---|---|
| 7880 | TCP | **不开** | 信令与管理接口；外面经 Caddy 443 进来，战斗服务器走本机 `127.0.0.1:7880` |
| 7881 | TCP | 开 | 媒体的 TCP 备用通道 |
| 7882 | UDP | 开 | 媒体 |

- **Caddy**：新申请一个免费 DuckDNS 子域名（例：`glorytd-voice.duckdns.org`，**他来申请**），指向同一个 IP；`deploy/Caddyfile` 加一个站点，反代到 `127.0.0.1:7880`（Caddy 自动处理 WebSocket 和证书）。
- **GCP 防火墙**：放开 `tcp:7881`、`udp:7882`（80 / 443 已经开着）。
- **密钥只存两处**：`/etc/livekit.yaml`，和战斗服务器读的密钥文件（3.2）。**不进仓库、不进客户端。**
- **验证**：`journalctl -u livekit -n 20` 看到在 7880 / 7881 / 7882 监听、找到公网 IP；再用第七节第 1 阶段的办法拿钥匙进房。

### 3.2 战斗服务器：发钥匙

- **两条新消息**（替换掉语音转发那两条）：
  - 客户端 → 服务器：`_rpc_team_voice_token_request()` —— **不带任何参数**。谁、哪个房间、哪一队，一律由服务器从连接反查（同聊天、同旧语音的做法；带参数就等于能冒充别人）。
  - 服务器 → 客户端：`_rpc_team_voice_token(url: String, token: String, room: String, error: String)`。
- **发不发**：请求的连接必须在某个房间的某个**真人座位**上；大厅、备战、战斗都可以（大厅也有语音按钮）。限流：每人 10 秒 5 次，软限（不计 strike，同聊天）。
- **钥匙内容**（JWT，HS256，用 API secret 签）：

| 字段 | 值 |
|---|---|
| `iss` | API key |
| `sub`（身份） | 这个座位名片里的**好友码**（账号服务器签过的，可信）；没有名片的测试座位用 `seat<N>` |
| `name` | 名片里的昵称 |
| `nbf` / `exp` | 现在 / 现在 + 10 分钟（过期只影响**首次**进房；在线的人 LiveKit 会自动续） |
| `video.roomJoin` | `true` |
| `video.room` | 房间名，见下 |
| `video.canSubscribe` | `true` |
| `video.canPublish` | `true` |
| `video.canPublishSources` | `["microphone"]`（只准发麦克风，不准发摄像头、屏幕） |
| `video.canPublishData` | `false` |

- **房间名**：`g<房间 id>-<随机串>-t<队>`。随机串在建房时生成、存进房间（要确认会随房间快照保存），保证上一局的旧钥匙进不了这一局。
- **密钥文件**：战斗服务器启动时读一个语音密钥文件（`{"url": "wss://…", "api_key": "…", "api_secret": "…"}`），放在出战名片公钥同一个目录（照 `BattleCard.load_server_key()` 的做法）。**读不到照常启动**（语音不是必需的，和名片公钥不同），请求钥匙时回「服务器没配语音」。
- **实现**：纯 GDScript（`HMACContext` + SHA-256 + base64url），不加依赖。门禁用 JWT 标准测试向量对账签名。

### 3.3 战斗服务器：踢人

LiveKit 文档：钥匙过期**只影响首次连接**，进去以后服务器还会自动给在线的人续钥匙。所以**钥匙只管进门、不管出门** ——
玩家换了队或离开，不主动踢的话，他还留在旧队的语音房里听。

- **怎么踢**：`POST http://127.0.0.1:7880/twirp/livekit.RoomService/RemoveParticipant`，内容 `{"room": …, "identity": …}`，
  请求头 `Authorization: Bearer <带 roomAdmin 权限、限这个房间的钥匙>`。对已经离开的人调用，会把他的钥匙作废（文档说明）。
  关房用同一套接口的 `DeleteRoom`，两个队伍房间都删。
- **所有座位变动都走一个函数** `_voice_seat_released(room, slot, identity)`，触发点：

| 场景 | 现在的函数 | 语音要做的 |
|---|---|---|
| 大厅换座位、**跨队** | `_room_do_move` | 踢出旧队房间（同队换座不用踢） |
| 主动离开 / 被踢 / 大厅掉线 | `_room_remove_peer`（`_room_kick_slot` 经它） | 踢出 |
| 座位被接管（AI 顶位、别人坐进来） | 座位接管的那几条路径（实现时逐条列进门禁） | 踢出原来那个人 |
| 关房 | `_room_close` | 删掉两个队伍房间 |
| 对局中掉线、座位保留 | `_room_reserve_peer` | **不踢**：人还在这一队，重连回来接着说 |

- **不阻塞对局**：请求异步发，失败写日志、重试两次；门禁钉住上表每条路径都调了它。

### 3.4 战斗服务器要删的

`team_send_voice`、`_rpc_team_voice_submit`、`_rpc_team_voice`、`voice_recipients`、语音流量统计（`_voice_stats*`）、
`NetworkConfig.CH_VOICE`、`RateLimitService` 的 `"voice"` 额度。协议注释写 v31。

### 3.5 中继（TURN）先不开

有的网络会封 UDP，这时靠 7881 的 TCP 通道；再不通才需要中继。中继最好用 443 端口，而这台机器的 443 已经给 Caddy 了，
中继还要单独的域名和证书。所以：**先不开**；第 5 阶段测马来西亚各家网络，有连不上的再用另一个免费 DuckDNS 子域名在 5349 端口开。

## 四、游戏客户端（GDScript）

### 4.1 `VoiceService` 仍是唯一入口

- **保留**：三档模式、离开房间 3 秒自动关、切后台停、开麦前用途说明、按好友码屏蔽（换座位跟着人走）、队友列表、「说话中」、`VoiceControls` / `VoicePanel` 界面。
- **改的是后端**：从「自己收发语音包」变成「向战斗服务器要钥匙 → 让桥接去连 LiveKit」。
- **档位流转**：

| 从 → 到 | 做什么 |
|---|---|
| 关 → 只听 | 要钥匙 → `joinRoom(url, token, true)`（只听） |
| 只听 → 开麦 | 没权限先走用途说明 → `setMicrophoneEnabled(true)`（安卓可能要换音频模式，见 5.1） |
| 开麦 → 关 / 离开房间 | `leaveRoom()` |
| 自己跨队换座 | 重新要钥匙、重连新房间（旧房间服务器会踢） |
| 钥匙请求失败 / 连不上 | 按钮显示「语音暂时连不上」，退避重试；**对局照常** |

- **身份对座位**：远端的身份就是好友码，用房间名片里的好友码（`team_seat_profiles`）对回座位；屏蔽、音量都按好友码。

### 4.2 三个平台的桥接：同一个单例名、同一套方法

三个平台都注册成 `Engine.get_singleton("GloryVoice")`，`VoiceService` 不分平台。

| 方法 | 说明 |
|---|---|
| `hasRecordPermission() -> bool` | 有没有麦克风权限 |
| `joinRoom(url, token, listen_only) -> String` | 开始连（异步）；空串 = 已开始，否则是原因 |
| `leaveRoom()` | 断开，停止录音和播放 |
| `setMicrophoneEnabled(enabled) -> String` | 开 / 关麦（发布或取消麦克风） |
| `setParticipantVolume(identity, volume)` | 某个队友的音量，0 ~ 1，0 就是屏蔽（只影响自己） |
| `getStatus() -> String` | JSON：`state`（disconnected / connecting / connected / reconnecting / failed）、`error`、`mic_on`、`mic_error`（开麦受理了却打不开的原因）、`self_speaking`（自己在不在说）、`speaking`（队友身份列表）、`participants`、`audio_mode`、`output`。放弃重连 / 被请出房间时 `state = failed` |
| `getCapabilities() -> String` | JSON：平台、开发包版本、回声消除类型（系统 / WebRTC）、`listen_mode_fixed_at_join`（只听 / 开麦的声音模式是否只能在进房时定，安卓是） |

`VoiceService` 每 0.25 秒拉一次 `getStatus()`（同现在），不依赖各平台不同的信号机制。
门禁用**假桥接**跑完整状态机（同现在 `voice_check` 的假插件）。

> 方法名刻意不用 `connect` / `disconnect`：那是 Godot 每个对象自带的方法（接信号用的），桥接单例上同名会被截走。
> 这张表在代码里是 `VoiceService.BRIDGE_METHODS`，`voice_check` 拿它和假桥接对账。

## 五、三个平台

### 5.1 安卓（第 2 阶段）

- **语言与依赖**：Kotlin；`io.livekit:livekit-android`（开工时取最新稳定版，09-18 查到 2.28.2），版本写死。
- **打包方式要改**：现在的插件是 `build_aar.ps1` 用 javac 直接编 Java。LiveKit 是 Kotlin、接口是协程，桥接改用 **Kotlin + Gradle 打 aar**；
  LiveKit 依赖在导出插件里用 `_get_android_dependencies` 声明，出包时 Godot 的 Gradle 从 Maven 下载 —— **每台出包的电脑都要能上网**。
- **音频模式**：
  - 只听：`MediaAudioType`（媒体音频；蓝牙耳机保持高音质，路由交给系统）
  - 开麦：`CallAudioType`（通话模式，系统回声消除）
  - 两种模式要在建 Room 时指定，**切换大概要断开重连一下** —— 真机评估；接受不了就只听也用通话模式（代价：蓝牙耳机音质变差）。
- **权限**：`RECORD_AUDIO`（现有流程）。出包后检查权限清单，**如果 LiveKit 带进了摄像头等我们不用的权限，用清单合并规则去掉**（隐私申报与玩家观感）。
- **包体**：会变大（WebRTC 原生库每种芯片一份）；出包后记录大小。
- **删**：`android_plugins/glory_voice/` 里的 `AdpcmCodec`、`OpusCodec`、`FrameCodec`、`Packetizer`、`RemoteStream`、`Resampler`、`VoicePacket`、`VoiceSelfTest`，以及插件里自己的录音 / 混音线程（**09-19 已删**；`build_aar.ps1` 改写成跑 Gradle）。

**09-19 写下来的做法（第 2 阶段）**：

- **桥接**：`android_plugins/glory_voice/src/com/glory/voice/GloryVoicePlugin.kt`，单例名、类名不变（`GloryVoice` / `com.glory.voice.GloryVoicePlugin`），方法照 4.2 那张表。
  - LiveKit 的操作都投到安卓主线程；`getStatus` 读主线程写好的快照。
  - 每次进房 / 离开都换一个编号，旧房间迟到的事件一律丢掉。
- **只听 / 开麦两种声音模式**：LiveKit 只能在建房间时定，所以换档 = 退房再进。
  - `getCapabilities` 报 `listen_mode_fixed_at_join: true`，由 `VoiceService` 去重进。
  - 重进用刚拿到的钥匙（8 分钟内有效），不再问战斗服务器，中间断一两秒。
  - 真机上如果觉得换档太慢或不稳，改成「只听也用通话模式」只动 Kotlin 一行（代价是蓝牙耳机音质变差）。
- **麦克风打不开**（被通话占着、没权限）是异步报的：`getStatus.mic_error`。`VoiceService` 看到后退回只听，并把原因留给界面。
- **切后台**：桥接自己断开，报 `failed / paused`；回到前台，`VoiceService` 重新要钥匙进房。
- **打包**：`build_aar.ps1` 把插件目录拷到纯英文临时目录，用本机 Gradle 8.11.1 编译，AGP、Kotlin 版本与 Godot 4.7.1 构建模板一致。
  - LiveKit 只 compileOnly，插件包里不带。
  - 打进 APK 的那份由导出插件 `_get_android_dependencies` 交给出包的 Gradle。
  - 三处版本号（`build.gradle.kts`、导出插件、Kotlin 的 `LIVEKIT_VERSION`）由 `voice_check` 对账。
- **JitPack**：LiveKit 依赖的 `com.github.davidliu:audioswitch` 只发布在 JitPack。
  - 导出插件把 `https://jitpack.io` 交给出包的 Gradle。
  - 编译插件时 JitPack 只准拿这一组。
  - 每台出包的电脑第一次出包都要能连上 JitPack。
- **去掉 LiveKit 带来的权限**：LiveKit 的清单带摄像头、`FOREGROUND_SERVICE(_MEDIA_PROJECTION)` 和屏幕录制服务。
  - 导出插件在应用清单里用 `tools:node="remove"` 去掉。只有写在应用清单里才可靠，库清单之间的 remove 要看合并顺序。
  - 出包后 `tools/apk_identity.py` 验：包里有桥接、有 LiveKit、没有摄像头 / 屏幕录制权限。

### 5.2 电脑 Windows（第 3 阶段；前提：这台电脑装好 Visual Studio 生成工具「使用 C++ 的桌面开发」）

> **2026-09-19 改：先做「甲」，下面「所有声音都经过 Godot」那套降为「乙」，甲测不过再做。**
>
> 下载的 LiveKit C++ 开发包 1.11.0 自带「系统音频」（`PlatformAudio`）：麦克风、喇叭、回声消除、降噪、自动音量都由
> WebRTC 自己的音频设备模块处理，和手机上的做法一样。用户选了先做甲。
>
> | | 甲：开发包自带的系统音频 | 乙：全部经过 Godot（下面原来的写法） |
> |---|---|---|
> | 工作量 | 小，主要是接线 | 大，要自己串音频、调延迟 |
> | 外放时队友声音的回声 | 能消 | 能消 |
> | 外放时游戏音乐 / 音效漏给队友 | **不保证**：WebRTC 只认得自己放的声音。戴耳机没这个问题 | 能消（参考信号是 Godot 总输出） |
>
> 甲的做法：
> - **代码与编译**：
>   - C++ 扩展在 `native/glory_voice_desktop/`，用 `build_dll.ps1` 编译；
>   - godot-cpp 10.0.0-stable、LiveKit C++ SDK 1.11.0 和 SCons 都放在仓库外，默认位置写在 `build_dll.ps1` 里；
>   - 编出来的 dll、LiveKit 的两个 dll、VC++ 运行库都进 `addons/glory_voice/bin/windows/`，由 `glory_voice.gdextension` 声明，**跟着仓库走**。电脑版约多 28 MB。
> - **对游戏的接口**：单例名、方法照 4.2 那张表，`VoiceService` 不分平台。`listen_mode_fixed_at_join = false`，电脑上换档不用重进房间。
> - **屏蔽队友**：开发包的系统音频没有按人调音量的接口，所以屏蔽 = 退订这个人的声音，只分「听 / 不听」。
> - **关麦**：撤掉麦克风轨道并放掉录音源，不是静音。
> - **测试时看**：
>   - 外放 + 游戏音乐 + 开麦时，队友听不听得到游戏声；
>   - 关麦之后，Windows 任务栏的麦克风图标会不会消失。
>   - 游戏声漏得明显的话，先试把 `prefer_hardware` 打开（用 Windows 自带的语音处理；它可能以整机输出为参考），再考虑乙。

- **做法**：GDExtension（C++，godot-cpp）+ **LiveKit C++ SDK**（官方支持 Windows x64；头文件里有 `audio_source` / `audio_stream` / `audio_frame` / `audio_processing_module`）。
  社区的 godot-livekit（MIT，同样包 C++ SDK）可以参考写法，但**不直接依赖**（标着不稳定、只写到 Godot 4.5、没有回声消除）。
- **所有声音都经过 Godot**（这是电脑版能把游戏声也消掉的关键）：
  - 麦克风：Godot 录音（第 3 阶段在 `project.godot` 重新打开 `driver/enable_input.windows`；第 1 阶段随电脑试用版一起关掉了。**只对 Windows 开**，手机录音一律走桥接）→ LiveKit 的回声消除模块（回声消除 + 降噪 + 自动增益）→ LiveKit 音频源
  - 队友声音：LiveKit 音频流 → Godot 播放（`AudioStreamGenerator`，每个队友一路，可以单独调音量）
  - 回声消除的**参考信号 = Godot 主总线的最终输出**（游戏音乐 + 音效 + 队友声音都在里面）。LiveKit 自己的回声消除只认得它自己放的声音；
    把整路输出交给它，游戏声音才能一起被消掉
  - 参考信号和麦克风的时间差要设（stream delay），实测调
- **构建**：scons 或 cmake；dll 放 `addons/glory_voice/bin/windows/`，`.gdextension` 注册；按 Godot 4.7 编（MSI 4.7.1、同事 4.7.2 都能加载）。以后 Mac / Linux 电脑版同理。
- **删**：电脑试用版（`scripts/voice/` 里的 `DesktopVoiceBackend` / `VoiceAdpcm` / `VoicePacketCodec`）、`tools/fixtures/voice_adpcm_golden.json` 与对应门禁 —— **第 1 阶段已删**（它靠的战斗服务器转发没了）。

### 5.3 苹果（第 4 阶段；前提：有 Mac + 苹果开发者账号，游戏要有苹果版）

- **做法**：Swift + LiveKit Swift SDK，做成 Godot 苹果插件（`.gdip` + xcframework），注册同名单例 `GloryVoice`。
- **音频会话**：LiveKit 的 AudioManager 默认自己配置 AVAudioSession。要调成：**从外放出声（不是听筒）**、**游戏声被压低的程度可控**
  （苹果的「其他声音压低」设置，iOS 17 起有）。通话模式下苹果不会把游戏自己的声音消掉，而是**压低**它 —— 真机调。
- **Info.plist**：麦克风用途说明；**不开后台音频**。
- **开工前核实**：Swift SDK 当时的音频会话接口。

## 六、游戏声音和语音（最大的风险）

| 平台 | 游戏声会不会被麦克风收进去、发给队友 | 怎么处理 | 怎么验 |
|---|---|---|---|
| 电脑 | 会，除非参考信号里有游戏声 | 5.2：参考信号接 Godot 主总线输出 | 外放放音乐 + 开麦，让队友听 |
| 安卓 | 看厂商：通话模式的系统回声消除有的会消掉整机声音，有的不会 | 用系统通话模式；不行就开下面的保底 | 真机矩阵（第八节） |
| 苹果 | 不会被消掉，而是被**压低**；有的设置下还会跑到听筒 | 5.3：外放 + 压低程度 | 真机 |

**保底**：设置里加「语音时降低游戏音量」开关；第一次开麦时提示「戴耳机效果最好」。

## 七、分阶段与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| 1 | LiveKit 部署文件 + 战斗服务器发钥匙 / 踢人 + `VoiceService` 新后端 + 假桥接 + 门禁 + 协议 31。**09-19 代码与门禁已完成、未提交**（见下） | 门禁全绿；用 LiveKit 官方命令行工具拿战斗服务器发的钥匙进房：能进本队、进不了对面、换队后被踢 |
| 2 | 安卓桥接。**09-19 代码、门禁已写，插件包还没打**（要先下载 LiveKit 依赖，见 5.1） | 两台以上真手机：同队听得到、对面听不到、外放开麦无明显回声、游戏声没被队友听到、蓝牙 / 有线耳机、切后台再回来 |
| 3 | 电脑桥接（09-19 选甲，代码已写，等装好 VS 生成工具编译） | 电脑与手机互通；外放放游戏音乐开麦，队友听不到音乐（甲不保证这一条，实测后定要不要做乙） |
| 4 | 苹果桥接 | 苹果与安卓、电脑互通；游戏声压低程度可以接受 |
| 5 | 压测（账号 + 战斗 + 语音一起）+ 马来西亚网络实测 | 定：要不要开中继、要不要把语音搬到第二台机器；看 GCP 出站流量费 |

**发布顺序**：第 1 阶段删了旧转发、改了协议，**必须和第 2 阶段一起发**，不能出一个手机没语音的包。

**第 1 阶段做了什么（2026-09-19）**：

- 部署：`deploy/livekit/`（安装脚本、配置模板、systemd 服务、中文手册）；`deploy/Caddyfile` 加了 `import /etc/caddy/glory-voice*.caddy`。
- 战斗服务器：
  - `scripts/voice/LiveKitAuth.gd` 签钥匙，`LiveKitAdmin.gd` 踢人 / 删房间；
  - `NetworkService` 加发钥匙的两条 RPC，删掉语音转发的两条（数量仍 58）；
  - 在换座跨队、离开、AI 接管、关房四处调踢人；
  - 房间多了 `voice_salt` / `voice_used` 两个字段并随房间存盘；
  - 限流 `voice` 换成 `voice_token`（10 秒 5 次）；
  - 协议 30 → 31。
- 客户端：`VoiceService` 改成「要钥匙 → 桥接进房」；`VoicePanel` 显示「为什么用不了 / 连不上」和连接诊断。
- 删了：电脑试用版、语音转发、`CH_VOICE`、`project.godot` 里的电脑录音开关、ADPCM 样例与生成脚本。
- 门禁：`voice_check` 重写（243 项），`chat_check` / `carrot_online_check` 跟到 31。
- **还没做的验收**：用 LiveKit 命令行工具拿战斗服务器发的钥匙真进房（要先在服务器上装好 LiveKit）。
- **现在的手机包点语音会失败**：旧插件没有 `joinRoom`，要等第 2 阶段。这正是不能单独发的原因。
电脑版：Windows 上没加载起语音扩展时，显示「语音组件没有加载起来」；Mac / Linux 的电脑版显示「这个系统的电脑版还没有语音」。苹果版随苹果版游戏一起。

## 八、门禁与测试

- `tools/voice_check` 重写：
  - 钥匙：只含本队房间、10 分钟、只准发麦克风、签名对标准向量
  - 踢人：3.3 表里每条路径都调了 `_voice_seat_released`；对局中掉线**不**踢
  - 密钥：不在仓库、不在客户端代码里
  - `VoiceService` 状态机（假桥接）：三档、跨队重连、连不上不影响对局、离开房间自动断
  - 导出插件声明了 LiveKit 依赖；出包后权限清单里没有摄像头
- `tools/chat_check`：RPC 签名指纹与协议 31。
- `tools/apk_identity.py`：包里有桥接和 LiveKit 库。
- **真机清单**：
  - 厂商：三星、小米 / 红米、OPPO / vivo、Pixel
  - 网络：Unifi、TIME 的 Wi-Fi；CelcomDigi、Maxis、U Mobile 的 4G / 5G；Wi-Fi 与 5G 互切；VPN；弱网
  - 设备：蓝牙耳机、有线耳机
  - 场景：锁屏、切后台
  - 我们自己的几条：
    - 外放开麦时队友听不听得到我这边的游戏音乐；
    - 「只听」与「开麦」时蓝牙耳机的音质；
    - 苹果上游戏声会不会被压太低或跑到听筒。

## 九、一次删完的清单

- 安卓：见 5.1「删」
- 电脑：见 5.2「删」
- 战斗服务器：见 3.4
- 门禁：`voice_check` 里 ADPCM / 包格式 / 插件指纹相关的用例（换成第八节的）
- 文档：`docs/聊天系统设计.md` 第九节的自建方案段落改成指向本文；`docs/语音隐私与数据安全申报.md` 更新（语音改走我们自己的 LiveKit 服务器，传输加密为 WebRTC 的 DTLS-SRTP，仍然不录音、不存）
- 发行：第三方许可声明加上 LiveKit（Apache-2.0）与 WebRTC

## 十、还没定 / 开工前核实

- 安卓「只听 / 开麦」两种音频模式来回切的实际代价（真机）
- 苹果 Swift SDK 的音频会话接口（第 4 阶段开工时）
- 同事那台（Godot 4.7.2）出包时 Gradle 能从 Maven 下载 LiveKit
- 语音子域名（他来申请 DuckDNS）
- GCP 出站流量费（第 5 阶段压测时看）

## 资料

- LiveKit 服务器：<https://github.com/livekit/livekit>（Apache-2.0；配置样例 `config-sample.yaml`）
- 钥匙与权限：<https://docs.livekit.io/frontends/reference/tokens-grants/>
- 踢人等服务器接口：<https://docs.livekit.io/reference/other/roomservice-api/>
- 自建部署（中继要单独域名与端口）：<https://docs.livekit.io/home/self-hosting/deployment/>
- 回声消除与降噪（客户端自带、免费；官方云的增强降噪才收费）：<https://docs.livekit.io/transport/media/noise-cancellation/>
- 安卓开发包：<https://github.com/livekit/client-sdk-android>；音频类型：<https://docs.livekit.io/reference/client-sdk-android/livekit-android-sdk/io.livekit.android/-audio-type/index.html>
- C++ 开发包：<https://github.com/livekit/client-sdk-cpp>
- 苹果「其他声音压低」：<https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration>
- 社区 Godot 插件（只支持电脑，仅参考）：<https://github.com/NodotProject/godot-livekit>
