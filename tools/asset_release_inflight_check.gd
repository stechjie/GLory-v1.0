extends Node

const FIRST := "res://assets/models/units/human_refined/human_mage/human_mage_refined.tscn"
const SECOND := "res://assets/models/units/dark_refined/dark_scythe/dark_scythe_refined.tscn"
var checked := 0
var failures := 0

func expect(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)

func drain() -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while BattleAssetService.harvest() > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	expect(BattleAssetService.pending_count() == 0, "Resource jobs drain without hanging")

func _ready() -> void:
	BattleAssetService.acquire(FIRST, "probe/old")
	expect(BattleAssetService.is_pending(FIRST), "Initial job tracked")
	BattleAssetService.release_owner("probe/old")
	expect(BattleAssetService.is_pending(FIRST), "Releasing owner must retain native job reservation")
	BattleAssetService.acquire(SECOND, "probe/new")
	expect(BattleAssetService._requested.size() == 1, "No parallel scripted model loads")
	expect(BattleAssetService._queue.has(SECOND), "New model waits for released job to drain")
	await drain()
	expect(not BattleAssetService._scenes.has(FIRST), "Unowned completed scene is not retained")
	expect(BattleAssetService.ready_count([SECOND]) == 1, "Next model loads after old job drains")
	BattleAssetService.release_owner("probe/new")
	# A new owner can adopt a job that the previous screen no longer needs.
	BattleAssetService.acquire(FIRST, "probe/old2")
	BattleAssetService.release_owner("probe/old2")
	BattleAssetService.acquire(FIRST, "probe/replacement")
	expect(BattleAssetService._requested.size() == 1 and BattleAssetService._queue.is_empty(), "Reacquire reuses same request")
	await drain()
	expect(BattleAssetService.ready_count([FIRST]) == 1, "Adopted completed scene retained")
	BattleAssetService.acquire(FIRST, "probe/shared")
	BattleAssetService.release_owner("probe/replacement")
	expect(BattleAssetService.ready_count([FIRST]) == 1, "Remaining owner protects scene")
	BattleAssetService.release_owner("probe/shared")
	expect(BattleAssetService.ready_count([FIRST]) == 0, "Final owner release frees scene")
	print("ASSET_RELEASE_INFLIGHT checked=", checked, " failures=", failures)
	get_tree().quit(1 if failures else 0)
