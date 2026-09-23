class_name NetworkConfig
extends RefCounted

# Client-side production target. Public server info only; no secrets belong here.
const SERVER_IP := "34.142.168.170"
const SERVER_PORT := 8080
const CONNECTION_TIMEOUT := 10.0
const USE_DEDICATED_SERVER := true

# --- 传输加密（C14）---------------------------------------------------------
# 战斗链路走 DTLS。实现在 scripts/multiplayer/NetTLS.gd，那里写了为什么审计文档
# 原来记的"插不进去"是错的，以及为什么用 client_unsafe。
#
# **这个常量是客户端和服务器共同的唯一真相，两端必须一起改、一起部署。**
# 不一致的症状不是干净报错，而是客户端**卡在 CONNECTING 直到超时** ——
# DTLS 在协议握手之下，对不上时连 protocol_mismatch 都发不出来。
# 这与 v17 顶协议号那次是同一类代价，且已被接受为"有意的，不是回归"。
#
# 关掉它 = 逐字节回到明文时代（连回放分块阈值都会退回原值）。
# 开着但服务器找不到私钥 = **拒绝启动**，不会静默退回明文。
const USE_DTLS := true
# v6: 新增备战期佣兵同步 RPC（_rpc_team_prep_mercs / _rpc_team_prep_mercs_submit）。
# v7: 宝物归属改服务端 intent，新增 5 个 RPC（_rpc_treasure_choice / _rpc_treasure_refresh /
#     _rpc_treasure_offer / _rpc_treasure_granted / _rpc_treasure_denied）；
#     resume payload 新增 owned_treasures / treasure_offer。
# 增删或重命名 @rpc 方法会改变 Godot 的 RPC 映射与校验，新旧版本混连会静默调错函数——
# 客户端与服务器必须一起升级，且协议号必须同步 +1。
# v8: match_state 新增 `run_outcome`（TeamOutcome.TEAM_A/TEAM_B/DRAW）。
#     整局归属改由 TeamOutcome 统一判定：第 21 回合按最终战结果；双杀且无正面
#     胜负可依时记平局，不再默认判 A 队胜。`team_run_won` 保留为派生布尔。
# v9: replay 改为「服务端压缩后的 PackedByteArray」下发（`_rpc_team_replay` 签名变更）。
#     实测最坏一场 3639 KB -> zstd 61.8 KB，六人一轮出口从 43 MB 降到 740 KB；
#     同时整局只序列化一次（此前逐 peer 发 Dictionary，同一份要序列化 6 次）。
#     废除 `send_rival_replay` 开关：它与「两队 replay 一律全发」的产品规则冲突。
# v10: 加入连接握手（状态信封 E1 / C10）。协议号从此在**连接建立之前**校验，
#      不再是"打完整个备战、第一次提交棋盘才被踢"。旧版本客户端不发认证数据，
#      会被 auth_timeout 直接拒在门外 —— 这正是想要的行为。
#      同时引入 NetError 统一错误分级（terminal / retryable / transport）。
# v11: 状态信封 E2。房间权威状态合并成一条带序号的全量快照 `_rpc_room_state`，
#      取代 team_lobby / team_leader / team_assign_slot / resume_state 四条各自
#      为政的下行。`server_epoch` + 每房 `state_seq`，客户端拒收不前进的包。
#      `_rpc_round_resync` 改为不携带状态的 `_rpc_board_rejected`。
# v12: 状态信封 E3。新增 `battle_id` + `_rpc_result_ack`：所有在线真人确认收到
#      结算才推进下一轮（此前任意一人按准备就能把还在看回放的人拽走）。
#      新增 `_rpc_leave_intent` / `_rpc_leave_receipt`：明确退出走 request_id +
#      幂等回执，**收到确认才清凭证**；技术失败改走 enter_recoverable_failure，
#      不发 leave、不清凭证。
# v13: 状态信封 E4。宝物选择 / 宝物刷新 / 黄金祭坛三笔一次性交易全部改为
#      `request_id` + 服务端存结果 + 重试重放同一份结果（`room.tx_log`，定长
#      16/座位、随座位清理、随房间持久化）。四条回复 RPC（`_rpc_treasure_offer`
#      / `_rpc_treasure_granted` / `_rpc_treasure_denied` / `_rpc_altar_result`）
#      签名前置 `request_id`，客户端据此去重并重发。
# v14: 通道映射（B9）。ping/pong 改 unreliable，replay / client_log / team_boards
#      改走独立可靠通道 CH_BULK，其余留在 CH_CONTROL。建 peer 时显式申报
#      ENET_CHANNELS —— 两端不一致会让 bulk 通道的包被静默丢弃。
# v15: P1 备战经济账本（服务端侧）。新增 `_rpc_economy_intent` / `_rpc_economy_receipt`，
#      `room.prep[slot]` 座位账本（金币 / 商店 / roster+cost_basis / 赌博标记），
#      room_state payload 新增 `economy` 段。**默认关闭**（ServerFlags 两个开关都是
#      false），开启后先只影子比对，客户端改造完成前不得翻 authoritative。
# v16: 确定性屏障（无线格变更）。协议 15 的服务器包（2026-07-28）之后，战斗模拟
#      与数值表被大改：BattleSimulator / BattleSimShared / BattleSimSkills /
#      BattleSimTreasures / DamageService，以及 race_units / bosses / mercenaries /
#      pve_monsters / formation_allies / pets 六张 JSON。RPC 签名和通道一个没动，
#      所以旧服务器**不会**拒绝新客户端，只会两边各算各的、结算对不上——这种
#      静默分歧比明确报错难查得多。顶这一格就是为了让版本校验把它拦下来。
#      规则：模拟逻辑或数值表改动到会影响战斗结果时，即使没有线格变更也必须顶号。
# v17: 回放传输补齐分块/确认/重试，新增两个 RPC（_rpc_team_replay_chunk、
#      _rpc_replay_ack）。**加 @rpc 方法会平移整套 RPC 的 wire ID**（同 :1846 与
#      :3759 两处注释），旧服务器与新客户端的方法编号会整体错位——那是静默错位，
#      症状是随机调错方法，比任何报错都难查。顶号把它变成握手阶段一次干净的
#      protocol_mismatch 拒绝，玩家看到的是可读原因。
#      代价：线上服务器必须同步重新部署，否则两端都连不上。这是有意的，不是回归。
# v18: 萝卜经济（4a10441 `carrot` 起）。ECONOMY_ACTIONS 新增 upgrade_harvest_tech /
#      hire_merc_carrot / draw_upgrade_stone，room_state 的 `economy` 段新增
#      carrot_authoritative / carrots / harvest_tech_level / merc_carrots_spent_total /
#      last_harvest_round / stone_draw_used_round / team_upgrade_stones。
#      **这一格是补顶的**：那批改动当时没顶号，于是线上那台萝卜之前的服务器与新
#      客户端协议号都是 17、握手照常放行，然后 _rpc_economy_intent 因为
#      _economy_action_enabled() 不认识这三个动作而直接 return（不发回执），
#      room_state 也不带 carrot_authoritative —— 玩家看到的是萝卜恒为 0、三个按钮
#      点了没反应、一条报错都没有。这正是 v16 注释里写的那种静默分歧。
#      规则重申：改服务端契约（RPC、ECONOMY_ACTIONS、room_state 字段集）必须顶号，
#      并同步 tools/carrot_online_check.gd 的 PINNED_PROTOCOL / PINNED_CONTRACT。
# v22: 房间 / 局内快捷短语（docs/聊天系统设计.md 批次 A），新增两个 RPC
#      （_rpc_team_chat_submit、_rpc_team_chat）。**与 v17 完全同一类。**
#      2026-09-10 实测漏顶号的后果：Godot 4.7 会先一步在 scene cache 上比对两端
#      NetworkService 的方法表，客户端直接刷
#          process_simplify_path: The rpc node checksum failed.
#          Make sure to have the same methods on both nodes. Node path: NetworkService
#      比 v17 那会儿好一点的是：这次**有明确报错**，不用靠猜。
#      但危险的不是那条错误本身，而是它背后的事实 —— 两端的方法表已经不一致，
#      于是 v17 注释里那件事同时成立：**方法编号错位，RPC 可能被派发到别的方法上**。
#      ⚠️ 方法表不一致时联机行为是**未定义的**。不要试图靠观察症状判断"是不是还能用"。
#      代价同 v17：**线上战斗服务器必须同步重新打包部署**，否则两端连不上。
#      这是有意的，不是回归。
# v23: four-star ascension consumes 500/800/1100 gold plus a team stone.
# Upgrade intents carry shadow-mode gold; receipts carry the trusted tier cost.
# v24: 房间 / 局内自由文字（docs/聊天系统设计.md 批次 D），新增两个 RPC
#      （_rpc_team_chat_text_submit、_rpc_team_chat_text）。**与 v17、v22 完全同一类**：
#      加 @rpc 方法会平移整套 RPC 的 wire ID。
#      🔴 **为什么是 24 不是 23**：批次 D 与上面的四星升阶是 2026-09-11 同一天分头顶的号，
#      两边都写成了 23，但两个「23」一个多了两条 RPC、一个改了经济契约 —— 合并后的代码
#      与任何一边单独打出来的 23 都不一样。同一个号对应两套方法表，正是 v17 / v22 那种
#      握手放行、然后方法错位的静默事故。**合并时撞号，一律顶到一个没人用过的新号。**
#      代价同上：**线上战斗服务器必须用合并后的代码重新打包部署到 p24**（make_server_zip.ps1），
#      否则新客户端连不上。确认依据是服务器日志里的 `server started protocol=24`。
# v25: 游戏内组队语音（docs/聊天系统设计.md 第九节），新增两个 RPC
#      （_rpc_team_voice_submit、_rpc_team_voice）和一条用户通道 CH_VOICE。**与 v17、v22、v24 同一类**：
#      加 @rpc 方法会平移整套 RPC 的 wire ID。
#      代价同上：**线上战斗服务器必须重新打包部署到 p25**（make_server_zip.ps1），
#      否则新客户端连不上。确认依据是服务器日志里的 `server started protocol=25`。
# v26: 聊天分范围（docs/聊天系统设计.md「聊天范围」，2026-09-14）。四条聊天 RPC
#      （_rpc_team_chat_submit、_rpc_team_chat、_rpc_team_chat_text_submit、_rpc_team_chat_text）
#      各加一个 team_only 参数，③ 据此只转同队或转全房。**RPC 数量没变（仍是 59），
#      但参数个数变了**：两端版本不一致时参数对不上，收方直接丢掉这条 RPC
#      （日志里只多一行 RPC 报错），聊天静默失效 —— 所以一样要顶号。
#      tools/chat_check 的 PINNED_RPC_SIGNATURES 挡的就是「只改参数、忘了顶号」。
#      同批带上语音 v1.1（语音包格式 v2；③ 不解析语音包，这件事本身不需要顶号）。
#      代价同上：**线上战斗服务器必须重新打包部署到 p26**（make_server_zip.ps1），
#      否则新客户端连不上。确认依据是服务器日志里的 `server started protocol=26`。
# v27: 同时在线上限与排队（backend/app/admission.py，2026-09-14）。**线格一个字节都没变**：
#      RPC 数量、签名、通道全都没动。顶这一格只为一件事 —— 让没有排队逻辑的旧包连不上。
#      排队拦在客户端的启动画面，战斗服务器不认识账号；旧包根本不走那道门，只有协议号挡得住它。
#      同 v16 那格（没有线格变更也顶号）。
#      代价同上：**线上战斗服务器必须重新打包部署到 p27**（make_server_zip.ps1），
#      否则新客户端连不上。确认依据是服务器日志里的 `server started protocol=27`。
#      并且**账号后端要先于客户端更新**（deploy/README.md「在线人数上限与排队」）。
# v28: 备战「出战种族」（scripts/units/RacePick.gd，2026-09-15）。**改了两条 RPC 的参数**：
#      _rpc_team_set_ready 与 _rpc_team_start_request 各加一个 races 参数 —— 出战种族跟着
#      「准备 / 开始」一起到服务器，开局第一次摇商店时服务器手里一定已经有每个座位的选择。
#      RPC 数量没变（仍是 59），**与 v26 同一类**：两端版本不一致时参数对不上，收方直接丢掉
#      这条 RPC —— 准备按不下去、房主开不了局，而且不报错。
#      代价同上：**线上战斗服务器必须重新打包部署到 p28**（make_server_zip.ps1），和新 APK 一起上，
#      否则新客户端连不上。确认依据是服务器日志里的 `server started protocol=28`。
#      账号服务器不用动（它不认识战斗协议号）。
# v29: 备战萝卜营地公开席位状态。新增 `_rpc_team_submit_active_pet`，并在
# room_state 下发 `seat_pets` 与仅本回合的 `carrot_harvest_gains`：营地只渲染真实
# 玩家或 AI 的实际宠物，回合采集用各宠物头顶的小型 +N 提示，不暴露他人余额。
# 新 RPC 改变了 Godot 的 NetworkService 方法表，客户端和战斗服务器必须同步部署到 p29；
# 否则由连接握手明确拒绝，绝不能让 checksum 不一致的双方继续联机。
# v30: 出战名片（scripts/multiplayer/BattleCard.gd，docs/商城系统设计.md 第五节，2026-09-16）。
#      座位上的名字头像、出战宠物、出战种族只认账号服务器签过名的名片。**改了 RPC 方法表**：
#        · 删 _rpc_lobby_identity（手机把登录令牌交给战斗服务器那条）
#        · 删 _rpc_team_submit_active_pet（v29 加的宠物自报）
#        · _rpc_team_create_room / _rpc_team_join_room 各加一个 card 参数
#        · _rpc_team_set_ready / _rpc_team_start_request 去掉 races 参数
#      代价同上：**战斗服务器必须重新打包部署到 p30**，和新 APK 一起上。
#      **而且战斗服务器上要先放好名片公钥**（deploy/BATTLE_SERVER_KEY.md「出战名片公钥」），
#      否则它拒绝启动；**账号服务器要先于二者更新并配好私钥**（发名片的接口在那边）。
#      确认依据是服务器日志里的 `battle card key loaded` 与 `server started protocol=30`。
# v31: 语音改用 LiveKit 自建（docs/语音LiveKit方案.md，2026-09-19）。语音不再经过战斗服务器：
#      删 _rpc_team_voice_submit / _rpc_team_voice 和语音通道 CH_VOICE，
#      加 _rpc_team_voice_token_request / _rpc_team_voice_token（发只能进本队语音房间的钥匙）。
#      RPC 数量没变（仍是 58），但方法表变了 —— 与 v26、v28 同一类，两端不一致时方法对不上。
#      代价同上：**战斗服务器必须重新打包部署到 p31**，和新包一起上。要有语音还得先装好 LiveKit、
#      放好语音钥匙配置（deploy/livekit/README.md）；没放的话照常开服，只是没有语音。
#      确认依据是服务器日志里的 `voice configured (LiveKit)` 与 `server started protocol=31`。
const NETWORK_PROTOCOL_VERSION := 32

