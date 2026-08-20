extends RefCounted

const NetworkConfig := preload("res://scripts/multiplayer/NetworkConfig.gd")

# D1 步骤 1.5：跨切面的会话状态。
#
# 这一步不在 README 原本的五服务列表里，是量完耦合之后加进计划的。理由是数据：
# NetworkService 的 71 个成员变量里，**26 个跨 4 个以上分节**，最缠的几个是
#
#   state              12 个分节、74 次引用
#   is_host            10 个分节、40 次
#   _dedicated_server   9 个分节、39 次
#   team_active         9 个分节、30 次（另有 64 处外部引用）
#   team_local_slot     7 个分节、38 次（另有 49 处外部引用）
#
# 接下来要抽的 ReconnectService / NetworkTransport / MatchStateService **都要读
# state 和 is_host**。如果不先给它们一个共同的去处，第一刀会自己发明一种拿 state
# 的方式，第二刀又发明另一种 —— 那才是"拆到一半接不上"的确切形态。所以先立这一处。
#
# 边界不是按感觉划的，收进来的是两类：
#   1. 本进程这条会话的身份与连接（state / 角色 / token / 目标地址 / 最后错误）
#   2. 队伍视图（team_*）
#
# 为什么 team_* 也算跨切面而不是"纯客户端镜像"：实测 team_slot_states 的 29 个写入点
# **两侧都有** —— 服务端有 _team_*_authoritative、_on_peer_connected/disconnected，
# 客户端有 _rpc_room_state、_rpc_team_lobby；而且 _room_compute_and_broadcast_replays
# 是把 room.slot_states **复制进** team_slot_states，它在服务端是房间状态的一个视图。
# 硬拆成"服务端一份、客户端一份"会比现在更糟。
#
# 不搬 SessionState 枚举：它有 33 处外部引用（NetworkService.SessionState.X），
# 搬走要动的地方远超这一刀的范围。这里存 int，门面的转发属性保留原来的枚举类型签名。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。
#
# 命名与 RoomService 一致：这里用不带下划线的公开名，门面上保留**原来的名字**
# （含 _dedicated_server / _team_peer_slot 的下划线）作为转发属性。门面内部 417 处、
# 仓库其它文件 189 处，合计 606 处引用因此一处都不用改，且共享同一份引用、不会出双份状态。

# --- 会话身份与连接 -----------------------------------------------------------

# SessionState 的整数值。类型化的枚举签名留在门面上。
var state: int = 0
var is_host := false
var dedicated_server := false
var last_error := ""
# 连接目标的默认值必须和搬迁前一致：原来是 DEFAULT_HOST / DEFAULT_PORT，
# 也就是 NetworkConfig 里的值。写成空串/0 会让"没显式设过地址就连"退化成连不上，
# 而那是个很难查的失败 —— 表现是连接超时，看不出默认值被弄丢了。
var remote_address := NetworkConfig.SERVER_IP
var remote_port := NetworkConfig.SERVER_PORT
# 服务器签发的会话 token（重连凭证，非账号）
var session_token := ""
# 玩家看得到的短 Token ID
var public_token_id := ""
# 重连目标地址
var reconnect_address := ""
# 开新游戏时要放弃的旧座位 token（连上后发给服务器）
var pending_abandon_token := ""

# --- 队伍视图 -----------------------------------------------------------------

var team_active := false
var team_local_slot := -1
# 6 x "empty"/"player"/"dummy"（host 权威）
var team_slot_states: Array = []
# 6 x bool
var team_ready: Array = []
# peer_id -> slot（仅 host）
var team_peer_slot: Dictionary = {}
# true 表示在每回合备战中（区别于开局前的大厅）
var team_round_active := false
var team_room_id := 0
# 当前房主座位（服务器广播；房主掉线会顺延）
var team_leader_slot := 0


# 刻意**不提供** clear()/reset()。
#
# 门面的 reset() 原本就是逐个给这些字段赋初值，而转发属性让那些赋值原样生效 ——
# 所以 reset() 一个字都不用改。反过来若在这里也写一份重置，就有了两处必须保持同步的
# 语义，而它们已经不一样了：写第一版时我漏看了两点 —— reset() **不重置**
# public_token_id，且 _team_peer_slot 用的是原地 .clear() 而不是重新赋值
# （重新赋值会让持有旧引用的代码看不到这次清空）。
#
# 少一处需要同步的地方，就少一个会悄悄漂掉的地方。
