class_name NetworkConfig
extends RefCounted

# Client-side production target. Public server info only; no secrets belong here.
const SERVER_IP := "34.142.168.170"
const SERVER_PORT := 8080
const CONNECTION_TIMEOUT := 10.0
const USE_DEDICATED_SERVER := true
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
const NETWORK_PROTOCOL_VERSION := 15

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
