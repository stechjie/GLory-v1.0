extends Node

# 备战棋子的宝藏套装 / 联动常驻表现门禁（11.04）。
#
# Leno 11.04 定的规则，逐条钉住：
#   1. 只挂**棋盘上的普通棋子**：备战席、佣兵都不挂（与战斗生效范围一致）；
#   2. 「一直显示不会不见」：挂上之后过几秒仍在；模型被重建（升星换模型）后仍是同一个节点、
#      跟到新模型上（不重建、不再淡入一次）；
#   3. 五个套装各自的刻口图案；防卫套 = 战斗盾纹原样（pattern 0）；
#   4. 金钱套亮度随金币变：没钱最暗但看得见，满 10000 金满亮；
#   5. 联动（11.04 返工）= 棋盘上一只平面生物：凤凰涅槃 → 一只凤凰，画在贴地画布里（棋子站在它上面）；几秒内会俯冲点燃一枚棋盘普通棋子；联动没了就散掉；经济联动不出生物；
#   6. 棋子下棋盘 / 宝藏没了 → 收掉。
# 每条「没有」都配了一条「有」的正对照，避免「整条路径从不挂」也全绿。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")
const SigilScript := preload("res://effects/vfx3d/modules/SetDefenseSigil3D.gd")
const PhoenixScript := preload("res://scenes/prep/effects/creatures/PrepPhoenix2D.gd")
const KoiScript := preload("res://scenes/prep/effects/creatures/PrepKoi2D.gd")
const SnakeScript := preload("res://scenes/prep/effects/creatures/PrepSnake2D.gd")
const BatsScript := preload("res://scenes/prep/effects/creatures/PrepBats2D.gd")
const IceChainScript := preload("res://scenes/prep/effects/creatures/PrepIceChain2D.gd")
const ScorpionScript := preload("res://scenes/prep/effects/creatures/PrepScorpion2D.gd")
const CrabScript := preload("res://scenes/prep/effects/creatures/PrepCrab2D.gd")
const ShellScript := preload("res://scenes/prep/effects/PrepDefenseShell3D.gd")
const SetBodyScript := preload("res://scenes/prep/effects/PrepSetBody3D.gd")

const CHECK_NAME := "prep_treasure_visuals"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"
const GOD_IDS := ["god_priest", "god_priestess", "god_guard"]
const BENCH_ID := "god_aurora"
const MERC_ID := "human_militia"

const SETS := {
	"defense": ["def_iron_wall", "def_life_monument", "def_formation_heal", "def_soul_counter"],
	"attack": ["atk_blood_pact", "atk_fury_roster", "atk_burst_core", "atk_wail_resonance"],
	"control": ["ctrl_shockwave", "ctrl_corrosive_needle", "ctrl_interrupt_chain", "ctrl_time_compress"],
	"money": ["money_compound", "money_generous_fate", "money_discount", "money_golden_altar"],
	"element": ["elem_flame_shatter", "elem_frost_blade", "elem_thunder_haste", "elem_toxic_spread"],
}
const SET_PATTERN := {"defense": 0, "attack": 1, "control": 2, "money": 3, "element": 4}

