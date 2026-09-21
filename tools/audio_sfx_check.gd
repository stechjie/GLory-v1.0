extends Node

# 9.17 音效接入门禁：BGM 槽位、cue 表、静音门、重触发保护、代币收支监视器。
#
# ## 这条门禁验什么、不验什么
#
# **不验好不好听、也不验真机上能不能听见。** headless 用的是 Dummy 音频驱动，
# 就算文件烧坏了这里也听不出来。音色与音量是 external，写在交接里，
# 不在这里假装验过。
#
# 它验的是五件**会静默出错**的事：
#   1. cue 表里登记了但文件不在 —— 运行时只有一声没有内容的静默，没人会发现；
#   2. BGM 常量指向的文件不存在 —— 页面进得去，只是没声音；
#   3. 静音开关关掉了音还在响 —— 玩家侧的「我明明关了」；
#   4. 代币监视器响错方向、响两次、或把「换了一本账」当成收支；
#   5. 播放器池根本没挂进树 —— `play()` 返回 true、计数 +1，而**全链无声**。
#      第 5 条是第一版门禁漏掉的（只验返回值），引擎只留 ERROR 日志不留
#      CHECK_RESULT，所以现在直接数 root 下的节点。
#
# 第 3、4 条在桌面上**分别**能看出来，但「关掉开关后还响」在真机上更容易复现；
# 第 4 条则是纯逻辑，只能靠门禁。
#
# ## 为什么这一条不能靠 ui_feedback_check 代替
#
# 那条门禁管的是「按钮反馈该不该发、发了几次」，刻意**不验发声**
# （它抬头明写「不验发声」）。本批把音效真正接上了，所以需要新的一条来验
# 「有没有东西可发」和「静音门有没有生效」。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/audio_sfx_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")

const CHECK_NAME := "audio_sfx"

# 源文件里必须一条不漏登记进来的 cue 数（zip 里 24 条音效 +
# 9.17 第二批的 3 条：聊天新信息/朋友申请、房间内更换座位、己方法阵受击 +
# 9.18 的 7 条：四星大天使/末日守卫拆出 2 条、敌方法阵受击、房间准备切换、
# 资料改名保存、设置切换、语音切换）。
# 9.19 的 3 条：四星「合成」与「战斗技能」分离，神王/母灵/黑龙各加一条
# `*_skill` 素材（合成音回滚到 9.18 前原件），故 34 → 37。
#
# 9.19 第二批（`音乐/0919/战斗、特效` 9 个素材）= 四星技能音 6 条
# （剑士 / 弓箭手 / 极光射手 / 法师 / 牧师 / 神侍·天使）+ 佣兵技能音 2 条
# （星轨猎人、泡沫术士·圣愈修女）+ 人王「战后未阵亡奖励属性」1 条，故 37 → 46。
#
# 9.20 第二批（`音乐/0920` 10 个素材）= 3 条**替换**（四星其他棋子合成 / 四星神王技能 /
# 四星大天使技能 —— 只是文件被覆盖，cue 与路径都没变，所以**不增加**计数）+
# 7 条**新增**四星技能音（偷袭者 / 大祭司 / 裁决者 / 暗影法师·恐惧魔·魅魔共用 /
# 寄生灵 / 自爆灵 / 死侍），故 46 → 53。
#
# 9.21 第三批（`音乐/0921` 7 个素材）= 7 条**新增**：
#   四星民兵技能 1 条（走 proc_skill_cue_for，见 STAR4_PROC_SKILL_CUES）+
#   佣兵技能 3 条（时空观测者 / 黄金重骑 / 黑钢统帅，走 merc_skill_cue_for）+
#   最终回合 pvp 开局音 1 条（BattleScreen._begin_final_round_intro 直接 play）+
#   开始游戏成功 / 失败 2 条（Main / Team3v3Lobby 直接 play），故 53 → 60。
# 注：`音乐/0921` 里另外两个文件（设置语音·画质切换 / 语音档位切换）与工程内
# 既有的 settings_switch / voice_switch **逐字节相同**，是覆盖而非新增，不计数。
const EXPECTED_CUE_COUNT := 60

# 播 SfxService 的生产代码扫描范围。**刻意不含 `res://tools`** ——
# 门禁自己会调 play()，算进来就等于让门禁给自己的断言当证人
# （见 _production_sfx_references）。
const SCAN_ROOTS: Array[String] = ["res://scenes", "res://scripts", "res://ui", "res://effects"]

