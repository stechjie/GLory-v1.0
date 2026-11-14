extends Node2D
## A local-only lane identifier; never changes simulation or replay data.
##
## 11.14 第 21 回合（用户：最后一回合很容易看不到自己在哪里）：
##   * 战场打横了，双刀整个转 90° 横过来；
##   * 开场 Ready / Go 期间就出现，每 0.5 秒闪一次（亮 0.25、灭 0.25），
##     一直闪到战斗开始后 FINAL_BLINK_AFTER_START 秒，之后回到平时「每 5 秒亮一下」。
var battle
var clock := 0.0
const PERIOD := 5.0
const DURATION := 1.15
const FINAL_BLINK_PERIOD := 0.5
const FINAL_BLINK_ON := 0.25
const FINAL_BLINK_AFTER_START := 3.0
var _blink_clock := 0.0
var _since_start := 0.0

func _ready() -> void:
    z_index = 35

func _process(delta: float) -> void:
    if not is_instance_valid(battle):
        return
    if NetworkService.team_active and not battle._finished and not battle._watching_rival:
        if battle._battle_setup_ready:
            clock += delta
            _since_start += delta
        if _is_final_blinking():
            _blink_clock += delta
    queue_redraw()

func _is_final() -> bool:
    return battle._battlefield_kind() == "final"

# 第 21 回合：开场（模型已建好、还没放行战斗）到开战后 3 秒都在闪。
func _is_final_blinking() -> bool:
    if not _is_final() or battle._battle_3d_camera == null:
        return false
    return not battle._battle_setup_ready or _since_start < FINAL_BLINK_AFTER_START

func _draw() -> void:
    if not is_instance_valid(battle) or not NetworkService.team_active or battle._finished or battle._watching_rival:
        return
    if battle._battle_3d_camera == null or battle._battle_3d_viewport == null:
        return
    var slot: int = NetworkService.team_local_slot
    if slot < 0 or slot >= 6:
        return
    var alpha := 0.0
    if _is_final_blinking():
        if fmod(_blink_clock, FINAL_BLINK_PERIOD) >= FINAL_BLINK_ON:
            return
        alpha = 1.0
    else:
        if not battle._battle_setup_ready:
            return
        var time := fmod(clock, PERIOD)
        if time >= DURATION:
            return
        var t := time / DURATION
        alpha = minf(1.0, t * 8.0) * minf(1.0, (1.0 - t) * 4.0)
    var lane := slot % 3
    var lo: Vector2 = battle._battle_visual_min()
    var hi: Vector2 = battle._battle_visual_max()
    var enemy_side: bool = battle._color_flip
    var center: Vector2
    var turn := 0.0
    if _is_final():
        var y := lerpf(lo.y, hi.y, (float(lane) + 0.5) / 3.0)
        var x := lerpf(lo.x, hi.x, 0.75 if enemy_side else 0.25)
        center = Vector2(x, y)
        # 战场打横，双刀跟着横过来
        turn = PI * 0.5
    else:
        var x := lerpf(lo.x, hi.x, (float(lane) + 0.5) / 3.0)
        var y := lerpf(lo.y, hi.y, 0.25 if enemy_side else 0.75)
        center = Vector2(x, y)
    var origin: Vector2 = battle._battle_readability_point(center)
    var size: float = clampf(battle._arena.size.y / 720.0, 0.55, 1.8)
    var tint: Color = GameConstants.team_slot_color(slot)
    _draw_sword(origin, -0.72 + turn, size, tint, alpha)
    _draw_sword(origin, 0.72 + turn, size, tint, alpha)

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
