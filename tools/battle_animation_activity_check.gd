extends Node

# Round 20 mobile performance gate: wrappers containing separate idle / attack /
# run FBX scenes must not keep hidden AnimationPlayers evaluating skeletons.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleVfxScript := preload("res://scenes/battle/BattleVfx.gd")
const CHECK_NAME := "battle_animation_activity"

var _h: RefCounted


class ActionModelProbe extends Node3D:
	var proxy: AnimationPlayer
	var action_nodes: Dictionary = {}
	var action_players: Dictionary = {}

	func setup() -> void:
		proxy = _make_player("ProxyPlayer")
		add_child(proxy)
		for action in ["idle", "attack", "run"]:
			var branch := Node3D.new()
			branch.name = "%s_model" % action.capitalize()
			add_child(branch)
			var player := _make_player("%sPlayer" % action.capitalize())
			branch.add_child(player)
			var mesh := MeshInstance3D.new()
			mesh.name = "%sMesh" % action.capitalize()
			mesh.mesh = BoxMesh.new()
			branch.add_child(mesh)
			action_nodes[action] = branch
			action_players[action] = player
		# Reproduce the pre-fix leak: all imported action players have previously
		# been activated and are still playing before the next action switch.
		proxy.play("loop")
		for player in action_players.values():
			(player as AnimationPlayer).play("loop")

	func play_idle() -> void:
		_activate("idle", false)

	func play_attack() -> void:
		_activate("attack", true)

	func play_run() -> void:
		_activate("run", false)

	func _activate(action: String, restart: bool) -> void:
		proxy.play("loop")
		for key in action_nodes.keys():
			(action_nodes[key] as Node3D).visible = str(key) == action
		var player := action_players[action] as AnimationPlayer
		if restart:
			player.stop()
		player.play("loop")

	func _make_player(player_name: String) -> AnimationPlayer:
		var player := AnimationPlayer.new()
		player.name = player_name
		var animation := Animation.new()
		animation.length = 1.0
		animation.loop_mode = Animation.LOOP_LINEAR
		var library := AnimationLibrary.new()
		library.add_animation("loop", animation)
		player.add_animation_library("", library)
		return player


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var renderer := BattleVfxScript.new()
	renderer.name = "AnimationActivityRenderer"
	add_child(renderer)
	var actor := Node3D.new()
	actor.name = "Actor"
	renderer.add_child(actor)
	var model := ActionModelProbe.new()
	model.name = "ActionModel"
	actor.add_child(model)
	model.setup()
	actor.set_meta("model_action_node_path", actor.get_path_to(model))
	actor.set_meta("current_model_action", "")
	await get_tree().process_frame

	_h.expect(_playing_count(model.action_players) == 3,
		"fixture_does_not_reproduce_hidden_players",
		"测试夹具启动时应有 3 个动作子模型同时播放")
	_check_action(renderer, actor, model, "idle")
	_check_action(renderer, actor, model, "attack")
	_check_action(renderer, actor, model, "run")
	_check_action(renderer, actor, model, "idle")

	actor.queue_free()
	renderer.queue_free()
	await get_tree().process_frame
	_h.finish(get_tree())


func _check_action(renderer: Node, actor: Node3D, model: ActionModelProbe, action: String) -> void:
	var ok: bool = renderer._play_model_action_method(actor, action, true)
	_h.expect(ok, "action_switch_failed_%s" % action,
		"动作切换 %s 返回 false" % action)
	_h.expect(str(actor.get_meta("current_model_action", "")) == action,
		"current_action_not_recorded_%s" % action,
		"动作切换后 current_model_action 不是 %s" % action)
	_h.expect(model.proxy.is_playing(),
		"proxy_paused_%s" % action,
		"wrapper proxy AnimationPlayer 被误停；它负责动作结束回调")
	for key in model.action_players.keys():
		var player := model.action_players[key] as AnimationPlayer
		var should_play := str(key) == action
		_h.expect(player.is_playing() == should_play,
			"wrong_player_state_%s_%s" % [action, str(key)],
			"切到 %s 后，%s player is_playing=%s，期望 %s"
				% [action, str(key), str(player.is_playing()), str(should_play)])
	_h.expect(_hidden_playing_count(model) == 0,
		"hidden_players_remain_%s" % action,
		"切到 %s 后仍有不可见动作子模型在播放" % action)


func _playing_count(players: Dictionary) -> int:
	var count := 0
	for player in players.values():
		if (player as AnimationPlayer).is_playing():
			count += 1
	return count


func _hidden_playing_count(model: ActionModelProbe) -> int:
	var count := 0
	for key in model.action_players.keys():
		var player := model.action_players[key] as AnimationPlayer
		var branch := model.action_nodes[key] as Node3D
		if player.is_playing() and not branch.visible:
			count += 1
	return count