# 这 5 条只能由 `star4_cue_for(unit_id)` 间接派发：调用方给的是棋子 id，
# cue 由 SfxService 内部的 STAR4_CUES 映射出来，所以它们的常量名
# **不会**出现在任何调用点。列在这里是明示豁免，不是把断言改松 ——
# 下面还为这一组单独钉了「派发入口必须有生产调用点」。
const INDIRECT_CUES: Array[String] = [
	"CUE_STAR4_HUMAN_KING", "CUE_STAR4_GOD", "CUE_STAR4_UNDEAD_MOTHER",
	"CUE_STAR4_DARK", "CUE_STAR4_DEFAULT",
	"CUE_STAR4_ARCHANGEL", "CUE_STAR4_DOOM",
	# 9.19：四星「战斗技能」专用素材，同样只经 star4_cue_for(unit_id, true) 间接派发。
	"CUE_STAR4_GOD_SKILL", "CUE_STAR4_UNDEAD_MOTHER_SKILL", "CUE_STAR4_DARK_SKILL",
	# 9.19 第二批「施法型」四星技能音（剑士盾击 / 法师法术 / 神侍·天使治疗）。
	# 与上面三条共用同一条 star4_cue_for(unit_id, true) 派发路径。
	"CUE_STAR4_SWORDSMAN_SKILL", "CUE_STAR4_MAGE_SKILL", "CUE_STAR4_PRIEST_SKILL",
	# 9.19 第二批「攻击触发型」四星技能音（弓箭手第 N 击额外伤害 / 牧师第 N 击治疗 /
	# 极光射手每次普攻的真伤）。它们没有 skill_ready 边沿，走
	# attack_skill_cue_for(unit_id)，由 BattleVfx._play_attack_unit_procedural
	# 在 `attack_count % every == 0` 判过之后才派发。
	"CUE_STAR4_ARCHER_SKILL", "CUE_STAR4_CLERIC_SKILL", "CUE_STAR4_AURORA_SKILL",
	# 9.19 第二批：佣兵专属技能音（星轨猎人 / 泡沫术士·圣愈修女）。
	# 佣兵升不到四星，所以走 merc_skill_cue_for(unit_id)，不叠星级门。
	"CUE_MERC_ARROW_RAIN_SKILL", "CUE_MERC_BUBBLE_HOLY_SONG_SKILL",
	# 9.20 第二批：7 条新增四星技能音。**全部**经 star4_cue_for(unit_id, true) 派发 ——
	# 包括寄生灵 / 自爆灵 / 死侍那三条非施法型：它们的触发点不同，但取值入口同一个
	# （BattleVfx 各处真事件里调 star4_cue_for(uid, true)），所以豁免名单是同一组。
	"CUE_STAR4_SCYTHE_SKILL", "CUE_STAR4_PRIESTESS_SKILL", "CUE_STAR4_ARBITER_SKILL",
	"CUE_STAR4_DARK_CASTERS_SKILL", "CUE_STAR4_PARASITE_SKILL",
	"CUE_STAR4_BOMB_SKILL", "CUE_STAR4_DEATH_SERVANT_SKILL",
	# 9.21 第三批：三条佣兵技能音，走既有的 merc_skill_cue_for(unit_id)。
	"CUE_MERC_AQUARIUS_TIME_SKILL", "CUE_MERC_TAURUS_CHARGE_SKILL",
	"CUE_MERC_CAPRICORN_STEEL_SKILL",
	# 9.21 第三批：四星民兵。技能 `attack_interrupt` 是**按概率**触发的
	# （不是「每第 N 次普攻」），所以既不归 STAR4_SKILL_CUES 也不归
	# STAR4_ATTACK_SKILL_CUES —— 它走新开的 proc_skill_cue_for(skill_id)，
	# 由 BattleVfx 在 `unit_skill_proc` 事件里按 skill_id 派发。
	"CUE_STAR4_MILITIA_SKILL",
]
# 上面这组 cue 的**派发入口**。每一个都必须在生产代码里有调用点 ——
# 少了这一条，把整张映射表删空也能全绿（那 8 个名字会被上面的循环全跳过）。
const INDIRECT_ENTRIES: Array[String] = [
	"star4_cue_for", "attack_skill_cue_for", "merc_skill_cue_for",
	# 9.21：四星民兵那条「概率触发型」技能音的派发入口。
	"proc_skill_cue_for",
]

# 六条 BGM 槽位。team_room_music 是这一批新开的：此前 3v3 组队房间
# 和主菜单共用 menu_music，zip 里给了独立的《组队房间》。
const BGM_PATHS: Array[String] = [
	"res://assets/audio/bgm/menu_music.mp3",
	"res://assets/audio/bgm/prep_music.mp3",
	"res://assets/audio/bgm/pvp_round_music.mp3",
	"res://assets/audio/bgm/fighting_music.mp3",
	"res://assets/audio/bgm/pvp_battle_music.mp3",
	"res://assets/audio/bgm/team_room_music.mp3",
	"res://assets/audio/bgm/shop_music.mp3",
]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_cue_table()
	_check_cue_files()
	_check_every_cue_has_call_site()
	_check_bgm_files()
	_check_screen_music_constants()
	SfxService.install()
	await _check_voice_pool()
	_check_install_is_idempotent()
	_check_mute_gate()
	_check_retrigger_guard()
	# 9.17 第二批：三条新行为各自的最小断言。
	_check_throttle_config()
	await _check_loop_api()
	await _check_loop_cold_start()
	_check_cue_lengths()
	await _check_currency_watcher()
	_check_source_contract()
	_check_main_installs()
	# 收尾：拆掉播放器池与流缓存，见 SfxService.shutdown 的说明。
	# 拆不干净时仍会偶发 "ObjectDB instances were leaked" —— 那是混音线程
	# 持有的 AudioStreamPlayback，GDScript 侧管不到，也不影响 CHECK_RESULT。
	SfxService.shutdown()
	_h.finish(get_tree())


# --- 播放器池 ---------------------------------------------------------------