# Local phone hosting is debug-only.
const ALLOW_LOCAL_HOST_DEBUG := false

# --- 通道映射（B9）----------------------------------------------------------
# ENet 的可靠通道是**按通道各自排序**的：同一条通道上，前面那个包没送达，
# 后面的包就算已经到了也得压着不交付（队头阻塞）。此前 44 个 RPC 全部是
# `reliable` + 默认通道 —— 于是一份 62 KB 的 replay 在弱网重传时，会把排在
# 它后面的 pong 一起压住。客户端量到的是"心跳超时"，然后重连、再收一份
# replay，形成"超时 → 重连 → 重发"的放大循环。
#
# 分三路：
#   ping/pong    -> **unreliable**：走 ENet 自己的不可靠系统通道，永远不排队。
#                   丢包无所谓 —— 心跳本来就是周期性的，下一发几秒后就到；
#                   而"被大包压住"才是实际观测到的故障。
#   replay/日志  -> CH_BULK：独立可靠通道。大包内部仍然有序，但**压不到控制流**。
#   其余         -> CH_CONTROL（默认可靠通道）：房间状态、结算、交易、握手。
#
# 通道号 0 表示"用该 transfer mode 的引擎默认通道"，≥1 才是用户通道。
const CH_CONTROL := 0
const CH_BULK := 1

