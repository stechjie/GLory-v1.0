extends Node

const H := preload("res://tools/CheckHarness.gd")
const Entry := preload("res://scenes/bootstrap/Bootstrap.gd")

func _ready() -> void:
	var h := H.new("single_login")
	var credentials_before := SaveManager.load_account_credentials().duplicate(true)
	var reconnect_before := SaveManager.load_reconnect().duplicate(true)
	AccountManager._access_token = "test-only"
	AccountManager._login_session_id = "test-generation"
	AccountManager.state = AccountManager.State.LOGGED_IN
	RealtimeService._admitted = true
	var peer := OfflineMultiplayerPeer.new()
	NetworkService.multiplayer.multiplayer_peer = peer
	RealtimeService._mark_kicked()
	h.expect(NetworkService.multiplayer.multiplayer_peer == null, "battle_disconnected", "Kick closes the actual multiplayer transport")
	h.expect(AccountManager.access_token().is_empty() and AccountManager.login_session_id().is_empty(), "credentials_blocked", "HTTP and battle-card requests cannot continue")
	h.expect(not RealtimeService._want_connection and not RealtimeService.is_processing(), "no_reconnect", "No automatic kick/reconnect loop")
	h.expect(not RealtimeService.is_admitted(), "admission_revoked", "Old admission cannot bypass the entry screen")
	h.expect(SaveManager.load_account_credentials() == credentials_before, "identity_preserved", "Anonymous account must not be deleted")
	h.expect(SaveManager.load_reconnect() == reconnect_before, "recovery_preserved", "A kick must not forfeit the account's match recovery")
	for login in ["idle", "working", "failed", "logged_in"]:
		var view := Entry.entry_view({"login": login, "admitted": true, "online": true, "kicked": true})
		h.expect(view.state == "kicked" and not view.get("pass", false), "entry_" + login, "Kick has priority over stale success flags")
	var generation := AccountManager._session_generation
	RealtimeService._mark_kicked()
	h.expect(generation == AccountManager._session_generation, "idempotent", "Message and close code cannot kick twice")
	var room := {"seat_pid": {0: "same-account"}, "slot_states": ["player", "empty"], "ready": [false, false], "peer_slot": {2: 0}}
	var before := var_to_bytes(room)
	NetworkService._assign_peer_to_room(3, room, "", {"pid": "same-account"})
	h.expect(before == var_to_bytes(room), "room_duplicate", "Second account seat rejected before any room mutation")
	h.finish(get_tree())