# **这条是本门禁最早漏掉的那一条，值得写在最前面。**
#
# 第一版只验了 `play()` 的返回值和计数 —— 而 `play()` 在「播放器一个都没进树」
# 的实现上照样返回 true、计数照样 +1，于是门禁全绿，产品里一条音效都听不见。
# 引擎那 8 行 "Parent node is busy setting up children" 是唯一的线索，
# 而它们不是 CHECK_RESULT，不会有人去翻。
#
# 所以这里直接问「树里到底有没有 8 个能播的节点」。
func _check_voice_pool() -> void:
	# 播放器是延迟挂载的（install 的时机正撞在 root 装配子节点的窗口里），
	# 所以先等它落地 —— 有界等待，不然实现退化成「永远不挂」时这里会挂死。
	# 挂死比断言失败更糟：CI 里表现为超时，看不出是这条。
	var waited := 0
	while not SfxService.voices_ready() and waited < 10:
		await get_tree().process_frame
		waited += 1
	_h.expect(SfxService.voices_ready(), "voice_pool_not_in_tree",
		"等了 %d 帧，8 个播放器仍然没全部挂进场景树 —— install() 之后音效"
			% waited + "只记数不出声（add_child 失败会静默失败，见 SfxService）")
	if not SfxService.voices_ready():
		return

	# 再确认一次「树里真的有」：voices_ready() 是服务自己的判据，
	# 万一它被写错，上面那条就会跟着错。这里从 root 侧独立数一遍。
	var in_tree := 0
	for child in get_tree().root.get_children():
		var player := child as AudioStreamPlayer
		if player != null and str(player.name).begins_with("GlorySfxVoice"):
			in_tree += 1
	_h.expect(in_tree == 8, "voice_pool_root_child_count",
		"root 下只数到 %d 个 GlorySfxVoice 节点，应该是 8 个" % in_tree)


# --- cue 表 -----------------------------------------------------------------

func _check_cue_table() -> void:
	_h.expect(SfxService.cue_ids().size() == EXPECTED_CUE_COUNT,
		"cue_count_changed",
		"cue 表里有 %d 条，zip 给了 %d 条音效 —— 少登记或多登记了"
			% [SfxService.cue_ids().size(), EXPECTED_CUE_COUNT])
	# 路径必须是 res:// 且落在 assets/audio/sfx 下。写错前缀在导出后才会暴露
	# （编辑器里从磁盘读得到，APK 里没有）。
	for cue in SfxService.cue_ids():
		var path := SfxService.cue_path(str(cue))
		_h.expect(path.begins_with("res://assets/audio/sfx/"),
			"cue_path_outside_sfx_dir",
			"cue %s 的路径不在 res://assets/audio/sfx/ 下：%s" % [str(cue), path])


func _check_cue_files() -> void:
	for cue in SfxService.cue_ids():
		var path := SfxService.cue_path(str(cue))
		_h.expect(FileAccess.file_exists(path), "cue_file_missing",
			"cue %s 指向的文件不存在：%s" % [str(cue), path])


# --- 每条 cue 都得有人调 -------------------------------------------------------

# **这条是本轮补上的，它本来能抓到 shop_buy 漏接。**
#
# 「文件在」+「表里有」两件事都成立，只说明这条音效**能被**播；
# 没有任何生产调用点的话它**永远不会**响，而且没有任何迹象 ——
# 表是对的、文件是对的、门禁全绿，玩家那边就是少一声。
# 9.17 第一版就是这样：`CUE_SHOP_BUY` 只在门禁自己的重触发用例里出现过，
# 买棋子的那一声从头到尾没接上，是人工 grep 调用点时发现的。
func _check_every_cue_has_call_site() -> void:
	var corpus := _production_sfx_references()
	var missing: Array[String] = []
	for name in _cue_constant_names():
		if INDIRECT_CUES.has(name):
			continue
		# 要求带 `SfxService.` 前缀：这样 `SfxService.gd` 里那些常量**定义**
		# （`const CUE_SHOP_BUY := "shop_buy"`）不会被自己满足 ——
		# 定义处永远存在，拿它当调用点是本仓栽过多次的
		# 「整文件 contains 被自己满足」。
		if not corpus.contains("SfxService." + name):
			missing.append(name)
	_h.expect(missing.is_empty(), "cue_without_call_site",
		"这些 cue 在表里有、文件也在，但生产代码（非 tools/）里没有任何调用点，"
			+ "永远不会响：%s" % ", ".join(missing))

	# 间接那一组的兜底。少了这一条，把映射表整个删空也能全绿 ——
	# 因为那时上面循环会把那些名字全跳过。9.19 第二批之后有三个派发入口
	# （star4_cue_for / attack_skill_cue_for / merc_skill_cue_for），逐个钉。
	#
	# ★ 匹配串带尾部 `(`：这里要求的是**真调用**，不是「出现过这个名字」。
	# 变异测试实测过这个差别 —— 把调用改名成 `attack_skill_cue_for_MUTATED`
	# 时，不带 `(` 的 `contains()` 会因为这个**前缀**仍然命中，变异照旧全绿。
	for entry in INDIRECT_ENTRIES:
		_h.expect(corpus.contains("SfxService." + entry + "("), "indirect_cue_entry_unused",
			"%s 这一组 cue 只能靠 SfxService.%s() 派发，但生产代码里没有任何调用点"
				% [", ".join(INDIRECT_CUES), entry])