# **不要**给 create_server / create_client 传 max_channels。
# 实测（tools/channel_check.tscn，Godot 4.7）：不传时 ENet host 的 max_channels = 255；
# 传一个具体数字只会把上限**调低**。以后加第三条用户通道时，一个写死的小数字就是
# 一个静默丢包的陷阱 —— 越界通道上的包不会报错，只会消失。
# 这里留常量只为记录这条结论，代码里不使用。
const ENET_MAX_CHANNELS_DEFAULT := 255

# --- 多进程分片 -------------------------------------------------------------
# Godot 是单线程的，而单线程的瓶颈是**每个进程**的。所以扩容方式是开 N 个服务器
# 进程，各自监听不同端口、各管一批房间。房间之间本来就互不相干，天然可分。
#
# 路由靠**房间号自带分片号**：room_id = shard * SHARD_ID_STRIDE + 本地随机六位。
#   shard 0 -> 100000  ..  999999   （6 位）
#   shard 1 -> 1100000 .. 1999999   （7 位）
# 这样客户端拿到一个房间号就知道该连哪个进程，不需要额外查表，也不会跨进程撞号
# （撞号是多进程最先坏掉的东西：两个进程各自 randi 六位，早晚重复）。
#
# 端口约定 SERVER_PORT + shard。以后接了「分配端点」（HTTP 返回 host+port）之后，
# 这里退化成兜底默认值。
const SHARD_COUNT := 1              # 部署几个服务器进程；1 = 单进程（现状）
const SHARD_ID_STRIDE := 1000000

static func shard_of_room(room_id: int) -> int:
	return int(room_id / SHARD_ID_STRIDE)

static func port_of_shard(shard: int) -> int:
	return SERVER_PORT + maxi(0, shard)

static func port_of_room(room_id: int) -> int:
	return port_of_shard(shard_of_room(room_id))
