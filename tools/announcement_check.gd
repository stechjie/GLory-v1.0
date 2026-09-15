extends Node

# 公告（docs/公告系统设计.md）的客户端验收。
#
# 核心判据，每条都对应一个**不会报错、只会静默出错或开洞**的失败：
#
#   1. 🔴 跨语言常量：推送类型、图片上限、种类表与 backend/app/announcements.py 一致 ——
#      对不上的症状分别是「紧急公告收不到」「服务器放行的图手机拒收」
#   2. 🔴 正文 BBCode 只放行白名单：[img] 能加载包里任意资源、[url] 能跳任意外链
#   3. 登录弹窗只弹勾了 popup 的；revision 变了再弹；弹过的不弹
#   4. 🔴 「看过」的记录不按列表裁剪 —— 服务器刚重启时返回空列表，裁了就全服重弹
#   5. 维护公告：过期按服务器 Date 头判；时区后缀算对；"true" 字符串不算
#   6. 图片：只认 /media/<小写哈希>.<扩展名>；字节对不上哈希就不解码；长边超限不解码
#   7. 接线：主菜单入口不再是「敬请期待」、Main 接了界面 / 跳转 / 登出、autoload 注册了、请求带版本头
#   8. 公告界面、登录弹窗、顶部横条能画出来，收起后不留看不见却吃点击的控件
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/announcement_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Text := preload("res://scripts/account/AnnouncementText.gd")
const Service := preload("res://scripts/autoload/AnnouncementService.gd")
const Images := preload("res://scripts/account/AnnouncementImages.gd")
const ServiceStatus := preload("res://scripts/account/ServiceStatus.gd")
const SCREEN_SCENE := preload("res://scenes/menu/AnnouncementScreen.tscn")
const PopupScript := preload("res://scenes/menu/AnnouncementPopup.gd")

const CHECK_NAME := "announcement"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_constants_match_backend()
	_case_bbcode_whitelist()
	_case_text_helpers()
	_case_popup_selection()
	_case_seen_record_survives_empty_list()
	_case_service_status()
	await _case_images()
	_case_wiring()
	await _case_screen_renders()
	await _case_popup_and_banner()
	_h.finish(get_tree())


# --- 1. 🔴 跨语言常量 ------------------------------------------------------------

func _case_constants_match_backend() -> void:
	var py := FileAccess.get_file_as_string("res://backend/app/announcements.py")
	_h.item()
	if py.is_empty():
		_h.fail("backend_unreadable", "读不到 backend/app/announcements.py")
		return
	_h.expect(py.contains('PUSH_TYPE = "%s"' % Service.PUSH_TYPE), "push_type_drift",
		"后端的 PUSH_TYPE 不是 %s 了 —— 紧急公告会落进 RealtimeService 的未知类型分支，收不到也不报错" % Service.PUSH_TYPE)
	# 服务器把原图转成 WebP，转出来的不超过它的 IMAGE_MAX_BYTES；手机这边的上限只许更宽，不许更窄。
	_h.expect(py.contains("IMAGE_MAX_BYTES = 1024 * 1024") and Images.MAX_BYTES >= 1024 * 1024, "image_bytes_drift",
		"手机的图片字节上限（%d）比服务器转出来的图还小 —— 手机会拒收，玩家看不到图" % Images.MAX_BYTES)
	_h.expect(py.contains("IMAGE_MAX_SIDE = %d" % Images.MAX_SIDE), "image_side_drift",
		"图片长边上限两边对不上（客户端 %d）" % Images.MAX_SIDE)
	_h.expect(py.contains('KINDS = ("%s")' % '", "'.join(PackedStringArray(Service.KINDS))), "kinds_drift",
		"公告种类表两边对不上 —— 新种类在客户端会显示成「系统」")
	var routes := FileAccess.get_file_as_string("res://backend/app/routes/announcements.py")
	_h.expect(routes.contains('@router.get("/v1/announcements"'), "endpoint_drift",
		"后端没有 GET /v1/announcements 了，客户端 AccountManager.fetch_announcements 还在打它")


# --- 2. 🔴 BBCode 白名单 ---------------------------------------------------------

