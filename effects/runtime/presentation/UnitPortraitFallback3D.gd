class_name UnitPortraitFallback3D
extends Node3D

const DEFAULT_HEIGHT := 0.98
const UnitVisualResolverScript := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")

var _portrait: Sprite3D
var _frame: Sprite3D
var _team_plate: Sprite3D


func configure(portrait_path: String, frame_path: String, team_color: Color, target_height: float = DEFAULT_HEIGHT) -> bool:
	var height := maxf(0.4, target_height)
	_team_plate = _make_sprite("TeamPlate")
	_team_plate.texture = _make_team_plate_texture(team_color)
	_team_plate.pixel_size = height * 0.78 / 64.0
	_team_plate.position = Vector3(0.0, height * 0.51, -0.006)
	add_child(_team_plate)

	var portrait_texture := load(portrait_path) as Texture2D if UnitVisualResolverScript.resource_exists(portrait_path) else null
	if portrait_texture != null:
		_portrait = _make_sprite("Portrait")
		_portrait.texture = portrait_texture
		_portrait.pixel_size = height * 0.70 / maxf(1.0, float(portrait_texture.get_height()))
		_portrait.position = Vector3(0.0, height * 0.56, 0.0)
		add_child(_portrait)

	var frame_texture := load(frame_path) as Texture2D if UnitVisualResolverScript.resource_exists(frame_path) else null
	if frame_texture != null:
		_frame = _make_sprite("Frame")
		_frame.texture = frame_texture
		_frame.pixel_size = height / maxf(1.0, float(frame_texture.get_height()))
		_frame.position = Vector3(0.0, height * 0.50, 0.008)
		add_child(_frame)

	return portrait_texture != null


func _make_sprite(node_name: String) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.name = node_name
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return sprite


func _make_team_plate_texture(team_color: Color) -> GradientTexture2D:
	var gradient := Gradient.new()
	var dark := team_color.darkened(0.72)
	dark.a = 0.88
	var center := team_color.darkened(0.32)
	center.a = 0.82
	gradient.colors = PackedColorArray([dark, center, dark])
	gradient.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 64
	texture.height = 64
	texture.fill_from = Vector2(0.0, 0.0)
	texture.fill_to = Vector2(1.0, 1.0)
	return texture
