class_name NetworkConfig
extends RefCounted

# Client-side production target. Public server info only; no secrets belong here.
const SERVER_IP := "34.142.168.170"
const SERVER_PORT := 8080
const CONNECTION_TIMEOUT := 10.0
const USE_DEDICATED_SERVER := true
# v6: 新增备战期佣兵同步 RPC（_rpc_team_prep_mercs / _rpc_team_prep_mercs_submit）。
# 新增 RPC 会改变方法表，新旧版本混连会错乱——客户端与服务器必须一起升级。
const NETWORK_PROTOCOL_VERSION := 6

# Local phone hosting is debug-only.
const ALLOW_LOCAL_HOST_DEBUG := false