func _case_bbcode_whitelist() -> void:
	var cases := {
		"[b]粗[/b][i]斜[/i][u]下[/u]": "[b]粗[/b][i]斜[/i][u]下[/u]",
		"[color=#FFCC00]金[/color]": "[color=#FFCC00]金[/color]",
		"[url=glory://prep]去备战[/url]": "[url=glory://prep]去备战[/url]",
		"[img]res://icon.svg[/img]": "[lb]img]res://icon.svg[lb]/img]",
		"[url=https://evil.example]点我[/url]": "[lb]url=https://evil.example]点我[/url]",
		"[url=glory://settings]设置[/url]": "[lb]url=glory://settings]设置[/url]",
		"[url]glory://prep[/url]": "[lb]url]glory://prep[/url]",
		"[color=red]红[/color]": "[lb]color=red]红[/color]",
		"[b=1]x[/b]": "[lb]b=1]x[/b]",
		"[font_size=99]大[/font_size]": "[lb]font_size=99]大[lb]/font_size]",
		"数组[0] 和 [lb]": "数组[lb]0] 和 [lb]lb]",
		"没有标签": "没有标签",
		"结尾是 [": "结尾是 [lb]",
	}
	for raw in cases:
		var got := Text.sanitize_bbcode(str(raw))
		_h.expect(got == str(cases[raw]), "bbcode_whitelist",
			"正文 %s 过白名单后是 %s，应当是 %s" % [raw, got, cases[raw]])

	_h.expect(Text.link_route("glory://codex") == "codex", "link_route_rejects_valid", "glory://codex 应当放行")
	for bad in ["glory://codex/extra", "https://glory.example", "glory://", "GLORY://prep", ""]:
		_h.expect(Text.link_route(bad).is_empty(), "link_route_too_loose", "%s 不该被当成游戏内页面" % bad)
	_h.expect(Text.plain_text("[b]限时[/b]活动 [color=#FF0000]今晚[/color] [x]") == "限时活动 今晚 [x]",
		"plain_text_drift", "弹窗预览去标签的结果不对：%s" % Text.plain_text("[b]限时[/b]活动 [color=#FF0000]今晚[/color] [x]"))


# --- 文案小工具 ------------------------------------------------------------------

func _case_text_helpers() -> void:
	var both := {"title_zh": "夏日活动", "title_en": "Summer"}
	var zh_only := {"title_zh": "只有中文", "title_en": "  "}
	var en_only := {"title_zh": "", "title_en": "English only"}
	_h.expect(Text.pick_text(both, "title", true) == "Summer" and Text.pick_text(both, "title", false) == "夏日活动",
		"pick_text_language", "中英都有时没按语言挑")
	_h.expect(Text.pick_text(zh_only, "title", true) == "只有中文", "pick_text_blank_english",
		"英文没写时英文玩家应当看中文，不是空白")
	_h.expect(Text.pick_text(en_only, "title", false) == "English only", "pick_text_blank_chinese",
		"中文没写时应当退回英文，不是空白")

	var noon_utc := Time.get_unix_time_from_datetime_dict(
		{"year": 2026, "month": 9, "day": 20, "hour": 12, "minute": 0, "second": 0})
	_h.expect(Text.time_text(noon_utc, null, 480, false) == "9月20日 20:00 发布", "time_text_zh",
		"时间显示不对：%s" % Text.time_text(noon_utc, null, 480, false))
	var english := Text.time_text(noon_utc, float(noon_utc + 86400), 480, true)
	_h.expect(english == "Sep 20 20:00 – Sep 21 20:00", "time_text_en", "英文时间显示不对：%s" % english)

	var preview := Text.row_text({"kind": "event", "title_zh": "测试", "preview": true}, false)
	_h.expect(preview == "（预览）【活动】测试", "row_text", "列表行文字不对：%s" % preview)
	_h.expect(Text.kind_label("something_new", false) == "系统", "kind_label_fallback",
		"认不出的种类应当显示成「系统」")


# --- 3. 登录弹窗 -----------------------------------------------------------------

func _case_popup_selection() -> void:
	var list := [
		{"id": 1, "revision": 1, "popup": false},
		{"id": 2, "revision": 2, "popup": true},
		{"id": 3, "revision": 1, "popup": true},
	]
	_h.expect(int(Service.pick_popup(list, {}).get("id", 0)) == 2, "popup_order",
		"应当按服务器给的顺序弹第一条勾了 popup 的")
	_h.expect(int(Service.pick_popup(list, {"2": 2}).get("id", 0)) == 3, "popup_repeats",
		"弹过的（同 revision）又弹了")
	_h.expect(int(Service.pick_popup(list, {"2": 1, "3": 1}).get("id", 0)) == 2, "popup_revision_ignored",
		"管理员把 revision 加了 1，没有再弹")
	_h.expect(Service.pick_popup(list, {"2": 2, "3": 1}).is_empty(), "popup_never_ends",
		"全弹过了还在弹")
	_h.expect(Service.pick_popup([{"id": 4, "revision": 1, "popup": "true"}], {}).is_empty(), "popup_string_true",
		"popup 必须是 JSON 的 true")