# 取 SfxService 里所有 `CUE_*` 常量名。
#
# **不能写 `SfxService.get_script_constant_map()`。** 那是 `Script` 上的
# **非静态**方法，对 preload 来的 GDScript 直接调是**解析期**报错
# （"Cannot call non-static function ... Make an instance instead"）。
#
# 而这条检查的失败形态特别难查，值得记一笔：解析失败 → 本脚本的 `_ready()`
# 整个不执行 → `_h.finish()` 永远不调用 → **进程不报错也不退出，静默挂死**。
# 实测挂了 5 分钟以上只能手动 taskkill，日志里只有一行 SCRIPT ERROR，
# 而批量跑门禁时它表现为「卡住」而不是「红了」。
# 先赋值给 `GDScript` 类型的变量，就是让分析器按 `GDScript` 这个类去静态解析
# 这个方法（而不是绑到具体脚本上）。
func _cue_constant_names() -> Array[String]:
	var script: GDScript = SfxService
	var names: Array[String] = []
	for key in script.get_script_constant_map().keys():
		var name := str(key)
		if name.begins_with("CUE_"):
			names.append(name)
	names.sort()
	return names


# 生产代码（**不含 tools/**）里所有提到 `SfxService.` 的文件内容，已去注释。
#
# 去掉 tools/ 是关键：门禁自己会调 `SfxService.play(...)` 来验静音门和重触发，
# 把这些算作「有调用点」等于让门禁给自己的断言当证人。
func _production_sfx_references() -> String:
	var out: Array[String] = []
	for root in SCAN_ROOTS:
		_collect_sfx_refs(root, out)
	return "\n".join(out)


# 递归收集。**用 get_directories_at / get_files_at，不要用
# list_dir_begin + get_next 那套游标 API。**
#
# 第一版写的是游标版，结果这条门禁**挂死**（跑 5 分钟不返回，最后是手动
# taskkill 掉的）：游标版在嵌套递归时会互相踩 —— 外层还在遍历，里层又开了一个
# DirAccess，`get_next()` 拿到的就未必是本目录的条目了，于是要么死循环、
# 要么漏文件。`get_directories_at` / `get_files_at` 是「一次拿全」的静态形式，
# 没有跨层共享的游标，递归才安全。
#
# 速度上也没问题：真正会进 `_code_only` 状态机的只有提到 `SfxService.` 的那
# 16 个文件（约 656 KB），其余 260 多个文件只做一次 `contains()` 就被丢掉。
func _collect_sfx_refs(dir_path: String, out: Array[String]) -> void:
	for sub in DirAccess.get_directories_at(dir_path):
		_collect_sfx_refs(dir_path.path_join(sub), out)
	for file_name in DirAccess.get_files_at(dir_path):
		if not str(file_name).ends_with(".gd"):
			continue
		var source := FileAccess.get_file_as_string(dir_path.path_join(str(file_name)))
		if source.contains("SfxService."):
			out.append(_code_only(source))


# --- BGM --------------------------------------------------------------------

func _check_bgm_files() -> void:
	for path in BGM_PATHS:
		if not _h.expect(FileAccess.file_exists(path), "bgm_file_missing",
				"BGM 文件不存在：%s" % path):
			continue
		var stream := load(path) as AudioStream
		_h.expect(stream != null, "bgm_not_loadable",
			"BGM 读不出来（导入产物缺失？跑一次 --import）：%s" % path)


# 四个页面各自的 BGM 常量必须指向真实存在的文件。
#
# 这一条挡的是「改了路径常量但文件没到位」——那种情况下页面进得去、
# 只是整局没有背景音乐，而日志里只有一句 push_warning，极易被忽略。
func _check_screen_music_constants() -> void:
	var screens := {
		"res://scenes/menu/MainMenu.gd": ["MENU_MUSIC_PATH"],
		"res://scenes/menu/Team3v3Lobby.gd": ["TEAM_ROOM_MUSIC_PATH"],
		"res://scenes/menu/ShopScreen.gd": ["SHOP_MUSIC_PATH"],
		"res://scenes/prep/PrepScreen.gd": ["PREP_MUSIC_PATH", "PREP_PVP_MUSIC_PATH"],
		"res://scenes/battle/BattleUI.gd": ["BATTLE_MUSIC_PATH", "PVP_BATTLE_MUSIC_PATH"],
	}
	for path in screens.keys():
		var script := load(str(path))
		_h.expect(script != null, "screen_script_missing", "读不到 %s" % str(path))
		if script == null:
			continue
		for const_name in screens[path]:
			# GDScript 常量走 get()，读不到会返回 null 而不是报错 —— 正好用来判缺。
			var value: Variant = script.get(str(const_name))
			_h.expect(value is String and not str(value).is_empty(),
				"music_constant_missing",
				"%s 里读不到常量 %s" % [str(path), str(const_name)])
			if value is String and not str(value).is_empty():
				_h.expect(FileAccess.file_exists(str(value)), "music_constant_file_missing",
					"%s 的 %s 指向不存在的文件：%s" % [str(path), str(const_name), str(value)])


# --- 安装 / 静音门 -----------------------------------------------------------

