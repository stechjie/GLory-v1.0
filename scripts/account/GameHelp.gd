extends RefCounted

# These pages are packaged with the game and do not require a working website.
const HELP_ZH := "GLory Auto Chess 是一款策略自走棋游戏。招募、合成与布阵组建阵容，管理对局经济，参与自动战斗及多人协作竞技。\n\n开始游戏：首次联网建立游戏账号；选择游客方式时不需要邮箱或密码。主菜单可进入教学和对局；在设置中可重新体验教学。\n\n账号删除：点击主菜单左上角自己的名牌，在个人资料中找到“注销账号”，输入页面上的好友码并确认。卸载游戏不等于删除账号。游客账号在卸载或换机后可能无法找回。\n\n举报与屏蔽：在世界频道点击发送者，可举报消息或查看资料；玩家资料中可举报或拉入黑名单。语音面板可单独屏蔽声音。举报由运营核实处理。请勿发布辱骂、骚扰、色情、违法或侵权内容。\n\n购买：可用商品会显示平台价格；iOS 购买通过 Apple 付款页面完成，到账由服务器确认。取消购买不会发放钻石。处理中请勿重复付款，重新启动游戏会尝试补交未完成交易。祈愿页面在抽取前显示概率和保底规则。\n\n网络与权限：账号及多人功能需要联网。麦克风仅用于主动开启的语音，拒绝麦克风权限仍可游戏。\n\n支持、举报跟进及数据请求：bytegamesg2025@gmail.com。可提供版本、问题时间和好友码；请勿发送密码或登录令牌。"
const HELP_EN := "GLory Auto Chess is a strategy auto battler. Recruit, merge and position units, manage match resources, and cooperate and compete in automatic battles.\n\nGetting started: set up a game account on first online launch. Guest access does not require an email or password. Access the tutorial and matches from the main menu; replay the tutorial from Settings.\n\nDelete account: open your nameplate at the top left of the main menu. Find Delete account in your profile, enter the displayed friend code and confirm. Uninstalling does not delete your account. Guest progress may be lost after reinstalling or changing devices.\n\nReport and block: tap a sender in world chat to report a message or view their profile. Profiles offer Report player and Block player. The voice panel separately mutes audio. Reports are reviewed by the operator. Abusive, harassing, sexual, illegal and infringing content is prohibited.\n\nPurchases: available products show platform prices. iOS purchases use the Apple payment sheet; the server confirms delivery. Cancelling grants no diamonds. Avoid repeated payments while processing. Relaunching retries unfinished transactions. Wish screens display odds and guarantees before drawing.\n\nConnectivity and permissions: accounts and multiplayer need an internet connection. The microphone is used for voice you enable; denying permission does not prevent gameplay.\n\nSupport, report follow-up and data requests: bytegamesg2025@gmail.com. Include the version, issue time and friend code if useful. Never send passwords or login tokens."

static func show_help(owner: Object) -> void:
	var english := LocaleManager.get_locale() == "en"
	_show(owner, "help", "Game help and support" if english else "游戏帮助与支持", HELP_EN if english else HELP_ZH)

static func show_privacy(owner: Object) -> void:
	var english := LocaleManager.get_locale() == "en"
	_show(owner, "privacy", "Privacy policy" if english else "隐私政策", PrivacyText.EN if english else PrivacyText.ZH)

static func show_deletion(owner: Object) -> void:
	var english := LocaleManager.get_locale() == "en"
	var body := "Open your own profile, find Delete account, enter your friend code and confirm. Deletion is permanent; pets, currency and progress cannot be recovered. Uninstalling does not delete server data. Profile, friends, ordinary chat and account-linked activity and analytics data are removed. Some match, transaction, penalty, report evidence and technical records may remain for verification, disputes and abuse prevention, without a single fixed retention period. For data requests contact bytegamesg2025@gmail.com; ownership is verified before acting. Never send passwords, tokens or identity documents." if english else "打开自己的个人资料，找到“注销账号”，输入页面显示的好友码并确认。注销不可恢复，宠物、虚拟货币及进度不能继续使用。卸载不等于注销。个人资料、好友、普通聊天和账号关联的活跃及分析数据会删除；部分对局、物品流水、处罚、举报证据及技术记录可能为核对、争议和防滥用而保留，未设置统一到期期限。数据请求请联系 bytegamesg2025@gmail.com，我们会核实归属后处理。请勿发送密码、令牌或身份证件。"
	_show(owner, "deletion", "Account and data deletion" if english else "账号与数据删除", body)

const PrivacyText := preload("res://scripts/account/PrivacyText.gd")

static func _show(owner: Object, page: String, title: String, body: String) -> void:
	DialogService.info({"owner": owner, "request_id": "game_help_" + page,
		"title": title, "body": body,
		"confirm_text": "Close" if LocaleManager.get_locale() == "en" else "关闭"})