# --- 4. 🔴 看过的记录 ------------------------------------------------------------

func _case_seen_record_survives_empty_list() -> void:
	var svc: Service = Service.new()
	svc.seen_file = ""
	svc.apply_list([{"id": 5, "revision": 1, "kind": "news", "title_zh": "a"}])
	_h.expect(svc.any_unread(), "unread_missing", "新公告没有亮红点")
	svc.mark_seen(svc.find_item(5))
	_h.expect(not svc.any_unread(), "seen_not_recorded", "看过之后红点没灭")
	svc.apply_list([])
	svc.apply_list([{"id": 5, "revision": 1, "kind": "news", "title_zh": "a"}])
	_h.expect(not svc.is_unread(svc.find_item(5)), "seen_pruned_by_empty_list",
		"服务器短暂返回空列表之后「看过」被清掉了 —— 真实上线时账号服务器每次重启都会全服重新亮红点、重新弹窗")
	svc.apply_list([{"id": 5, "revision": 2, "kind": "news", "title_zh": "a"}])
	_h.expect(svc.is_unread(svc.find_item(5)), "revision_bump_ignored", "管理员把 revision 加了 1，红点没有重新亮")
	svc.free()

	var big := {}
	for id in range(1, Service.SEEN_LIMIT + 51):
		big[str(id)] = 1
	var capped := Service.capped(big)
	_h.expect(capped.size() == Service.SEEN_LIMIT and capped.has(str(Service.SEEN_LIMIT + 50))
			and not capped.has("1"), "seen_cap", "封顶时应当丢最老（id 最小）的记录")
	var parsed := Service.revision_map({"5": 2.0, "x": 1, "7": "3", "8": {}, "-1": 4})
	_h.expect(parsed == {"5": 2}, "seen_file_parsing", "本机记录解析不对：%s" % str(parsed))


# --- 5. 维护公告 -----------------------------------------------------------------

func _case_service_status() -> void:
	var ten_utc := Time.get_unix_time_from_datetime_dict(
		{"year": 2026, "month": 9, "day": 20, "hour": 10, "minute": 0, "second": 0})
	var body := '{"maintenance": true, "title_zh": "维护中", "message_zh": "预计 20:00 恢复", "expires_at": "2026-09-20 20:00+08:00"}'
	var shown := ServiceStatus.parse(body, ten_utc)
	_h.expect(str(shown.get("title_zh", "")) == "维护中" and str(shown.get("message_zh", "")) == "预计 20:00 恢复",
		"status_not_shown", "维护公告没有解析出来：%s" % str(shown))
	_h.expect(ServiceStatus.parse(body, ten_utc + 3 * 3600).is_empty(), "status_never_expires",
		"过了 expires_at（按服务器时间）还在显示 —— 管理员忘了删文件时，网络不好的玩家会被告知「在维护」")
	_h.expect(ServiceStatus.parse('{"maintenance": "true"}', ten_utc).is_empty(), "status_string_true",
		"\"true\" 字符串被当成了在维护")
	_h.expect(ServiceStatus.parse('{"maintenance": false, "title_zh": "x"}', ten_utc).is_empty(), "status_false_shown",
		"maintenance=false 也显示了")
	_h.expect(ServiceStatus.parse("<html>502</html>", ten_utc).is_empty(), "status_garbage_shown",
		"不是 JSON 的响应被当成了维护公告")

	var twelve := ten_utc + 7200
	for text in ["2026-09-20T12:00:00Z", "2026-09-20 20:00+08", "2026-09-20T20:00:00+08:00", "2026-09-20 07:00-05:00", "2026-09-20 12:00"]:
		_h.expect(ServiceStatus.parse_iso_utc(text) == twelve, "iso_timezone",
			"%s 应当是 %d，算出来 %d" % [text, twelve, ServiceStatus.parse_iso_utc(text)])
	_h.expect(ServiceStatus.parse_iso_utc("明天晚上") == 0, "iso_garbage", "认不出的时间应当返回 0")
	_h.expect(ServiceStatus.parse_http_date("Sun, 20 Sep 2026 10:00:00 GMT") == ten_utc, "http_date",
		"Date 头解析不对")
	_h.expect(ServiceStatus.server_time_from_headers(PackedStringArray(
			["Content-Type: application/json", "date: Sun, 20 Sep 2026 10:00:00 GMT"])) == ten_utc,
		"http_date_header_lookup", "响应头里找 Date 应当不分大小写")


# --- 6. 图片 ---------------------------------------------------------------------

