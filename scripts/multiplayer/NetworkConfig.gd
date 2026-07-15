class_name NetworkConfig
extends RefCounted

# Client-side production target. Public server info only; no secrets belong here.
const SERVER_IP := "34.142.168.170"
const SERVER_PORT := 8080
const CONNECTION_TIMEOUT := 10.0
const USE_DEDICATED_SERVER := true
const NETWORK_PROTOCOL_VERSION := 5

# Local phone hosting is debug-only.
const ALLOW_LOCAL_HOST_DEBUG := false
