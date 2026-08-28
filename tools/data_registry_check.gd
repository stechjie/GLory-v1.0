extends Node

# Gate for scripts/autoload/DataRegistry.gd.
#
# The property being protected is narrow and easy to lose: ensure_loaded() must be
# free to call from anywhere. It was introduced because the data was being read
# twice per process -- once by the autoload's _ready(), once by Main._ready() -- and
# the obvious "fix" of making load_all() idempotent would have broken the tools/
# checks and debug scenes that call it precisely to pick up edited JSON.
#
# So: ensure_loaded() must not touch the disk twice, load_all() must always touch
# it, and Main.gd must be on the idempotent one.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RegistryScript := preload("res://scripts/autoload/DataRegistry.gd")
const CHECK_NAME := "data_registry"

const MAIN_PATH := "res://scenes/main/Main.gd"

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	# A private instance, not the autoload: the autoload has already loaded during
	# this process's boot, so its read counter would start at 8 and prove nothing.
	var registry = RegistryScript.new()
	registry.name = "DataRegistryUnderTest"
	add_child(registry)

	_check_first_load_populates(registry)
	_check_ensure_loaded_is_idempotent(registry)
	_check_load_all_still_forces_reread(registry)
	_check_tables_are_non_empty(registry)
	_check_main_uses_ensure_loaded()

	registry.queue_free()
	_h.finish(get_tree())


# add_child() runs _ready(), which calls ensure_loaded() -- so by now one full pass
# should have happened and exactly one read per declared file.
func _check_first_load_populates(registry) -> void:
	var expected := RegistryScript.DATA_FILES.size()
	_h.expect(int(registry.state) == RegistryScript.State.READY,
		"not_ready_after_boot",
		"_ready() 之后状态是 %d，不是 READY（failed=%s）" % [int(registry.state), str(registry.failed_files)])
	_h.expect(int(registry._file_reads) == expected,
		"unexpected_read_count",
		"首次加载读了 %d 个文件，应为 %d" % [int(registry._file_reads), expected])
	_h.expect(registry.failed_files.is_empty(),
		"files_failed", "有数据文件加载失败：%s" % str(registry.failed_files))


# The reason this file exists. Three more calls must cost zero disk reads.
func _check_ensure_loaded_is_idempotent(registry) -> void:
	var before := int(registry._file_reads)
	registry.ensure_loaded()
	registry.ensure_loaded()
	registry.ensure_loaded()
	_h.expect(int(registry._file_reads) == before,
		"ensure_loaded_rereads",
		"连续三次 ensure_loaded() 又读了 %d 次盘 —— 重复加载没有真正消除"
			% [int(registry._file_reads) - before])
	_h.expect(int(registry.state) == RegistryScript.State.READY,
		"state_changed_by_noop", "幂等调用把状态改成了 %d" % int(registry.state))


# The other half of the split: tools and debug scenes rely on load_all() actually
# re-reading, so making it idempotent would silently break editing workflows.
func _check_load_all_still_forces_reread(registry) -> void:
	var before := int(registry._file_reads)
	registry.load_all()
	var expected := before + RegistryScript.DATA_FILES.size()
	_h.expect(int(registry._file_reads) == expected,
		"load_all_became_idempotent",
		"load_all() 只读了 %d 次盘，应为 %d —— tools/ 下的检查依赖它强制重读"
			% [int(registry._file_reads) - before, RegistryScript.DATA_FILES.size()])


# An empty dictionary is what a missing file also produces, so "it loaded" is not
# the same as "there is data in it".
func _check_tables_are_non_empty(registry) -> void:
	for key in RegistryScript.DATA_FILES.keys():
		var table: Variant = registry.get_table(str(key))
		var populated := false
		if typeof(table) == TYPE_DICTIONARY:
			populated = not (table as Dictionary).is_empty()
		elif typeof(table) == TYPE_ARRAY:
			populated = not (table as Array).is_empty()
		_h.expect(populated, "empty_table",
			"数据表 %s 是空的（%s）" % [str(key), str(RegistryScript.DATA_FILES[key])])


func _check_main_uses_ensure_loaded() -> void:
	var source := FileAccess.get_file_as_string(MAIN_PATH)
	if not _h.expect(not source.is_empty(), "main_unreadable", "读不到 %s" % MAIN_PATH):
		return
	_h.expect(source.contains("DataRegistry.ensure_loaded()"),
		"main_not_using_ensure_loaded", "Main.gd 没有走 DataRegistry.ensure_loaded()")
	_h.expect(not source.contains("DataRegistry.load_all()"),
		"main_forces_reload",
		"Main.gd 又调回了 DataRegistry.load_all() —— 那正是被删掉的那次重复同步加载")