func _case_images() -> void:
	var sha := "a".repeat(64)
	_h.expect(Images.is_valid_ref("/media/%s.png" % sha, sha), "image_ref_rejects_valid", "合规的图片地址被拒了")
	for bad in [
		["https://evil.example/media/%s.png" % sha, sha],
		["/media/%s.gif" % sha, sha],
		["/media/%s.png" % sha.to_upper(), sha.to_upper()],
		["/media/%s.png" % sha, "b".repeat(64)],
		["/media/../secret.png", "../secret"],
		["/media/%s.png" % "g".repeat(64), "g".repeat(64)],
	]:
		_h.expect(not Images.is_valid_ref(str(bad[0]), str(bad[1])), "image_ref_too_loose",
			"不该下载的图片地址被放行了：%s" % bad[0])

	var hello := "hello".to_utf8_buffer()
	var hello_sha := "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	_h.expect(Images.sha256_hex(hello) == hello_sha, "sha256_wrong", "SHA-256 算得不对")
	_h.expect(Images.bytes_match(hello, hello_sha) and not Images.bytes_match(hello, sha)
			and not Images.bytes_match(PackedByteArray(), hello_sha), "bytes_match", "字节与哈希的比对不对")

	var small := Image.create_empty(8, 4, false, Image.FORMAT_RGBA8).save_png_to_buffer()
	var texture := Images.decode(small, "png")
	_h.expect(texture != null and texture.get_width() == 8, "decode_png", "正常的 PNG 没解出来")
	var wide := Image.create_empty(Images.MAX_SIDE + 1, 1, false, Image.FORMAT_RGBA8).save_png_to_buffer()
	_h.expect(Images.decode(wide, "png") == null, "decode_ignores_max_side", "长边超限的图被解码了")

	# 缓存命中：本地有、哈希对得上就直接用，不联网。
	var small_sha := Images.sha256_hex(small)
	var path := Images.cache_path(small_sha, "png")
	DirAccess.make_dir_recursive_absolute(Images.CACHE_DIR)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(small)
	f.close()
	var cached: Texture2D = await AnnouncementService.images.texture_for(
		{"url": "/media/%s.png" % small_sha, "sha256": small_sha})
	_h.expect(cached != null and cached.get_height() == 4, "cache_not_used", "本地缓存里有这张图却没用上")
	DirAccess.remove_absolute(path)
	var refused: Texture2D = await AnnouncementService.images.texture_for(
		{"url": "https://evil.example/x.png", "sha256": sha})
	_h.expect(refused == null, "foreign_image_loaded", "列表里的外部地址被拿去下载了")


# --- 7. 接线 ---------------------------------------------------------------------

func _case_wiring() -> void:
	var menu := FileAccess.get_file_as_string("res://scenes/menu/MainMenu.gd")
	_h.expect(menu.contains("_add_hit(Vector2(1380, 400), Vector2(270, 250), _emit_announcements"),
		"news_entry_still_coming_soon", "主菜单「公告 / 活动」那块图点了还是「敬请期待」")
	var main := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	_h.expect(main.contains("_menu.announcements_requested.connect(_show_announcements_screen)"),
		"announcement_screen_not_wired", "Main 没有接主菜单的公告入口")
	_h.expect(main.contains("\tAnnouncementService.reset()"), "announcements_not_reset_on_logout",
		"登出时没有清公告状态 —— 上一个账号的横条会留给下一个人")
	for route in Text.ROUTES:
		_h.expect(main.contains('\t\t"%s":' % route), "link_route_unhandled",
			"正文链接 glory://%s 在白名单里，但 Main._on_announcement_navigate 不处理它 —— 点了没反应" % route)
	var project := FileAccess.get_file_as_string("res://project.godot")
	_h.expect(project.contains('AnnouncementService="*res://scripts/autoload/AnnouncementService.gd"'),
		"autoload_missing", "project.godot 的 [autoload] 里没有 AnnouncementService")
	var account := FileAccess.get_file_as_string("res://scripts/autoload/AccountManager.gd")
	_h.expect(account.contains('_request(HTTPClient.METHOD_GET, "/v1/announcements", null, true)'),
		"fetch_not_authed", "拉公告必须带令牌（预览账号靠它认人）")
	_h.expect(account.contains('PackedStringArray(["Content-Type: application/json", client_header_line()])'),
		"client_header_missing", "请求没带 X-Glory-Client —— 以后没法只给旧版本弹「请更新」")
	var header := AccountManager.client_header_line()
	_h.expect(header.begins_with("X-Glory-Client: protocol=%d; build=" % NetworkConfig.NETWORK_PROTOCOL_VERSION),
		"client_header_shape", "版本头格式不对：%s" % header)


