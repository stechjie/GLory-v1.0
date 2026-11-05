extends "res://scenes/menu/MainMenu.gd"

# Visual review only: build the real layout without account refresh or polling.
func _ready() -> void:
	_build()
	_layout()
	_show_shop_fallback()
	_profile_portrait.texture = AvatarCatalog.texture_for(AvatarCatalog.default_avatar())
	_profile_name_label.text = "GLory"
	_profile_sub_label.text = "主菜单美术预览"
	_coin_label.text = "1,280"
	_diamond_label.text = "360"
	_news_title.text = "欢迎来到 GLory\n\n公告内容由游戏显示"
	_news_title.visible = true
