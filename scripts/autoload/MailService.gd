extends Node

# 系统邮件的客户端状态（docs/邮件系统设计.md）。
#
# 分工：
#   AccountManager   请求（HTTPS）
#   RealtimeService  收「有新邮件」的推送（WebSocket）
#   本文件           邮箱快照、红点、读 / 领 / 删的结果怎么落到快照上 —— 界面只看这里
#
# 为什么单独一个 autoload：红点在主菜单与邮件界面上要一致，推送随时可能到
# （同 AnnouncementService 的理由）。
#
# ## 本机什么都不存
#
# 读过 / 领过 / 删过都在账号服务器上。换手机不会重新提醒，两台手机也不会各领一份 ——
# 「领过」只能由服务端判（它先锁住那一行再发东西）。本机那份只是快照，
# 拉到新列表就整份换掉。

signal changed

# 与 backend/app/mail.py 的 PUSH_TYPE 一致（backend/tests/test_mail.py 钉着）。
# 对不上的话推送落进 RealtimeService 的「未知类型」分支：不报错，就是红点不亮。
const PUSH_TYPE := "mail"
# 回主菜单时最多多久拉一次。新邮件另有推送。
const REFRESH_MIN_INTERVAL_SEC := 60.0

var _mails: Array = []
var _loaded := false
var _fetching := false
var _last_fetch_msec := -1


func _ready() -> void:
	# 专服也会加载全部 autoload，但那里没有玩家、没有界面。
	if "--server" in OS.get_cmdline_args() or "--dedicated-server" in OS.get_cmdline_args():
		return
	RealtimeService.message_received.connect(_on_realtime_message)
	RealtimeService.connection_changed.connect(_on_connection_changed)


# --- 读 -----------------------------------------------------------------------

# 服务器排好的顺序（新的在前）。
func mails() -> Array:
	return _mails


func is_loaded() -> bool:
	return _loaded


func find(mail_id: int) -> Dictionary:
	for entry in _mails:
		if int((entry as Dictionary).get("id", 0)) == mail_id:
			return entry
	return {}


static func has_attachments(entry: Dictionary) -> bool:
	return int(entry.get("diamond", 0)) > 0 or int(entry.get("coin", 0)) > 0 \
		or not (entry.get("items", []) as Array).is_empty()


static func is_claimable(entry: Dictionary) -> bool:
	return has_attachments(entry) and not bool(entry.get("claimed", false))


# 与服务端 mail.delete 同一条：已读，并且没有没领的附件。
static func is_deletable(entry: Dictionary) -> bool:
	return bool(entry.get("read", false)) and not is_claimable(entry)


# 红点：有没读的，或者有没领的附件。
func needs_attention() -> bool:
	for entry in _mails:
		if not bool((entry as Dictionary).get("read", false)) or is_claimable(entry):
			return true
	return false


func claimable_count() -> int:
	var n := 0
	for entry in _mails:
		if is_claimable(entry):
			n += 1
	return n


func deletable_count() -> int:
	var n := 0
	for entry in _mails:
		if is_deletable(entry):
			n += 1
	return n


# --- 拉列表 -------------------------------------------------------------------

# force=false 时 REFRESH_MIN_INTERVAL_SEC 内只拉一次（回主菜单时这么调）。
func refresh(force: bool = false) -> void:
	if _fetching or not AccountManager.is_logged_in():
		return
	var now := Time.get_ticks_msec()
	if not force and _last_fetch_msec >= 0 and now - _last_fetch_msec < int(REFRESH_MIN_INTERVAL_SEC * 1000.0):
		return
	_fetching = true
	var result: Dictionary = await AccountManager.fetch_mail()
	_fetching = false
	_last_fetch_msec = Time.get_ticks_msec()
	if int(result.get("code", 0)) / 100 != 2:
		# 拉不到就保留上一份。红点宁可晚一点亮，也不要因为一次失败把邮箱清空。
		return
	apply_list((result.get("body", {}) as Dictionary).get("mails", []))


func apply_list(raw: Variant) -> void:
	var fresh: Array = []
	if raw is Array:
		for entry in raw:
			if entry is Dictionary and int((entry as Dictionary).get("id", 0)) > 0:
				fresh.append(entry)
	_mails = fresh
	_loaded = true
	changed.emit()


