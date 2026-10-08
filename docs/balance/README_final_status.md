# final status 数值与文案

`final status.xlsx` 是中文显示文案和已核对数值的编辑源。Godot 运行时读取同目录对应的 `data/balance/final_status.json`，按稳定 ID 显示棋子技能、宠物、羁绊、宝藏和联动说明。备战、背包、图鉴、商城及共用战斗详情都经由 `FinalStatusCatalog.gd` 或 `PetService.gd` 读取它。

修改 Excel 后，在项目根目录运行：

```powershell
python tools/export_final_status.py
python tools/export_final_status.py --check
```

提交时同时提交 Excel 与 JSON。Game 数据表与服务端仍负责实际属性、价格、伤害和结算；每次改数值都要更新这些运行源并验证与本表一致。账号商城的最终售价以服务端目录为准，表内是本地配置快照。线上服务端源码不在当前仓库，本机对齐不代表线上已部署。

本次根据用户审定订正了三个冲突：灵族是双毒与中毒期间 30% 减疗，不使用旧表克隆羁绊；凤凰涅槃以 40% 最大生命复活；赌博胜利结算以现行的 2.5 倍为准。原始 2026-10-08 工作簿保留作为来源记录，`final status.xlsx` 为后续定稿。

检验入口：`tools/final_status_check.tscn`、`tools/synergy_bond_check.tscn`、`tools/pet_feature_check.tscn`、`tools/codex_four_star_check.tscn`。测试在本机 Godot 4.7 运行；联机实战仍需服务端版本的逐项验证。
