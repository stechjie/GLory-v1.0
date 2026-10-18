shader_type canvas_item;
// 新手教学「聚焦遮罩」：整幅压暗，只在 hole 里留一个透明的洞。
//
// 【为什么是"一整块 + 逐片元开洞"，而不是 4 块矩形拼成环形】
//   第一版（2026-10-15）用 4 块 ColorRect 围出一个洞（上/下/左/右）。玩法上成立，但
//   相邻两块共用一条**同值的分数坐标边**，而 GPU 是按"每个 quad 各自的顶点"
//   独立栅格化的；再加上被框住的目标（商店木牌）本身在**逐帧漂移**
//   （实测 y ≈ −0.027 px/帧、x ≈ +0.003 px/帧），那条公共边就会被像素栅格
//   一秒扫过一两次 —— 玩家看到的就是"屏幕在闪 + 有一条 1px 亮线"。
//   ⇒ 只要遮罩内部**不存在任何边界**，这类缝在结构上就不可能发生。
//   于是改成：单块铺满 overlay 的 ColorRect，洞由 fragment 逐片元判定。
//   附带好处：这唯一的 quad 矩形恒等于整幅 overlay，**每帧几何零变化**，
//   连"边缘随目标亚像素游走"这条抖动来源也一并消失（只改 uniform）。
//
// 【洞是硬边（不做抗锯齿）】
//   边缘不取 smoothstep / 不做 AA：压暗是"要么全压、要么完全不打"的二元状态，
//   硬边才能保证边缘像素不会随目标的亚像素漂移而明暗"呼吸"。
//
// 用法见 scripts/tutorial/TutorialMode.gd 的 _ensure_overlay / _update_focus_dim。

// 压暗颜色。与既有的两处遮罩同一档（萝卜营地 0.68 / 商店不可买原因 0.64）：
// 够暗到一眼分出主角，又留住足够的场景轮廓让新手知道自己在哪一步。
// 运行期由 TutorialMode.FOCUS_DIM_COLOR 覆盖，这里的默认值只是兜底。
uniform vec4 dim_color : source_color = vec4(0.02, 0.025, 0.04, 0.66);
// 洞口，单位是本控件的 UV（0..1）：xy = 左上角，zw = 宽高。hole_on = 0 时整幅压暗。
uniform vec4 hole = vec4(0.0, 0.0, 0.0, 0.0);
uniform float hole_on = 0.0;

void fragment() {
	COLOR.rgb = dim_color.rgb;
	// 乘上进来时的 alpha（= 节点色 × 各级 modulate），这样以后要淡入淡出遮罩
	// 只要动 modulate 就行，不必回来改 shader。
	COLOR.a = dim_color.a * COLOR.a;
	if (hole_on > 0.5) {
		vec2 lo = hole.xy;
		vec2 hi = hole.xy + hole.zw;
		if (UV.x >= lo.x && UV.x <= hi.x && UV.y >= lo.y && UV.y <= hi.y) {
			COLOR = vec4(0.0);
		}
	}
}