var _h: CheckHarness
var _defs: Dictionary = {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	await get_tree().process_frame
	# shader 编不过时节点照样建得出来、参数照样设得进去，后面的断言全绿 —— 第一版就这样空过了
	# （const PI 与内置常量重名）。编译失败时 uniform 列表是空的，拿它判。
	var uniforms: Array = (SigilScript.SIGIL_SHADER as Shader).get_shader_uniform_list().map(func(u): return str(u.get("name", "")))
	_h.expect("pattern" in uniforms and "fade" in uniforms, "sigil_shader_not_compiled",
		"set_defense_sigil.gdshader 的 uniform 列表里没有 pattern / fade（%s）—— 多半编译失败，战斗盾纹也会没" % str(uniforms))
	for sh in [preload("res://shaders/prep_set_overlay.gdshader"), preload("res://shaders/prep_set_emblem.gdshader")]:
		var names: Array = (sh as Shader).get_shader_uniform_list().map(func(u): return str(u.get("name", "")))
		_h.expect("fade" in names and "mode" in names, "set_body_shader_not_compiled",
			"%s 的 uniform 列表里没有 fade / mode —— 多半编译失败" % (sh as Shader).resource_path)
	_set_treasures([])
	_place_pieces(1)
	var prep := load(PREP_SCENE).instantiate() as PrepScript
	add_child(prep)
	await _wait(0.5)

	# 0. 没宝藏：什么都不挂
	_h.expect(_sigils(prep).is_empty() and _creatures(prep).is_empty(), "no_treasure_has_fx",
		"没有任何宝藏却挂了 %d 个脚下纹、%d 只生物" % [_sigils(prep).size(), _creatures(prep).size()])

	# 1. 防卫套：3 枚棋盘普通棋子各一个；备战席 / 佣兵没有
	_set_treasures(SETS["defense"])
	prep._refresh_all()
	await _wait(0.6)
	var sigils := _sigils(prep)
	_h.expect(sigils.size() == 3, "defense_sigil_count",
		"防卫套：棋盘 3 枚普通棋子 + 1 佣兵 + 备战席 1 枚，应挂 3 个，实际 %d" % sigils.size())
	_h.expect(_followed_models(sigils).size() == 3 and _follows_only_board_normals(prep, sigils), "sigil_on_wrong_unit",
		"脚下纹挂到了备战席或佣兵身上")
	_h.expect(_all_pattern(sigils, 0), "defense_not_battle_pattern", "防卫套不是战斗盾纹的图案（pattern 0）")
	# 11.04 返工：防卫套身上要有战斗那个六边形护罩（常驻）
	var shells := _live(_collect_list(prep, ShellScript))
	_h.expect(shells.size() == 3 and _follows_only_board_normals(prep, shells), "defense_shell_count",
		"防卫套身上护罩：应只给棋盘 3 枚普通棋子，实际 %d 个" % shells.size())

	# 2. 一直显示：3 秒后还在，且是同一批节点
	var first_ids := _ids(sigils)
	await _wait(3.0)
	_h.expect(_ids(_sigils(prep)) == first_ids, "sigil_disappeared",
		"3 秒后脚下纹变了（%d -> %d 个，或节点被换掉）" % [first_ids.size(), _sigils(prep).size()])
	_h.expect(_min_fade(_sigils(prep)) > 0.9, "sigil_faded", "常驻期间脚下纹的 fade 掉到了 %.2f" % _min_fade(_sigils(prep)))
	_h.expect(_ids(_live(_collect_list(prep, ShellScript))) == _ids(shells) and not shells.is_empty(), "shell_disappeared",
		"3 秒后身上护罩变了 / 没了")

	# 3. 模型重建（第 1 枚升成 2 星，同 uid）：仍是同一个节点，跟到新模型
	var old_model = prep._prep_board_model_nodes.get(0)
	(GameState.board_slots[0] as Dictionary)["star"] = 2
	prep._refresh_all()
	await _wait(0.4)
	var new_model = prep._prep_board_model_nodes.get(0)
	_h.expect(is_instance_valid(new_model) and new_model != old_model, "fixture_model_not_rebuilt",
		"夹具：改星级后模型没有重建，这一条测不到东西")
	_h.expect(_ids(_sigils(prep)) == first_ids, "rebuild_recreated_sigil", "模型重建后脚下纹被重建了（会再淡入一次，看着像闪）")
	_h.expect(_followed_models(_sigils(prep)).has(new_model), "rebuild_lost_follow", "模型重建后脚下纹没跟到新模型上")

	# 4. 五个套装各自的图案
	for category in ["attack", "control", "element", "money"]:
		_set_treasures(SETS[category])
		prep._refresh_all()
		await _wait(0.6)
		var s := _sigils(prep)
		_h.expect(s.size() == 3 and _all_pattern(s, int(SET_PATTERN[category])), "set_pattern_" + category,
			"%s 套：应 3 个 pattern %d，实际 %d 个" % [category, int(SET_PATTERN[category]), s.size()])
		# 11.04：身上效果 —— 3 枚棋盘普通棋子各一个；贴身光确实叠到模型网格上；攻击 / 控制有背后虚影
		var bodies := _live(_collect_list(prep, SetBodyScript)).filter(func(b): return str(b.get("category")) == category)
		_h.expect(bodies.size() == 3 and _follows_only_board_normals(prep, bodies), "set_body_count_" + category,
			"%s 套身上效果：应只给棋盘 3 枚普通棋子，实际 %d 个" % [category, bodies.size()])
		var overlaid := 0
		for b in bodies:
			overlaid += (b.get("_overlaid") as Array).size()
		# 元素套有光柱，棋子身上不上色（Leno 11.04）；其余三套要有贴身光
		if category == "element":
			_h.expect(overlaid == 0, "element_overlay_present", "元素套不该再给棋子身上上色（已有环绕光柱）")
			_h.expect(bodies.all(func(b): return b.get("_vortex") != null), "element_vortex_missing", "元素套没有环绕光柱")
		elif category == "money":
			# 金钱套：金币雨，身上不上色（Leno 11.04）
			_h.expect(overlaid == 0, "money_overlay_present", "金钱套不该再给棋子身上上色（已有金币雨）")
			_h.expect(bodies.all(func(b): return b.get("_coin_mm") != null), "money_coins_missing", "金钱套没有金币雨")
		else:
			_h.expect(overlaid > 0, "set_overlay_missing_" + category, "%s 套的贴身光没有叠到任何模型网格上" % category)
		var want_emblem: bool = category in ["attack", "control"]
		var has_emblem: bool = bodies.all(func(b): return b.get("_emblem") != null)
		_h.expect(bodies.is_empty() or has_emblem == want_emblem, "set_emblem_" + category,
			"%s 套背后虚影：应%s，实际%s" % [category, "有" if want_emblem else "无", "有" if has_emblem else "无"])

	# 5. 金钱套亮度随金币
	GameState.gold = 0
	await _wait(0.4)
	var poor := _min_strength(_sigils(prep))
	GameState.gold = 10000
	await _wait(0.4)
	var rich := _min_strength(_sigils(prep))
	_h.expect(poor > 0.2 and poor < 0.5, "money_poor_strength", "金钱套 0 金时亮度 %.2f（应在 0.2~0.5：暗但看得见）" % poor)
	_h.expect(rich > 0.95, "money_rich_strength", "金钱套 10000 金时亮度 %.2f（应满亮）" % rich)
	# 金币雨随档位变密：0 金（0 档）和 10000 金（10 档）各下 2.5 秒，比在场金币数
	var money_bodies := _live(_collect_list(prep, SetBodyScript)).filter(func(x): return str(x.get("category")) == "money")
	if not money_bodies.is_empty():
		var mb = money_bodies[0]
		GameState.gold = 0
		await _wait(2.5)
		var few := int(mb.get("_coin_mm").visible_instance_count)
		_h.expect(int(mb.call("coin_tier")) == 0, "coin_tier_poor", "0 金应是 0 档，实际 %d" % int(mb.call("coin_tier")))
		GameState.gold = 10000
		await _wait(2.5)
		var many := int(mb.get("_coin_mm").visible_instance_count)
		_h.expect(int(mb.call("coin_tier")) == 10, "coin_tier_rich", "10000 金应是 10 档，实际 %d" % int(mb.call("coin_tier")))
		_h.expect(many > few + 3, "coins_not_scaling", "金币雨没有随档位变密（0 档 %d 枚、10 档 %d 枚）" % [few, many])

	# 6. 凤凰涅槃（哀鸣共鸣 + 亡魂反击）：棋盘上一只凤凰，几秒内俯冲点燃一枚棋子
	_set_treasures(["atk_wail_resonance", "def_soul_counter"])
	prep._refresh_all()
	await _wait(0.6)
	_h.expect(_live(_sigils(prep)).is_empty(), "sigil_left_after_set_gone", "套装没了脚下纹还在")
	var birds := _creatures(prep)
	_h.expect(birds.size() == 1, "phoenix_count", "凤凰涅槃成立应有 1 只凤凰，实际 %d" % birds.size())
	if birds.size() == 1:
		var bird: Node2D = birds[0]
		# 平面贴地（Leno 11.04）：凤凰画在棋盘生物画布里，画布贴在棋盘地面的面片上 —— 棋子站在它上面
		var vp := bird.get_parent() as SubViewport
		var plane := prep._prep_creature_plane as MeshInstance3D
		var tex_ok: bool = plane != null and vp != null \
			and (plane.material_override as ShaderMaterial).get_shader_parameter("canvas") == vp.get_texture()
		_h.expect(vp != null and vp.name == "PrepBoardCreatureViewport" and tex_ok, "phoenix_not_on_board",
			"凤凰没有画在贴地画布里（或画布没贴到棋盘面片上）—— 会盖住棋子 / 不跟棋盘透视")
		_h.expect(plane != null and plane.position.y < 0.0, "phoenix_plane_not_ground",
			"凤凰面片不在地面高度（y=%s）" % (str(plane.position.y) if plane != null else "null"))
		_h.expect(not (bird.get("_flares") as Array).is_empty(), "phoenix_no_rebirth",
			"备战中途凑成凤凰涅槃，应有「浴火重生」登场火团")
		var ignited: Array = []
		bird.connect("piece_ignited", func(i: int) -> void: ignited.append(i))
		await _wait(9.0)
		_h.expect(not ignited.is_empty(), "phoenix_never_ignites", "凤凰 9 秒内一次都没俯冲点燃棋子")
		var normals: Array = [0, 1, 2]
		_h.expect(ignited.all(func(i): return normals.has(i)), "phoenix_ignites_wrong_unit",
			"凤凰点燃了佣兵或空格：%s" % str(ignited))

	# 6b. 富裕之路（复利之道 + 雷霆加速）：棋盘上一条锦鲤（凤凰散掉），同样贴地、会点燃棋子
	_set_treasures(["money_compound", "elem_thunder_haste"])
	prep._refresh_all()
	await _wait(1.8)
	var kois := _live_creatures(prep, KoiScript)
	_h.expect(kois.size() == 1 and _live_creatures(prep, PhoenixScript).is_empty(), "koi_count",
		"富裕之路应只有 1 条锦鲤（凤凰应已散掉），实际锦鲤 %d、凤凰 %d" % [kois.size(), _live_creatures(prep, PhoenixScript).size()])
	if kois.size() == 1:
		var koi: Node2D = kois[0]
		_h.expect((koi.get_parent() as SubViewport) != null and koi.get_parent().name == "PrepBoardCreatureViewport",
			"koi_not_on_board", "锦鲤没有画在贴地画布里")
		var koi_hits: Array = []
		koi.connect("piece_ignited", func(i: int) -> void: koi_hits.append(i))
		await _wait(9.0)
		_h.expect(not koi_hits.is_empty(), "koi_never_ignites", "锦鲤 9 秒内一次都没掠过棋子")

	# 6c. 剧毒爆发（爆裂核心 + 剧毒蔓延）：一条毒蛇（锦鲤散掉），贴地、会掠过棋子
	_set_treasures(["atk_burst_core", "elem_toxic_spread"])
	prep._refresh_all()
	await _wait(1.8)
	var snakes := _live_creatures(prep, SnakeScript)
	_h.expect(snakes.size() == 1 and _live_creatures(prep, KoiScript).is_empty(), "snake_count",
		"剧毒爆发应只有 1 条毒蛇（锦鲤应已散掉），实际毒蛇 %d、锦鲤 %d" % [snakes.size(), _live_creatures(prep, KoiScript).size()])
	if snakes.size() == 1:
		var snake: Node2D = snakes[0]
		_h.expect((snake.get_parent() as SubViewport) != null and snake.get_parent().name == "PrepBoardCreatureViewport",
			"snake_not_on_board", "毒蛇没有画在贴地画布里")
		var snake_hits: Array = []
		snake.connect("piece_ignited", func(i: int) -> void: snake_hits.append(i))
		await _wait(9.0)
		_h.expect(not snake_hits.is_empty(), "snake_never_ignites", "毒蛇 9 秒内一次都没掠过棋子")

	# 6d. 血之契约（炎焰碎裂 + 吸血纹章）：一群血蝠（毒蛇散掉），贴地、会掠过棋子
	_set_treasures(["elem_flame_shatter", "def_lifesteal_emblem"])
	prep._refresh_all()
	await _wait(1.8)
	var bats := _live_creatures(prep, BatsScript)
	_h.expect(bats.size() == 1 and _live_creatures(prep, SnakeScript).is_empty(), "bats_count",
		"血之契约应只有 1 群血蝠（毒蛇应已散掉），实际血蝠 %d、毒蛇 %d" % [bats.size(), _live_creatures(prep, SnakeScript).size()])
	if bats.size() == 1:
		var flock: Node2D = bats[0]
		_h.expect((flock.get_parent() as SubViewport) != null and flock.get_parent().name == "PrepBoardCreatureViewport",
			"bats_not_on_board", "血蝠没有画在贴地画布里")
		_h.expect((flock.get("_bat_poses") as Array).size() == 3, "bats_not_three", "血蝠群不是 3 只")
		var bat_hits: Array = []
		flock.connect("piece_ignited", func(i: int) -> void: bat_hits.append(i))
		await _wait(9.0)
		_h.expect(not bat_hits.is_empty(), "bats_never_ignite", "血蝠 9 秒内一次都没掠过棋子")

	# 6e. 瘫痪枷锁（打断锁链 + 冰封霜刃）：一条冰链（血蝠散掉），贴地、会掠过棋子
	_set_treasures(["ctrl_interrupt_chain", "elem_frost_blade"])
	prep._refresh_all()
	await _wait(1.8)
	var chains := _live_creatures(prep, IceChainScript)
	_h.expect(chains.size() == 1 and _live_creatures(prep, BatsScript).is_empty(), "icechain_count",
		"瘫痪枷锁应只有 1 条冰链（血蝠应已散掉），实际冰链 %d、血蝠 %d" % [chains.size(), _live_creatures(prep, BatsScript).size()])
	if chains.size() == 1:
		var chain: Node2D = chains[0]
		_h.expect((chain.get_parent() as SubViewport) != null and chain.get_parent().name == "PrepBoardCreatureViewport",
			"icechain_not_on_board", "冰链没有画在贴地画布里")
		var chain_hits: Array = []
		chain.connect("piece_ignited", func(i: int) -> void: chain_hits.append(i))
		await _wait(9.0)
		_h.expect(not chain_hits.is_empty(), "icechain_never_ignites", "冰链 9 秒内一次都没掠过棋子")

	# 6f. 铁处女（铁壁之护 + 腐蚀毒针）：一只钢铁蝎子（冰链散掉），贴地、会掠过棋子
	_set_treasures(["def_iron_wall", "ctrl_corrosive_needle"])
	prep._refresh_all()
	await _wait(1.8)
	var scorps := _live_creatures(prep, ScorpionScript)
	_h.expect(scorps.size() == 1 and _live_creatures(prep, IceChainScript).is_empty(), "scorpion_count",
		"铁处女应只有 1 只蝎子（冰链应已散掉），实际蝎子 %d、冰链 %d" % [scorps.size(), _live_creatures(prep, IceChainScript).size()])
	if scorps.size() == 1:
		var scorp: Node2D = scorps[0]
		_h.expect((scorp.get_parent() as SubViewport) != null and scorp.get_parent().name == "PrepBoardCreatureViewport",
			"scorpion_not_on_board", "蝎子没有画在贴地画布里")
		var scorp_hits: Array = []
		scorp.connect("piece_ignited", func(i: int) -> void: scorp_hits.append(i))
		await _wait(9.0)
		_h.expect(not scorp_hits.is_empty(), "scorpion_never_ignites", "蝎子 9 秒内一次都没掠过棋子")

	# 6g. 压迫反击（束缚重压 + 狂暴进攻）：一只符文巨蟹（蝎子散掉），贴地、会掠过棋子
	_set_treasures(["ctrl_binding_weight", "atk_frenzy_assault"])
	prep._refresh_all()
	await _wait(1.8)
	var crabs := _live_creatures(prep, CrabScript)
	_h.expect(crabs.size() == 1 and _live_creatures(prep, ScorpionScript).is_empty(), "crab_count",
		"压迫反击应只有 1 只巨蟹（蝎子应已散掉），实际巨蟹 %d、蝎子 %d" % [crabs.size(), _live_creatures(prep, ScorpionScript).size()])
	if crabs.size() == 1:
		var crab: Node2D = crabs[0]
		_h.expect((crab.get_parent() as SubViewport) != null and crab.get_parent().name == "PrepBoardCreatureViewport",
			"crab_not_on_board", "巨蟹没有画在贴地画布里")
		var crab_hits: Array = []
		crab.connect("piece_ignited", func(i: int) -> void: crab_hits.append(i))
		await _wait(9.0)
		_h.expect(not crab_hits.is_empty(), "crab_never_ignites", "巨蟹 9 秒内一次都没掠过棋子")

	# 7. 经济联动不出生物：诡诈命运（幻影步伐 + 慷慨命运）；原来的巨蟹散掉
	_set_treasures(["def_phantom_step", "money_generous_fate"])
	prep._refresh_all()
	await _wait(1.8)
	_h.expect(_creatures(prep).is_empty(), "creature_left_or_economy_creature",
		"凤凰涅槃没了 / 只剩经济联动，棋盘上还有 %d 只生物" % _creatures(prep).size())

	# 8. 下棋盘就收掉
	_set_treasures(SETS["defense"])
	prep._refresh_all()
	await _wait(0.6)
	GameState.board_slots[2] = null
	prep._refresh_all()
	await _wait(0.8)
	_h.expect(_live(_sigils(prep)).size() == 2, "removed_piece_kept_sigil",
		"拿下一枚棋子后应剩 2 个脚下纹，实际 %d" % _live(_sigils(prep)).size())

	# 9. 战斗盾纹默认图案不变：不调 configure 就是 pattern 0
	var battle_sigil := SigilScript.new() as MeshInstance3D
	add_child(battle_sigil)
	battle_sigil.call("setup", self_node(), 0.2, 1.0)
	var mat := battle_sigil.material_override as ShaderMaterial
	_h.expect(mat.get_shader_parameter("pattern") == null or int(mat.get_shader_parameter("pattern")) == 0,
		"battle_sigil_pattern_changed", "战斗里不传 pattern 的盾纹不再是 pattern 0")
	battle_sigil.queue_free()

	prep.queue_free()
	_set_treasures([])
	await _wait(0.1)
	_h.finish(get_tree())


func self_node() -> Node3D:
	var n := Node3D.new()
	add_child(n)
	return n


# --- 观测 ---------------------------------------------------------------------

func _collect(root: Node, script: Script, out: Array) -> void:
	for child in root.get_children():
		if child.get_script() == script and not child.is_queued_for_deletion():
			out.append(child)
		_collect(child, script, out)


func _collect_list(root: Node, script: Script) -> Array:
	var out: Array = []
	_collect(root, script, out)
	return out


func _sigils(prep: Node) -> Array:
	var out: Array = []
	_collect(prep, SigilScript, out)
	return _live(out)


func _live_creatures(prep: Node, script: Script) -> Array:
	var out: Array = []
	_collect(prep, script, out)
	return out.filter(func(n): return not bool(n.get("_leaving")))


func _creatures(prep: Node) -> Array:
	var out: Array = []
	_collect(prep, PhoenixScript, out)
	_collect(prep, KoiScript, out)
	_collect(prep, SnakeScript, out)
	_collect(prep, BatsScript, out)
	_collect(prep, IceChainScript, out)
	_collect(prep, ScorpionScript, out)
	_collect(prep, CrabScript, out)
	return out.filter(func(n): return not bool(n.get("_leaving")))


# 去掉正在淡出（已 stop）的
func _live(nodes: Array) -> Array:
	return nodes.filter(func(n): return is_instance_valid(n) and not bool(n.get("_stopping")))


func _ids(nodes: Array) -> Array:
	var out: Array = []
	for n in nodes:
		out.append(n.get_instance_id())
	out.sort()
	return out


func _followed_models(nodes: Array) -> Array:
	return nodes.map(func(n): return n.get("_follow"))


func _follows_only_board_normals(prep: PrepScript, nodes: Array) -> bool:
	var allowed: Array = []
	for i in GameState.board_slots.size():
		var cell = GameState.board_slots[i]
		if cell is Dictionary and not bool((cell as Dictionary).get("is_mercenary", false)):
			allowed.append(prep._prep_board_model_nodes.get(i))
	for f in _followed_models(nodes):
		if not allowed.has(f):
			return false
	return true


func _all_pattern(nodes: Array, pattern: int) -> bool:
	for n in nodes:
		var v = (n.material_override as ShaderMaterial).get_shader_parameter("pattern")
		if (0 if v == null else int(v)) != pattern:
			return false
	return not nodes.is_empty()


func _min_fade(nodes: Array) -> float:
	var m := 1.0
	for n in nodes:
		m = minf(m, float((n.material_override as ShaderMaterial).get_shader_parameter("fade")))
	return m


func _min_strength(nodes: Array) -> float:
	var m := 9.0
	for n in nodes:
		m = minf(m, float(n.get("_strength")))
	return m


# --- 夹具 ---------------------------------------------------------------------

# owned_treasures 是 Array[String]：只能 clear + append，set() 塞无类型 Array 会静默失败。
func _set_treasures(ids: Array) -> void:
	GameState.owned_treasures.clear()
	for id in ids:
		GameState.owned_treasures.append(str(id))


# 棋盘 3 枚普通神 + 1 枚佣兵；备战席 1 枚。
func _place_pieces(star: int) -> void:
	if _defs.is_empty():
		for cand in DataRegistry.get_table("race_units").get("units", []):
			_defs[str((cand as Dictionary).get("id", ""))] = cand
	GameState.board_slots.resize(GameConstants.CELL_COUNT)
	for i in GameConstants.CELL_COUNT:
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null
	for i in GOD_IDS.size():
		GameState.board_slots[i] = _cell(GOD_IDS[i], "g%d" % i, star, false)
	GameState.board_slots[3] = _cell(MERC_ID, "merc", star, true)
	GameState.bench_slots[0] = _cell(BENCH_ID, "bench", star, false)


func _cell(unit_id: String, uid: String, star: int, merc: bool) -> Dictionary:
	if not _defs.has(unit_id):
		_h.expect(false, "fixture_unit_missing", "数据表里找不到棋子 %s" % unit_id)
		return {}
	return {"id": unit_id, "uid": uid, "star": star, "is_mercenary": merc,
		"def": (_defs[unit_id] as Dictionary).duplicate(true)}


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
