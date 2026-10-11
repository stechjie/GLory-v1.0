extends RefCounted

# 「退出对局」确认框的文字（2026-10-06 用户要求：断线了除了重连可以直接退出，退出要显示惩罚、让玩家确认）。
# 三个入口共用：断线遮罩（Main）、摆放界面的设定（SettingsScreen）、开新局被上一局拦住（NetworkService.allow_new_match）。
#
# 只说**会不会扣**，不写扣多少（用户定）：扣几分要看 7 天内第几次，只有账号服务器知道，
# 而断线的时候多半也连不上它。规则本身在 backend/app/ranked.py 的 settle()：
#   · 三种模式都判负（_settle_ranked；排位以外的模式只影响对局历史里的胜负）
#   · 自定房间：不加也不扣信誉分
#   · 休闲：扣信誉分
#   · 排位：扣信誉分 + 排位分
# 那边改规则，这里的文字跟着改；tools/match_exit_check 对着这几句。
#
# mode 是空串 = 不知道这局是什么模式（旧版本存下的重连凭证里没有记），只能说通用的那句。

static func title(en: bool) -> String:
	return "Leave the match?" if en else "退出对局？"


static func body(mode: String, en: bool) -> String:
	# ★ 这半句的口径 2026-10-11 被**改回来**了，前后一共三版，别再翻第四次之前先读完：
	#
	#   初版        「你的位置由 AI 打完，**不能再回来**」
	#   10.11 上午  改成「按掉线处理，**还能**点游戏重连回来，这一局结束前开不了新局」
	#               —— 当时的规则是退出 = 保留座位，原句成了假话
	#   10.11 下午  用户改判：主动退出 = **彻底结束**这一局。座位的重连资格当场注销
	#               （NetworkService._revoke_seat_credentials），回不去，但**能马上开新局**
	#
	# 所以现在这句又得说「回不去」。🔴 **规则和文案必须一起翻** —— 这句话正是给
	# 「网络抖了、盯着断线遮罩、不耐烦想退」的人看的，他最可能照着它做决定；
	# 说反了就是主动误导。tools/match_exit_check 对着这几句。
	var lead := ("Leaving ends this match for you: you cannot return to it, "
		+ "and a new match can start right away."
		if en else "退出后这一局就结束了：**无法再回到这一局**，可以马上开新局。")
	return lead + "\n" + penalty(mode, en)


static func penalty(mode: String, en: bool) -> String:
	match mode:
		"custom":
			return "Custom rooms don't cost reputation." if en else "自定房间不扣分。"
		"casual":
			return "Your reputation will drop." if en else "会扣信誉分。"
		"ranked":
			return "Your reputation and rank points will drop." if en else "会扣信誉分和排位分。"
	return ("Matchmaking and ranked games cost reputation (custom rooms don't)."
		if en else "匹配和排位局会扣分（自定房间不扣）。")


static func confirm_text(en: bool) -> String:
	return "Leave" if en else "确认退出"