func _check_install_is_idempotent() -> void:
	# 连装两次不该多接一条 process_frame（多接一条就是每帧跑两遍代币比对，
	# 一笔收支响两声）。
	var tree := get_tree()
	var before := 0
	for conn in tree.process_frame.get_connections():
		if _is_currency_poll(conn):
			before += 1
	_h.expect(before == 1, "currency_poll_connection_count",
		"process_frame 上挂了 %d 条代币比对，应该是 1 条" % before)
	SfxService.install()
	var after := 0
	for conn in tree.process_frame.get_connections():
		if _is_currency_poll(conn):
			after += 1
	_h.expect(after == 1, "install_not_idempotent",
		"再 install() 一次之后 process_frame 上变成了 %d 条代币比对" % after)


func _is_currency_poll(conn: Dictionary) -> bool:
	var cb: Callable = conn.get("callable", Callable())
	return str(cb.get_method()) == "_poll_currency"


func _check_mute_gate() -> void:
	# **前置条件显式建，顺序也换过。**
	#
	# `ui_sound` 是落盘持久化的（PlayerProfile.save_profile），**上一跑的收尾状态
	# 就是这一跑的初值**。9.17 实测：磁盘里留着 `ui_sound_enabled=false`，
	# 于是「关掉开关不发声」那两条**空过**（恒不发声的实现也能绿），
	# 而「开着要发声」那条红。
	#
	# 所以这里做两件事：
	#   1. 先把现场摆成「开关开 + Master 没静音」，再断言；
	#   2. 把「开着要发声」放到最前面 —— 它才是这条门禁的主断言，
	#      「关掉不发声」是它的对照组。反过来的话，环境一偏就只剩对照组了。
	#
	# --- 9.21 修正：这条门禁会把整个文件毒死 ---------------------------------
	#
	# 上面那个「还原现场」原来写的是「还原成 before」——**这是错的**。
	#
	# `before` 就是磁盘上的旧值；如果它是 false（上一次跑完留下的，
	# 或玩家/手工改过），那么本函数收尾时把 false 又写回磁盘，
	# 而它下面还有 6 个会真发声的断言（重触发保护、10 秒节流、
	# 循环音冷启动、代币收支）。它们全部被静音门挡掉 → 计数恒为 0
	# → 一次红 12 条，且**下一跑依然红**：闸门自己把自己锁死了。
	#
	# 9.21 实测就是踩在这上面：日志里 12 条全是「记了 0 次播放 / 没进树 /
	# 返回 false」，逐条读像是播放器池坏了，实际只是一个落盘开关。
	# 对照实验：把磁盘上的 ui_sound_enabled 改成 true 再跑，同一条门禁
	# 立刻 PASS 192 failures=0 —— 代码一行没动。
	#
	# 所以：**(a) 收尾一律把开关摆回「开」**，而不是摆回「读到的值」；
	# **(b) 收尾不再写盘**（见下面 restore_disk_state）。
	# 门禁不该给下一跑留状态 —— 那和「测试要能重复跑」是矛盾的。
	#
	# 反过来说：「门禁不改写玩家偏好」这个原意是对的，但正确做法是
	# **把磁盘内容原样备份、跑完原样贴回**，而不是「把内存值改成磁盘上
	# 那个值、再让它落盘」。后者看着对称，实际是把「读到什么」当成
	# 「该是什么」，一旦读到的是污染值就永远出不来。
	# 注意这里**故意不读 sound_before**。原来读它只有两个用途：断言前摆好
	# 前置条件、收尾还原。前者现在硬写成 true（前置条件必须可控），
	# 后者改成「磁盘整块还原」。留着不用的局部变量只会让下一个读的人
	# 以为它还参与裁决。
	var master := AudioServer.get_bus_index("Master")
	var mute_before: bool = AudioServer.is_bus_mute(master) if master >= 0 else false
	# 记下磁盘原文，收尾时整块贴回（不经过 PlayerProfile，避免它再落一次盘）。
	var disk_state := _snapshot_profile_file()
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	if master >= 0:
		AudioServer.set_bus_mute(master, false)
	_h.expect(Presentation.ui_sound_allowed(), "ui_sound_precondition_failed",
		"开关开着、Master 总线没静音，ui_sound_allowed() 却是 false —— 下面几条断言无从谈起")

	# 开关打开时同一条 cue 必须真的发出去 —— 这条是主断言。
	# 少了它，「关掉就不发声」在下述两种坏实现上都能绿：永远不发声的、
	# 以及播放器根本没挂进树的（见 _check_voice_pool）。
	SfxService.reset_counters_for_check()
	_h.expect(SfxService.play(SfxService.CUE_UI_POPUP), "unmuted_play_returned_false",
		"界面音效开关开着，play() 却返回 false —— 资源没导入？播放器没进树？")
	_h.expect(SfxService.play_count(SfxService.CUE_UI_POPUP) == 1, "play_not_counted",
		"播了一条，计数是 %d" % SfxService.play_count(SfxService.CUE_UI_POPUP))

	# 对照组：关掉开关，同一个 cue 一声都不该出，也不该记账。
	PlayerProfile.set_presentation_toggle("ui_sound", false)
	SfxService.reset_counters_for_check()
	_h.expect(not SfxService.play(SfxService.CUE_UI_POPUP), "muted_play_returned_true",
		"界面音效开关已关，play() 仍然返回 true")
	_h.expect(SfxService.total_play_count() == 0, "muted_play_still_counted",
		"界面音效开关已关，却记了 %d 次播放" % SfxService.total_play_count())

	# 收尾：**必须摆回「开」**，不是摆回 before。
	#
	# 本函数下面的 6 条断言都要真发声（重触发保护、10 秒节流、循环音冷启动、
	# 代币收支）。留 false 就是让它们全红 —— 这正是 9.21 那次 12 红的成因。
	# 摆回 true 不丢信息：玩家偏好由下面的磁盘还原负责，内存态只要「不挡门禁」。
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	if master >= 0:
		AudioServer.set_bus_mute(master, mute_before)
	# 磁盘整块还原（不落盘、只贴回原字节）。还原失败不静默 —— 那会让
	# 「下一跑读到什么」变成不确定，正是这条门禁最怕的事。
	#
	# **还原必须是本函数的最后一步。** 之后再调任何会 `save_profile()` 的
	# setter（包括再写一次 ui_sound）都会把磁盘覆盖回去，还原就白做了。
	# 内存态与磁盘的差异到此为止：内存是 true（不挡下面的断言），
	# 磁盘是原样（不污染下一跑）。
	_h.expect(_restore_profile_file(disk_state), "profile_restore_failed",
		"收尾没能把 profile.json 还原成跑之前的字节 —— 下一跑的前置条件不再可控")


