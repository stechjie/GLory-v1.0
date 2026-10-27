extends Node
const H := preload("res://tools/CheckHarness.gd")
const Deadline := preload("res://scripts/rounds/PrepDeadline.gd")
const Countdown := preload("res://scenes/prep/PrepCountdown.gd")
const Errors := preload("res://scripts/account/AccountErrorText.gd")
class AccountProbe extends "res://scripts/autoload/AccountManager.gd":
 var replies: Array = []
 var calls: Array = []
 func is_logged_in() -> bool: return true
 func _request(method: int, path: String, payload: Variant = null, authed: bool = false, allow_refresh: bool = true) -> Dictionary:
  calls.append({"path":path,"payload":payload,"method":method})
  return replies.pop_front() if not replies.is_empty() else {"code":500,"error":"unexpected request"}
var h: RefCounted
func _ready() -> void:
 h = H.new("ranked_regression_1027")
 NetworkService.set_process(false)
 _timing()
 await _account_lifecycle()
 _languages()
 h.finish(get_tree())
func _timing() -> void:
 for spec: Dictionary in [{"mode":"casual","ruleset":"seedling","rounds":13},{"mode":"casual","ruleset":"normal","rounds":21},{"mode":"ranked","ruleset":"seedling","rounds":13},{"mode":"ranked","ruleset":"normal","rounds":21}]:
  GameState.FINAL_ROUND=int(spec.rounds)
  GameState.final_round_played=false
  for i in range(1,int(spec.rounds)+1):
   var pvp := i in ([6,11,13] if int(spec.rounds)==13 else [6,12,18,21])
   var expected := 60.0 if str(spec.mode)=="casual" and str(spec.ruleset)=="seedling" or pvp else 45.0
   h.expect(Deadline.duration(i,str(spec.ruleset),str(spec.mode))==expected,"mode_duration","%s %s round %d" % [spec.mode,spec.ruleset,i])
   var room := {"state":"prep","round_index":i,"ruleset":spec.ruleset,"mode":spec.mode,"state_started_at":100.0}
   h.expect(is_equal_approx(Deadline.remaining(room,110.0),expected-10.0),"server_remaining","Mode-aware countdown")
   h.expect(Deadline.remaining(room,1000.0)==0.0,"expired_clamped","No negative remaining")
  GameState.round_index=1
  NetworkService.match_mode=str(spec.mode)
  var host := Control.new()
  add_child(host)
  var countdown := Countdown.new()
  host.add_child(countdown)
  countdown.set_process(false)
  var actual: float = float(countdown.get("_deadline"))-Time.get_ticks_msec()/1000.0
  var expected := 60.0 if str(spec.mode)=="casual" and str(spec.ruleset)=="seedling" else 45.0
  h.expect(absf(actual-expected)<0.1,"client_fallback","Client fallback equals server at round 1")
  host.free()
 # Room timing must remain correct while the process-global schedule belongs to another room.
 GameState.FINAL_ROUND=21
 for i in [6,11,13]:
  h.expect(Deadline.duration(i,"seedling","ranked")==60.0,"ranked_13_room_schedule","13-round ranked PvP is independent of the process global")
 GameState.FINAL_ROUND=13
 for i in [6,12,21]:
  h.expect(Deadline.duration(i,"normal","ranked")==60.0,"ranked_21_room_schedule","21-round ranked PvP is independent of the process global")
 h.expect(Deadline.remaining({"state":"battle"},100)==-1.0,"not_prep","No active prep countdown during battle")
func _account_lifecycle() -> void:
 SaveManager.clear_reconnect()
 NetworkService.latest_match_state={}
 var probe := AccountProbe.new()
 probe.replies=[{"code":200,"body":{"state":{"state":"ready","match_uid":"a".repeat(32)}}},{"code":200,"body":{"state":{"state":"idle"}}}]
 var result: Dictionary = await probe.reconcile_finished_assignment()
 h.expect(int(result.code)==200 and probe.calls.size()==2,"stale_release","A nonexistent battle seat releases its own allocation")
 h.expect(str(probe.calls[1].path)=="/v1/match/release" and str(probe.calls[1].payload.match_uid)=="a".repeat(32),"release_identity","Release carries the exact old match ID")
 for locale in ["zh","en"]:
  LocaleManager.set_locale(locale)
  SaveManager.save_reconnect("ranked_probe", "127.0.0.1",7777,"ranked")
  SaveManager.mark_match_started()
  NetworkService.state=NetworkService.SessionState.RECONNECTING
  probe.calls=[]
  probe.replies=[{"code":200,"body":{"state":{"state":"ready","match_uid":"b".repeat(32)}}}]
  result=await probe.reconcile_finished_assignment()
  h.expect(int(result.code)==409 and probe.calls.size()==1,"active_not_released","Active match never silently released")
  var expected := "上一局还没结束，请先游戏重连或退出对局。" if locale=="zh" else "Your previous match is still running. Reconnect or leave it first."
  h.expect(str(result.error)==expected,"active_localized","Correct language for active-match error")
 SaveManager.clear_reconnect()
 NetworkService.state=NetworkService.SessionState.OFFLINE
 probe.calls=[]
 probe.replies=[{"code":200,"body":{"state":{"state":"queued"}}},{"code":503,"error":"test unavailable"}]
 result=await probe.prepare_custom_room()
 h.expect(int(result.code)==503,"leave_failure","Failure to leave old party is propagated")
 h.expect(str(probe.calls[1].path)=="/v1/party" and int(probe.calls[1].method)==HTTPClient.METHOD_DELETE,"leave_before_custom","Cross-room transition leaves/cancels the account party")
 probe.free()
func _languages() -> void:
 for text in ["排位每天 19:00 - 23:00 开放","你被暂时禁止排队，稍后再试","信誉分过低，暂时不能排这个模式","你的排位资格已被暂停","服务器正在维护，暂时不能开始新对局","排位功能暂时关闭","服务状态暂时确认不了，请稍后再试","现在不能开始新对局","现在不能排这个模式","排位模式需在备战区携带至少3个已解锁种族。","突破后排位模式需在备战区携带至少4个已解锁种族。","上一局还没结束，请先游戏重连或退出对局。","暂时无法确认对局状态，请检查网络后重试","无法退出原队伍，请重试","现在不能开始匹配"]:
  h.expect(Errors.localize(text,"zh")==text,"chinese_text","Chinese remains Chinese")
  h.expect(Errors.localize(text,"en")!=text,"english_text","English has a translated message: "+text)
