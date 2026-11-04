extends "res://scenes/prep/effects/creatures/PrepBoardCreature2D.gd"

# 宝藏联动「凤凰涅槃」在备战棋盘上的凤凰（11.04 定稿）。通用的游动 / 点燃 / 发光都在底座里。
#
# Leno 11.04 一路的反馈：
#   1.「用代码做一个凤凰在棋盘上飞动，平面的」；
#   2.「直接做平面的在棋盘动，不需要做到在空中」→ 贴在棋盘地面上；
#   3.「就 3 个颜色，凤凰的火焰形状就行，不需要把眼睛画出来，参考那个宝藏的 logo」
#      → 造型照 assets/ui/treasure_logos/凤凰涅槃.png，整只由火舌拼成；
#   4. 亮法照赤律 4「共鸣」光球，但「要橙色的这种亮，不要弄成红色」
#      → 配色用底座默认的橙色版共鸣光（暗边近黑焦褐 → 深橙 → 亮橙金 → 暖白，光丝亮琥珀）；
#   5. 真棋盘实拍翼展近三格、压住半个棋盘 → body_scale 0.6（翼展约 1.8 格）。
# 「定稿，做下一只」。

const WING_TONGUES := 9


func _init() -> void:
	creature_name = "PrepPhoenix"


# 追加顺序 = 画的顺序（从后往前）：尾巴 → 主飞羽 → 覆羽 → 身体 → 头颈冠羽。
func _build_shape(s: float) -> void:
	var fwd := Vector2.RIGHT
	# 尾巴：七缕宽火舌扇形散开，S 形摆，转弯时往外甩（跟随动作）
	for i in 7:
		var off := float(i - 3)
		var back_dir := (-fwd).rotated(off * 0.17 - _bank * 0.45)
		var length := s * (1.65 - 0.13 * absf(off))
		var spine := _spine(_w(Vector2(-s * 0.30, off * s * 0.04)), _wd(back_dir), length,
			off * 0.22 - _bank * 0.5, float(i) * 1.3, 0.30 * (1.0 if i % 2 == 0 else -1.0))
		_add_tongue(spine, s * (0.26 - 0.025 * absf(off)), true)
	# 翅膀：扇形展开、大量重叠成一整块；翅尖那片最长、往前卷（logo 里上扬内卷的翅尖）
	var flap := sin(_flap_phase)
	var sweep := lerpf(0.05 * sin(_t * 1.3), 0.40 * flap, _flap_amount) + 0.55 * _fold
	var span := lerpf(1.0, 0.80 + 0.20 * cos(_flap_phase * 2.0 - 0.6), _flap_amount) * lerpf(0.15, 1.0, _unfold)
	if _fold < 0.0:
		span *= 1.0 + 0.45 * _fold
	for side: float in [-1.0, 1.0]:
		var side_span := span * (1.0 + 0.22 * _bank * side)
		var shoulder := Vector2(s * 0.08, side * s * 0.12)
		# 主飞羽：从贴身（指后外，短）到翅尖（指外前，长）。先画贴身的，翅尖盖在最上面
		for i in WING_TONGUES:
			var k := float(i) / float(WING_TONGUES - 1)
			# 翅根沿翅骨往外排（第二版全聚在肩上，翅膀像两团火球）；外段略往前
			var root := shoulder + Vector2(s * 0.12 * k * k - s * 0.06 * (1.0 - k), side * s * 0.55 * k * side_span)
			var ang := lerpf(2.35, 0.75, k) - sweep * (0.4 + 0.6 * k)
			var dir := Vector2(cos(ang), side * sin(ang))
			var length := s * lerpf(0.80, 1.10, pow(k, 0.7)) * lerpf(0.55, 1.0, side_span)
			var spine := _spine(_w(root), _wd(dir), length, -side * lerpf(0.35, 1.0, k), float(i) * 0.9 + side, 0.0)
			_add_tongue(spine, s * lerpf(0.30, 0.34, k), true)
		# 覆羽：一排短而胖的火舌盖在主飞羽根部，做出 logo 那种一层压一层
		for i in 4:
			var k := float(i) / 3.0
			var ang := lerpf(2.0, 1.0, k) - sweep * 0.6
			var dir := Vector2(cos(ang), side * sin(ang))
			var spine := _spine(_w(shoulder), _wd(dir), s * lerpf(0.50, 0.70, k) * lerpf(0.6, 1.0, side_span),
				-side * 0.6, float(i) * 1.7 + side * 2.0, 0.0)
			_add_tongue(spine, s * 0.30, true)
	# 身体：粗壮的水滴，从胸口往后收
	_add_tongue(_spine(_w(Vector2(s * 0.38, 0.0)), _wd(-fwd), s * 0.95, 0.0, 0.4), s * 0.42, true)
	# 头颈：S 形往前伸，尖端是喙
	var neck_dir := fwd.rotated(0.22 * sin(_t * 1.7) + _bank * 0.25 - 0.3)
	_add_tongue(_spine(_w(Vector2(s * 0.12, 0.0)), _wd(neck_dir), s * 0.62, 0.75, 2.0, 0.25), s * 0.22, true)
	# 冠羽：三缕从头顶往后卷的火
	var head := Vector2(s * 0.55, -s * 0.05)
	for i in 3:
		var off := float(i - 1)
		_add_tongue(_spine(_w(head), _wd((-fwd).rotated(off * 0.5 - 0.3)), s * (0.40 - 0.06 * absf(off)), off * 0.8 + 0.4, 3.0 + float(i)), s * 0.10, false)