# profile.json 的字节快照。取不到（文件不存在 —— 首次跑）时返回空字典，
# 那种情况下收尾**不删文件**（删了反而丢玩家的其他字段）。
func _snapshot_profile_file() -> Dictionary:
	var path := _profile_path()
	if path.is_empty():
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return {"path": path, "bytes": bytes}


func _restore_profile_file(snap: Dictionary) -> bool:
	if snap.is_empty():
		return true
	var path := str(snap.get("path", ""))
	if path.is_empty():
		return true
	var bytes: PackedByteArray = snap.get("bytes", PackedByteArray())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	return true


# `user://profile.json` 的真实磁盘路径。**不能用 `ProjectSettings.globalize_path`
# 之外的路子凑** —— 拼 `OS.get_user_data_dir()` 也行，但 globalize_path 是
# Godot 自己认的那个，少一层猜测。
#
# 常量名照 PlayerProfile：它叫 `PROFILE_PATH` 且**已经是 `user://` 全路径**，
# 所以这里不再拼前缀。
func _profile_path() -> String:
	return ProjectSettings.globalize_path(str(PlayerProfile.PROFILE_PATH))


func _check_retrigger_guard() -> void:
	# 连点：5 次紧挨着的调用不该变成 5 声。
	# 断言写成 < 5 而不是 == 1 —— 循环里万一跨过一个毫秒边界就会是 2，
	# 那种偶发红比不测更糟。这里要证明的是「保护确实生效」。
	SfxService.reset_counters_for_check()
	for _i in 5:
		SfxService.play(SfxService.CUE_SHOP_BUY)
	var count := SfxService.play_count(SfxService.CUE_SHOP_BUY)
	_h.expect(count >= 1 and count < 5, "retrigger_guard_ineffective",
		"同一 cue 连发 5 次记了 %d 次播放（40 ms 保护没生效）" % count)


# --- 9.17 第二批：10 秒节流（聊天新信息 / 朋友申请）--------------------------

# 反馈原文：「聊天新信息、朋友申请音效 10 秒内只触发一次，触发 10 秒后，
# 有新信息、新申请才会再次触发。」
#
# 这条验两件事，缺一不可：
#   1. **窗口真的是 10 秒**（不是默认的 40 ms）—— 只验「连发 3 次只响 1 次」
#      的话，40 ms 的保护也能让断言通过，而那不满足需求；
#   2. 连发确实只响一声。
func _check_throttle_config() -> void:
	var window := int(SfxService.THROTTLE_MSEC_BY_CUE.get(SfxService.CUE_CHAT_ALERT, 0))
	_h.expect(window == 10_000, "chat_alert_throttle_window",
		"chat_alert 的节流窗口是 %d ms，需求是 10000 ms —— 40 ms 的重触发保护"
			% window + "只能挡住同一帧，挡不住「10 秒内一串消息」")

	SfxService.reset_counters_for_check()
	for _i in 3:
		SfxService.play(SfxService.CUE_CHAT_ALERT)
	var count := SfxService.play_count(SfxService.CUE_CHAT_ALERT)
	_h.expect(count == 1, "chat_alert_throttle_ineffective",
		"连发 3 次 chat_alert 记了 %d 次播放（10 秒窗口内应恒为 1）" % count)


# --- 9.17 第二批：循环音（己方法阵受击）--------------------------------------

