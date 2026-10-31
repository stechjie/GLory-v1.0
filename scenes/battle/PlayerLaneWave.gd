extends Node2D
## A local-only lane identifier; never changes simulation or replay data.
var battle
var clock := 0.0
const PERIOD := 5.0
const DURATION := 1.15

func _ready() -> void:
    z_index = 35

func _process(delta: float) -> void:
    if not is_instance_valid(battle):
        return
    if battle._battle_setup_ready and NetworkService.team_active and not battle._finished and not battle._watching_rival:
        clock += delta
    queue_redraw()

func _draw() -> void:
    if not is_instance_valid(battle) or not battle._battle_setup_ready or not NetworkService.team_active or battle._finished or battle._watching_rival:
        return
    if battle._battle_3d_camera == null or battle._battle_3d_viewport == null:
        return
    var slot: int = NetworkService.team_local_slot
    if slot < 0 or slot >= 6:
        return
    var time := fmod(clock, PERIOD)
    if time >= DURATION:
        return
    var t := time / DURATION
    var alpha := minf(1.0, t * 8.0) * minf(1.0, (1.0 - t) * 4.0)
    var lane := slot % 3
    var lo: Vector2 = battle._battle_visual_min()
    var hi: Vector2 = battle._battle_visual_max()
    var enemy_side: bool = battle._color_flip
    var center: Vector2
    if battle._battlefield_kind() == "final":
        var y := lerpf(lo.y, hi.y, (float(lane) + 0.5) / 3.0)
        var x := lerpf(lo.x, hi.x, 0.75 if enemy_side else 0.25)
        center = Vector2(x, y)
    else:
        var x := lerpf(lo.x, hi.x, (float(lane) + 0.5) / 3.0)
        var y := lerpf(lo.y, hi.y, 0.25 if enemy_side else 0.75)
        center = Vector2(x, y)
    var origin: Vector2 = battle._battle_readability_point(center)
    var size: float = clampf(battle._arena.size.y / 720.0, 0.55, 1.8)
    var tint: Color = GameConstants.team_slot_color(slot)
    _draw_sword(origin, -0.72, size, tint, alpha)
    _draw_sword(origin, 0.72, size, tint, alpha)

func _point(origin: Vector2, x: float, y: float, angle: float, size: float) -> Vector2:
    return origin + Vector2(x, y).rotated(angle) * size

func _draw_sword(origin: Vector2, angle: float, size: float, tint: Color, alpha: float) -> void:
    var a := _point(origin, 0, -55, angle, size)
    var b := _point(origin, 0, 48, angle, size)
    var glow := tint
    glow.a = 0.07 * alpha
    draw_line(a, b, glow, 24.0 * size, true)
    glow.a = 0.15 * alpha
    draw_line(a, b, glow, 12.0 * size, true)
    var blade := PackedVector2Array([
        _point(origin, 0, -55, angle, size),
        _point(origin, 7, -38, angle, size),
        _point(origin, 6, 13, angle, size),
        _point(origin, -6, 13, angle, size),
        _point(origin, -7, -38, angle, size),
    ])
    var fill := tint.lerp(Color.WHITE, 0.40)
    fill.a = 0.82 * alpha
    draw_colored_polygon(blade, fill)
    var outline := tint.lerp(Color.WHITE, 0.25)
    outline.a = alpha
    var outline_points := blade.duplicate()
    outline_points.append(blade[0])
    draw_polyline(outline_points, outline, 1.8 * size, true)
    draw_line(_point(origin, -16, 16, angle, size), _point(origin, 16, 16, angle, size), outline, 5.0 * size, true)
    draw_line(_point(origin, 0, 19, angle, size), _point(origin, 0, 43, angle, size), outline, 5.5 * size, true)
    draw_circle(_point(origin, 0, 45, angle, size), 4.0 * size, outline)
