extends RefCounted

# 体验到期提醒（2026-11-20 用户定）：体验到期后，玩家**第一次开始任何游戏前**弹一次。
#
#   种族体验到期（出战种族少了一个）：
#       暗族体验已结束
#       你的出战种族少了一个，请重新选择
#       [去修改]    [随机出战]
#     去修改  -> 不开局，跳到备战页的种族页签（调用方处理）。
#     随机出战 -> 从能用的种族里随机补满出战名单，存到服务器，然后继续开局。
#   只有宠物 / 棋盘皮肤到期（它们自动换回默认，不影响开局）：
#       一个「知道了」，然后继续开局。
#
# 处理完记为已提醒（服务器 player_trials.notified_at），以后不再弹。
# 点外面 / 返回关掉 = 没处理：这次不开局，下次开局前还会弹。
#
# 拉不到提醒（断网、旧服务器没有这个接口）一律放行 —— 提醒不能变成开局的门槛，
# 到期的东西服务器那边本来就不会再带进对局（出战名片按「能不能用」重算）。
#
# 用法（Main 的各个开局入口）：
#   var verdict: String = await TrialExpiryGate.check(self)
#   match verdict: PROCEED -> 开局；EDIT -> 打开备战页种族页签；ABORT -> 什么都不做

const PROCEED := "proceed"
const EDIT := "edit"
const ABORT := "abort"

const Card := preload("res://ui/components/TrialCardKit.gd")
const Dialog := preload("res://ui/components/GloryConfirmDialog.gd")
const RacePick := preload("res://scripts/units/RacePick.gd")

static var _checking := false


static func check(owner: Node) -> String:
	if not AccountManager.is_logged_in():
		return PROCEED
	# 连点开局按钮：第二下直接放弃，等第一下的弹窗。
	if _checking:
		return ABORT
	_checking = true
	var verdict := await _check(owner)
	_checking = false
	return verdict


static func _check(owner: Node) -> String:
	var result: Dictionary = await AccountManager.fetch_expired_trials()
	if int(result.get("code", 0)) / 100 != 2:
		return PROCEED
	var items: Array = (result.get("body", {}) as Dictionary).get("items", [])
	if items.is_empty():
		return PROCEED
	var targets: Array = []
	var races: Array[String] = []
	var others: Array[String] = []
	for raw in items:
		if not raw is Dictionary:
			continue
		var target := str(raw.get("target", ""))
		var kind := str(raw.get("kind", ""))
		targets.append(target)
		var label := Card.target_name(kind, target)
		if kind == "race":
			races.append(label)
		else:
			others.append(label)
	if targets.is_empty():
		return PROCEED

	var sep := ", " if Card.english() else "、"
	var lines: Array[String] = []
	if not others.is_empty():
		lines.append(Card.t("%s的体验已结束，已换回默认。", "Your %s trial has ended and was switched back to the default.")
			% sep.join(others))
	if races.is_empty():
		var info_id := DialogService.info({
			"owner": owner,
			"title": Card.t("体验已结束", "Trial ended"),
			"body": "\n".join(lines),
		})
		var info_answer := await _wait(info_id)
		if info_answer == Dialog.RESULT_DISMISSED:
			return ABORT
		await AccountManager.ack_expired_trials(targets)
		return PROCEED

	lines.push_front(Card.t("你的出战种族少了一个，请重新选择。", "One of your battle races is gone. Please choose again."))
	var ask_id := DialogService.confirm({
		"owner": owner,
		"title": Card.t("%s体验已结束", "%s trial has ended") % sep.join(races),
		"body": "\n".join(lines),
		"confirm_text": Card.t("随机出战", "Random lineup"),
		"cancel_text": Card.t("去修改", "Change races"),
		"dismiss_on_backdrop": true,
	})
	var answer := await _wait(ask_id)
	if answer == Dialog.RESULT_DISMISSED:
		return ABORT
	if answer == Dialog.RESULT_CANCELLED:
		await AccountManager.ack_expired_trials(targets)
		return EDIT
	if not await _random_lineup():
		GloryToast.show_text(Card.t("出战种族没存上，请到备战页手动选择", "Could not save the lineup — choose races in Prep"))
		return EDIT
	await AccountManager.ack_expired_trials(targets)
	return PROCEED


static func _wait(request_id: String) -> String:
	while DialogService.is_open(request_id):
		var resolved: Array = await DialogService.dialog_resolved
		if str(resolved[0]) == request_id:
			return str(resolved[1])
	return Dialog.RESULT_DISMISSED


# 从现在能用的种族（永久拥有 ∪ 体验中）里随机挑满出战名单并存到服务器。
static func _random_lineup() -> bool:
	var owned: Dictionary = await AccountManager.fetch_entitlements()
	if int(owned.get("code", 0)) / 100 != 2:
		return false
	var body: Dictionary = owned.get("body", {})
	var usable := {}
	for id in body.get("items", []):
		usable[str(id)] = true
	for id in Card.trial_map(body.get("trials", {})):
		usable[str(id)] = true
	var pool: Array[String] = []
	for race in RacePick.all_races():
		if usable.has(race):
			pool.append(race)
	if pool.is_empty():
		return false
	pool.shuffle()
	var picks := pool.slice(0, mini(RacePick.PICK_COUNT, pool.size()))
	return await PlayerProfile.set_selected_races(picks)