# 登出时由 Main 调。
func reset() -> void:
	_mails = []
	_loaded = false
	_last_fetch_msec = -1
	changed.emit()


# --- 读 / 领 / 删 -----------------------------------------------------------------

# 打开一封就算读过。**先改本机**：点开那一刻红点就该灭，不等网络。
# 服务端没记上的话，下次拉列表时它会重新是未读 —— 那是对的，不回滚也不提示。
func mark_read(mail_id: int) -> void:
	var entry := find(mail_id)
	if entry.is_empty() or bool(entry.get("read", false)):
		return
	entry["read"] = true
	changed.emit()
	await AccountManager.read_mail(mail_id)


# 领一封。返回 {"ok", "error", "diamond", "coin", "granted", "skipped", "replayed"}。
func claim(mail_id: int) -> Dictionary:
	var result: Dictionary = await AccountManager.claim_mail(mail_id)
	var outcome := _after_claim(result)
	# 服务端说「早就领过了」（另一台手机、或者上一次的回执丢了）：本机也记成已领。
	if bool(outcome.get("ok", false)) and bool(outcome.get("replayed", false)):
		_mark_claimed(mail_id)
		changed.emit()
	return outcome


func claim_all() -> Dictionary:
	return _after_claim(await AccountManager.claim_all_mail())


func _after_claim(result: Dictionary) -> Dictionary:
	var code := int(result.get("code", 0))
	if code / 100 != 2:
		# 404 = 这封已经过期 / 撤回了：拉一次，让它从界面上消失。
		if code == 404:
			refresh(true)
		return {"ok": false, "error": str(result.get("error", ""))}
	var body: Dictionary = result.get("body", {})
	for raw_id in body.get("mail_ids", []):
		_mark_claimed(int(raw_id))
	# 到手的宠物要进出战宠物的缓存（PlayerProfile 是它的唯一主人），不然备战页看不到。
	for item in body.get("granted", []):
		if item is Dictionary and str((item as Dictionary).get("kind", "")) == "pet":
			PlayerProfile.refresh_pets()
			break
	changed.emit()
	return {
		"ok": true,
		"error": "",
		"diamond": int(body.get("diamond", 0)),
		"coin": int(body.get("coin", 0)),
		"granted": body.get("granted", []),
		"skipped": body.get("skipped", []),
		"replayed": bool(body.get("replayed", false)),
	}


func _mark_claimed(mail_id: int) -> void:
	var entry := find(mail_id)
	if entry.is_empty():
		return
	entry["claimed"] = true
	entry["read"] = true


# 删一封。返回 {"ok", "error"}；error 是服务端给的原因（可能为空，界面自己兜底文案）。
func delete_mail(mail_id: int) -> Dictionary:
	var result: Dictionary = await AccountManager.delete_mail(mail_id)
	if int(result.get("code", 0)) / 100 != 2:
		return {"ok": false, "error": str(result.get("error", ""))}
	_drop([mail_id])
	return {"ok": true, "error": ""}


# 删掉所有已读且附件已领完的。返回删了几封；失败返回 -1。
func delete_read() -> int:
	var result: Dictionary = await AccountManager.delete_read_mail()
	if int(result.get("code", 0)) / 100 != 2:
		return -1
	var gone: Array = []
	for entry in _mails:
		if is_deletable(entry):
			gone.append(int((entry as Dictionary).get("id", 0)))
	_drop(gone)
	return int((result.get("body", {}) as Dictionary).get("deleted", gone.size()))


func _drop(ids: Array) -> void:
	var kept: Array = []
	for entry in _mails:
		if not ids.has(int((entry as Dictionary).get("id", 0))):
			kept.append(entry)
	_mails = kept
	changed.emit()


# --- 推送 ---------------------------------------------------------------------

func _on_realtime_message(payload: Dictionary) -> void:
	if str(payload.get("t", "")) != PUSH_TYPE:
		return
	# 推送不带内容（群发的资格、已读已领都要按人算），收到就拉一次。
	refresh(true)


func _on_connection_changed(_state: int) -> void:
	# 连上（含断线重连）之后拉一次：断线期间的推送全漏了。
	if RealtimeService.is_online():
		refresh(true)