# 循环音**不能**复用 play() 那条路：`_stream_for()` 会显式关掉 loop。
# 所以这里同时钉住「循环走的是专用播放器」和「专用播放器真的在树里」——
# 后者是 SfxService 自己踩过的坑（延迟挂载那一帧 play() 静默失败）。
func _check_loop_api() -> void:
	_h.expect(SfxService.looping_cue().is_empty(), "loop_should_start_idle",
		"开局就有循环音在响：%s" % SfxService.looping_cue())

	var started := SfxService.start_loop(SfxService.CUE_FORMATION_HIT)
	_h.expect(started, "loop_start_returned_false",
		"start_loop(formation_hit) 返回 false —— 静音开关关着？资源没导入？")
	_h.expect(SfxService.looping_cue() == SfxService.CUE_FORMATION_HIT,
		"loop_state_not_recorded",
		"start_loop 之后 looping_cue() 是 %s" % SfxService.looping_cue())

	# 等一帧：循环播放器也是延迟挂载的，这一刻才可能进树。
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(SfxService.loop_player_ready(), "loop_player_not_in_tree",
		"循环播放器没进树 —— play() 会打印 'Playback can only happen when a node "
			+ "is inside the scene tree' 并静默失败，调用方以为在响、其实没有")

	# root 下必须真的有且只有 1 个循环播放器节点。
	var loop_nodes := 0
	for child in get_tree().root.get_children():
		if str(child.name) == str(SfxService.LOOP_PLAYER_NAME):
			loop_nodes += 1
	_h.expect(loop_nodes == 1, "loop_player_root_child_count",
		"root 下有 %d 个 %s 节点，应该是 1 个" % [loop_nodes, str(SfxService.LOOP_PLAYER_NAME)])

	# 循环播放器**不能**落进 voices 的命名前缀里：_check_voice_pool 会数
	# 以 GlorySfxVoice 开头的节点并要求正好 8 个。
	_h.expect(not str(SfxService.LOOP_PLAYER_NAME).begins_with(str(SfxService.VOICE_PREFIX)),
		"loop_player_name_collides_with_voice_pool",
		"%s 以 %s 开头，会被 _check_voice_pool 数成第 9 个 voice"
			% [str(SfxService.LOOP_PLAYER_NAME), str(SfxService.VOICE_PREFIX)])

	SfxService.stop_loop()
	_h.expect(SfxService.looping_cue().is_empty(), "loop_not_stopped",
		"stop_loop() 之后 looping_cue() 仍然是 %s" % SfxService.looping_cue())


# 冷启动窗口：**循环播放器还没进树的那一帧里 start_loop()，声音必须照样发出来。**
#
# 上面那条只验了「返回值 + 两帧后播放器在树里」，而这三点在一个**不发声**的实现上
# 可以同时成立：`start_loop()` 返回 true、`looping_cue()` 记下 cue、
# 两帧后 `loop_player_ready()` 也是 true —— 因为播放器在那一帧末尾就挂上去了，
# 只是**当场的 play() 已经打空了**（引擎: "Playback can only happen when a node
# is inside the scene tree"，静默失败）。9.17 第二批就是这一版：每局第一次结算的
# 己方法阵受击音不响，第二场起才正常。
#
# 所以这里把服务**打回冷启动**（`shutdown()` 会把循环播放器一起 free 掉，
# 于是下一次 `start_loop()` 必然重新走「新建 + 延迟挂载」那条路），
# 再拿 `loop_start_count()` 问「到底真的起播没有」——而不是问「请求被接受没有」。
func _check_loop_cold_start() -> void:
	SfxService.stop_loop()
	SfxService.shutdown()
	SfxService.install()
	await _await_voices(10)

	SfxService.reset_counters_for_check()
	var started := SfxService.start_loop(SfxService.CUE_FORMATION_HIT)
	_h.expect(started, "cold_loop_start_returned_false",
		"冷启动后 start_loop(formation_hit) 返回 false —— 静音开关关着？资源没导入？")

	# 一帧给 call_deferred 的挂载与 ready 信号，一帧兜底。
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(SfxService.loop_start_count() > 0, "cold_loop_never_started",
		"冷启动后 start_loop() 返回 %s、looping_cue() 也记下了，但两帧内 "
			% str(started)
			+ "loop_start_count() 仍是 0 —— 这一声根本没发出去。冷启动的第一次 "
			+ "start_loop() 必然落在「播放器已建好、还没进树」的那一帧上，"
			+ "当场的 play() 只会打印一行 ERROR 然后静默失败")

	_h.expect(SfxService.looping_cue() == SfxService.CUE_FORMATION_HIT,
		"cold_loop_state_not_recorded",
		"冷启动的 start_loop 之后 looping_cue() 是 %s" % SfxService.looping_cue())

	# 补起播的那条回调必须先看「这一声是不是已经被取消了」。
	# 结算序列（水晶演出）中途退出战斗会在同一帧内 stop_loop()，而播放器挂 root、
	# 场景没了照样响 —— 没人收口的循环音就是这么来的。
	SfxService.stop_loop()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(SfxService.loop_start_count() == 1, "loop_restarted_after_stop",
		"stop_loop() 之后循环音的起播次数是 %d 次（应为 1 次：冷启动那一次）。"
			% SfxService.loop_start_count()
			+ "多出来的一次说明补起播的回调没有检查「请求已经取消」，"
			+ "会留下收不掉的循环音")

	# 收尾：把播放器池与流缓存恢复到后续检查能用的状态（本条把服务拆过一次）。
	SfxService.shutdown()
	SfxService.install()
	await _await_voices(10)


# 有界等待播放器池落地。挂死比断言失败更糟（CI 里只表现为超时，看不出是哪条）。
func _await_voices(frames: int) -> void:
	var waited := 0
	while not SfxService.voices_ready() and waited < frames:
		await get_tree().process_frame
		waited += 1


# --- 9.17 第二批：cue 时长 ---------------------------------------------------