# --- 8. 界面 ---------------------------------------------------------------------

func _fixture() -> Array:
	return [
		{"id": 901, "revision": 1, "kind": "event", "title_zh": "测试活动", "title_en": "",
			"body_zh": "[b]正文[/b][img]res://icon.svg[/img]", "body_en": "", "image": null,
			"popup": true, "starts_at": 1789000000, "ends_at": null, "preview": false, "problem": ""},
		{"id": 902, "revision": 1, "kind": "news", "title_zh": "测试公告", "title_en": "",
			"body_zh": "第二条", "body_en": "", "image": null,
			"popup": false, "starts_at": 1789000000, "ends_at": 1789086400, "preview": true,
			"problem": "图片 x.png：找不到"},
	]


func _case_screen_renders() -> void:
	AnnouncementService.seen_file = ""
	AnnouncementService.apply_list(_fixture())
	var screen = SCREEN_SCENE.instantiate()
	screen.configure(902)
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame

	var title := screen.find_child("Title", true, false) as Label
	var problem := screen.find_child("Problem", true, false) as Label
	_h.expect(title != null and title.text == "测试公告", "screen_focus_ignored",
		"从弹窗「查看详情」进来时没有定位到那一条")
	_h.expect(problem != null and problem.visible and problem.text.contains("x.png"), "screen_problem_hidden",
		"预览账号看不到服务器写回的问题")
	_h.expect(screen.find_child("Item_901", true, false) != null and screen.find_child("Item_902", true, false) != null,
		"screen_list_incomplete", "列表没有把两条都画出来")
	_h.expect(not AnnouncementService.is_unread(AnnouncementService.find_item(902)), "screen_not_marking_seen",
		"打开看了还亮红点")

	(screen.find_child("Item_901", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var body := screen.find_child("Body", true, false) as RichTextLabel
	_h.expect(title.text == "测试活动" and body != null and body.text.contains("[b]正文[/b]")
			and body.text.contains("[lb]img]"), "screen_select_or_sanitize",
		"点列表没切过去，或者正文没过白名单：%s" % (body.text if body != null else "<no body>"))

	var routes: Array = []
	screen.navigate_requested.connect(func(route: String) -> void: routes.append(route))
	screen._on_meta_clicked("glory://codex")
	screen._on_meta_clicked("https://evil.example")
	_h.expect(routes == ["codex"], "screen_link_whitelist", "正文链接跳转不对：%s" % str(routes))

	remove_child(screen)
	screen.free()


func _case_popup_and_banner() -> void:
	var popup = PopupScript.new()
	var modal_id := ModalStack.push(popup, {"id": "announcement_check_popup", "priority": 20,
		"dismiss_on_backdrop": true})
	_h.expect(not modal_id.is_empty(), "popup_push_failed", "登录弹窗没能进 ModalStack")
	popup.configure((_fixture()[0] as Dictionary))
	await get_tree().process_frame
	var asked: Array = []
	popup.details_requested.connect(func(id: int) -> void: asked.append(id))
	var details := popup.find_child("Details", true, false) as Button
	_h.expect(details != null, "popup_details_missing", "登录弹窗没有「查看详情」")
	if details != null:
		details.pressed.emit()
	_h.expect(asked == [901], "popup_details_id", "「查看详情」没带上公告 id：%s" % str(asked))
	ModalStack.pop(modal_id)

	_h.expect(AnnouncementService.show_banner({"id": 903, "revision": 1, "title_zh": "10 分钟后停服"}),
		"banner_not_shown", "紧急公告横条没出来")
	_h.expect(AnnouncementService.has_banner(), "banner_missing", "横条显示了却找不到")
	_h.expect(not AnnouncementService.show_banner({"id": 903, "revision": 1, "title_zh": "10 分钟后停服"}),
		"banner_repeats", "同一条紧急公告这次启动里出了两次")
	AnnouncementService.hide_banner()
	await get_tree().process_frame
	_h.expect(not AnnouncementService.has_banner(), "banner_not_hidden", "横条收不起来")
	var leaks: Array = []
	for path in ModalStack.find_invisible_stop_controls():
		if str(path).contains("Announcement"):
			leaks.append(path)
	_h.expect(leaks.is_empty(), "invisible_stop_left",
		"弹窗 / 横条收起后留下了看不见却吃点击的控件：%s" % str(leaks))

	AnnouncementService.reset()
	AnnouncementService.seen_file = Service.SEEN_FILE
