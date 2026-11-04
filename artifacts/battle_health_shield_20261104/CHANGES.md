# 血条与护盾显示修改记录

最终方案：固定原来的 72×9 底槽、66 像素填充宽度，生命段后直接连接蓝色护盾段，不延长底槽。小盾牌贴近原槽右端，不移动单位或加入避让。

显示比例：以 max(最大生命值, 当前生命值 + 显示护盾值) 为容量，两种颜色共同分配原槽。满血有盾不留人为黑尾；护盾消耗时蓝色占比减少，生命色占比回升只是显示分配变化，不代表回血。没有护盾时恢复原生命百分比。
少量正护盾至少显示 3 像素蓝色；护盾高于最大生命值时保留小盾牌加号。普通掉盾约 0.12 秒平滑过渡；破盾、死亡与同击掉血立即同步。
斩杀线读取当前生命显示比例，其 10% 游戏规则未修改。

修改文件：
- scenes/battle/BattleRenderer.gd
- scenes/battle/BattleVfx.gd（仅斩杀线的显示位置计算）
新增并维护的验证文件：
- tools/battle_health_bar_check.gd
- tools/battle_health_bar_check.tscn
未修改伤害计算、护盾吸收规则、技能、网络回放、角色移动和其他工作区改动。未移动或删除文件。

验证：battle_health_bar 63 项、battle_team_color 24 项、battle_death_exit 42 项，合计 129 项通过；git diff --check 通过。
最终控件预览：preview_fixed.png。
固定长度版实际战斗回放：battle_fixed/，25 次采样、4 张截图，捕获器报告 PASS。捕获后只微调了小额护盾的平滑速度，并重新通过 63 项血条检查；布局不变。
旧的 preview.png、preview_joined.png 和 battle/ 仅保留作历史对照，不是最终方案。
密集单位仍可能遮挡：用户明确要求保持当前位置，不加入上下避让。
运行环境报告系统证书存储读取失败，以及图形预览的用户目录/着色器缓存写入限制。无脚本解析错误，功能断言通过；未验证手机实机性能。

备份与运行记录：
- prechange_backups/20261104_battle_health_shield/battle_capture.log
- prechange_backups/20261104_battle_health_shield/battle_health_bar_check.separate_bars.gd
- prechange_backups/20261104_battle_health_shield/BattleRenderer.gd
- prechange_backups/20261104_battle_health_shield/BattleRenderer.separate_bars.gd
- prechange_backups/20261104_battle_health_shield/death_exit_joined.log
- prechange_backups/20261104_battle_health_shield/death_exit.log
- prechange_backups/20261104_battle_health_shield/fixed_width/battle_capture.log
- prechange_backups/20261104_battle_health_shield/fixed_width/battle_health_bar_check.gd
- prechange_backups/20261104_battle_health_shield/fixed_width/BattleRenderer.gd
- prechange_backups/20261104_battle_health_shield/fixed_width/BattleVfx.gd
- prechange_backups/20261104_battle_health_shield/fixed_width/death_exit.log
- prechange_backups/20261104_battle_health_shield/fixed_width/health_bar.log
- prechange_backups/20261104_battle_health_shield/fixed_width/preview.log
- prechange_backups/20261104_battle_health_shield/fixed_width/team_color.log
- prechange_backups/20261104_battle_health_shield/health_bar_joined.log
- prechange_backups/20261104_battle_health_shield/health_bar.log
- prechange_backups/20261104_battle_health_shield/preview_joined.log
- prechange_backups/20261104_battle_health_shield/preview.log
- prechange_backups/20261104_battle_health_shield/team_color_joined.log
- prechange_backups/20261104_battle_health_shield/team_color.log

预览、实战对照与记录文件：
- artifacts/battle_health_shield_20261104/battle_fixed/01-opening.png
- artifacts/battle_health_shield_20261104/battle_fixed/02-shield-established.png
- artifacts/battle_health_shield_20261104/battle_fixed/03-persistent-state.png
- artifacts/battle_health_shield_20261104/battle_fixed/05-timeline-end.png
- artifacts/battle_health_shield_20261104/battle_fixed/evidence.json
- artifacts/battle_health_shield_20261104/battle/01-opening.png
- artifacts/battle_health_shield_20261104/battle/02-shield-established.png
- artifacts/battle_health_shield_20261104/battle/03-persistent-state.png
- artifacts/battle_health_shield_20261104/battle/05-timeline-end.png
- artifacts/battle_health_shield_20261104/battle/evidence.json
- artifacts/battle_health_shield_20261104/preview_fixed.png
- artifacts/battle_health_shield_20261104/preview_joined.png
- artifacts/battle_health_shield_20261104/preview.png
- artifacts/battle_health_shield_20261104/CHANGES.md（本文件）