# 「等胜负音播完再切界面」和「boss 登场音播完再起 BGM」两处都读 cue_length()。
# 读不到时它返回 0.0，那两处的等待会**静默塌回默认值** —— 也就是说功能看着
# 还在，实际已经不等了。这个塌陷没有任何其它迹象，只能在这里钉住。
func _check_cue_lengths() -> void:
	for pair in [
		[SfxService.CUE_BATTLE_VICTORY, "battle_victory"],
		[SfxService.CUE_BATTLE_DEFEAT, "battle_defeat"],
		[SfxService.CUE_BOSS_APPEAR, "boss_appear"],
	]:
		var cue := str(pair[0])
		var length := SfxService.cue_length(cue)
		_h.expect(length > 0.0, "cue_length_unreadable",
			"cue_length(%s) 是 %.3f 秒 —— 「等它播完」的逻辑会塌回默认停留时长，"
				% [str(pair[1]), length] + "而这不会有任何其它症状")


# --- 代币收支监视器 ----------------------------------------------------------

func _check_currency_watcher() -> void:
	var saved := GameState.gold
	# 基线对齐之后改一次余额：应该播，而且只播一声，方向要对。
	SfxService.resync_currency_baseline()
	SfxService.reset_counters_for_check()
	GameState.gold = saved + 250
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(SfxService.play_count(SfxService.CUE_UI_CURRENCY_GAIN) == 1,
		"currency_gain_not_played_once",
		"金币 +250 之后入账音发了 %d 次（应该是 1 次）"
			% SfxService.play_count(SfxService.CUE_UI_CURRENCY_GAIN))
	_h.expect(SfxService.play_count(SfxService.CUE_UI_CURRENCY_SPEND) == 0,
		"currency_gain_played_spend",
		"金币增加却播了扣除音")

	SfxService.reset_counters_for_check()
	GameState.gold = saved
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(SfxService.play_count(SfxService.CUE_UI_CURRENCY_SPEND) == 1,
		"currency_spend_not_played_once",
		"金币减少之后扣除音发了 %d 次（应该是 1 次）"
			% SfxService.play_count(SfxService.CUE_UI_CURRENCY_SPEND))

	# 「换了一本账」不是一笔收支：赋值之后紧接对齐基线（真实调用顺序见
	# GameState.reset_run / SaveManager.load_run），一个字都不该响。
	SfxService.reset_counters_for_check()
	GameState.gold = saved + 777
	SfxService.resync_currency_baseline()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(SfxService.total_play_count() == 0, "baseline_resync_played",
		"整块替换账本（重开一局 / 读档）响了 %d 声" % SfxService.total_play_count())

	# 收尾：把余额还原并且不要再制造一声。
	GameState.gold = saved
	SfxService.resync_currency_baseline()
	SfxService.reset_counters_for_check()


# --- 源码合同 ---------------------------------------------------------------

func _check_source_contract() -> void:
	var src := _code_only(FileAccess.get_file_as_string(
		"res://ui/services/SfxService.gd"))
	# 震动只能由 UiFeedback 调（ui_feedback_check 的 vibrate_called_outside_feedback
	# 会在别处红）——这里做一条就近的说明性断言，省得到那边才发现。
	_h.expect(not src.contains("Input.vibrate_handheld("),
		"vibrate_added_to_sfx_service",
		"SfxService 里出现了 Input.vibrate_handheld() —— 震动必须走 UiFeedback")
	# 总线只能是 SFX。写 "Music" 会让这条服务绕开 ui_feedback_check 钉的那条线。
	_h.expect(not src.contains("\"Music\""), "music_bus_used_by_sfx_service",
		"SfxService 里引用了 Music 总线 —— 本批不新增 Music 总线")


func _check_main_installs() -> void:
	var body := ""
	for candidate in _function_bodies(
			FileAccess.get_file_as_string("res://scenes/main/Main.gd"), "func _ready("):
		body = candidate
		break
	_h.expect(body.contains("SfxService.install()"), "main_does_not_install_sfx",
		"Main._ready() 没有调 SfxService.install() —— 代币监视器整条链是断的")


# --- 工具 -------------------------------------------------------------------

# 去掉行注释。字符串里的 # 不能算 —— 状态机跟着引号走，别用正则。
# 与 ui_feedback_check._code_only 同款：整文件 contains 会被自己写的注释满足，
# 这一轮已经栽过。本文件开头那段说明里就写着 Input.vibrate_handheld，
# 不去注释的话上面那条断言会被自己的文档判红。
func _code_only(source: String) -> String:
	var out: Array[String] = []
	for raw in source.split("\n"):
		var line := str(raw)
		var quote := ""
		var cut := -1
		for i in line.length():
			var ch := line[i]
			if not quote.is_empty():
				if ch == quote and (i == 0 or line[i - 1] != "\\"):
					quote = ""
				continue
			if ch == "\"" or ch == "'":
				quote = ch
				continue
			if ch == "#":
				cut = i
				break
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)


# 一个文件里可能有多个同名回调（不同内部类），全部收上来。
func _function_bodies(source: String, signature: String) -> Array[String]:
	var out: Array[String] = []
	if source.is_empty():
		return out
	var current: Array[String] = []
	var inside := false
	for raw in source.split("\n"):
		var line := str(raw)
		if not inside:
			if line.begins_with(signature):
				inside = true
				current = [line]
			continue
		if not line.is_empty() and not line.begins_with("\t") and not line.begins_with(" "):
			out.append("\n".join(current))
			inside = false
			continue
		current.append(line)
	if inside:
		out.append("\n".join(current))
	return out
