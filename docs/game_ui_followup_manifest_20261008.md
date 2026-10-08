# Beta 0.04 MISS 与结算页跟进清单

工程：C:/Users/Leno/Desktop/Beta 0.04。以下路径均相对工程根。

## 修改

- `scripts/battle/DamageService.gd`：闪躲 MISS 事件补充技能/种族信息，并设为 important 可见优先级；不改伤害、闪躲概率或胜负逻辑。
- `tools/battle_presentation_event_check.gd`：验证普通攻击及技能闪躲的事件经 Director 和适配器抵达屏幕飘字。
- `scenes/menu/GameOverScreen.gd`：移除遮盖背景的黑色中央面板，采用备战界面的深棕、铜金按钮和铺在画面下方的结果文字；保留胜负背景图、按钮信号和跳转。
- `tools/make_server_zip.ps1`：空目录冒烟测试使用一次性 DTLS 私钥与配对证书，避免因缺少服务器私钥而误判。
- `tools/make_smoke_card_key.gd`：为上述冒烟测试在解压副本中生成一次性 DTLS 凭据；正式 ZIP 不含私钥。

## 创建

- `prechange_backups/20261008_ui_followup/scenes/menu/GameOverScreen.gd`
- `prechange_backups/20261008_ui_followup/scripts/battle/DamageService.gd`
- `prechange_backups/20261008_ui_followup/tools/battle_presentation_event_check.gd`
- `prechange_backups/20261008_ui_followup/make_server_zip.ps1`
- `prechange_backups/20261008_ui_followup/make_smoke_card_key.gd`
- `captures/game_over_ui_review_win.png`
- `captures/game_over_ui_review_lose.png`
- `captures/game_over_ui_review_win_1280.png`
- `glory_server_p40_miss_candidate.zip`（本地候选包，未上传）
- `docs/game_ui_followup_manifest_20261008.md`（本清单）

## 删除

- `tools/_game_over_ui_capture.gd`：仅用于本地截图的临时脚本，截图完成后清理。

## 验证

- `battle_presentation_event_check`: PASS，16123/16123。
- `main_screen_scenes_check`: PASS，64/64。
- `responsive_layout_check`: PASS，114/114。
- `cold_parse_chain_check`: PASS，354/354。
- Godot 4.7 实际渲染复核：胜、负 1600×720；胜 1280×720。
- 专服候选 ZIP：空目录解压后冷启动，日志出现 `server started protocol=40`；包内含 MISS priority 修正、无测试私钥及临时截图脚本。
- Git diff whitespace check 通过。

## 待完成的线上步骤

联机回放由专服生成。候选 ZIP 尚未部署，在线实战 MISS 显示须等专服更新后用一局闪躲复核。上线会重启在线战斗服务，须单独执行。

