# Glory Beta 0.04

Godot 4.7 自走棋 / 3v3 团队 PvP。同一份代码跑在 **Android、iOS、Windows / Steam、无界面战斗服务器** 四个平台。

## 先读这些

- **[AGENTS.md](AGENTS.md)** — 所有改动都要遵守的约定。改代码前先填开头的「平台影响表」，改完填「验证表」。
- **[docs/changelog/](docs/changelog/README.md)** — 更新日志，按月归档。以后的改动说明写到当月文件，**不要再写回这里**。
- `docs/` — 规则、数值、经济账本、资源交付（`docs/ASSET_DELIVERY.md`）等专题文档。
- [docs/项目概览_2026-09存档.md](docs/项目概览_2026-09存档.md) — 旧的项目说明，已过时，仅供追溯。

## 目录速览

| 目录 | 内容 |
|---|---|
| `scenes/` | 启动、主菜单、备战、战斗、房间；`debug/` 下是调试预览器 |
| `scripts/autoload/` | 全局服务：账号、网络、存档、本地化、语音等（即 `project.godot` 的 autoload 列表） |
| `scripts/battle/` | 纯规则的战斗模拟与回放 |
| `scripts/account/` | 原生登录 / 支付 / 语音插件的 GDScript 侧 —— 跨平台陷阱高发区，见 AGENTS.md |
| `scripts/multiplayer/` | 房间、协议、重连、回放传输 |
| `data/` | 单位、宝物、回合、Boss、佣兵等 JSON |
| `assets/`、`effects/`、`shaders/`、`ui/` | 运行时资源 |
| `tools/` | 门禁检查场景（`*_check.tscn`）、打包与资源脚本；`tools/git-hooks/` 是提交前钩子 |
| `deploy/` | 服务器部署脚本与发布记录 |
| `android/`、`android_plugins/`、`addons/` | 安卓构建模板、原生插件、编辑器插件 |

带 `.gdignore` 的目录（历史副本、备份、产物、日志）Godot 不扫描，不属于工程。

## 本地运行

1. Godot **4.7.x**（门禁和服务器包要用 console 版）。
2. 大资源不在 Git 里，按 `docs/ASSET_DELIVERY.md` 用 `tools/restore_assets.ps1` 恢复到 `assets/`。
3. 用编辑器打开 `project.godot`，主场景是 `scenes/bootstrap/Bootstrap.tscn`。
4. 克隆后启用提交前检查（每台机器一次）：`git config core.hooksPath tools/git-hooks`。

## 服务器环境

| 用途 | 测试服 | 正式服 |
|---|---|---|
| 账号接口 | `https://test-api.gogoglory.com` | `https://api.gogoglory.com` |
| 战斗（UDP + DTLS） | `test-battle.gogoglory.com:8080` | `battle.gogoglory.com:8080` |
| 语音 | `wss://test-voice.gogoglory.com` | `wss://voice.gogoglory.com` |

以 AGENTS.md「云服务器环境归属」为准；更新流程见 `deploy/README.md`。

## 门禁与打包

- 跑单个检查：`powershell -File tools/run_check.ps1 -Name <检查名>`；全部：`-All`。结果在 `reports/checks/`。
- 已知暂不修的失败登记在 `tools/check_allowlist.json`，**每条必须有到期日**，到期自动变红。
- 服务器包：`tools/make_server_zip.ps1` / `tools/make_server_bundle.py`。工作区有未提交改动时**默认拒绝打包**；只打测试服包可用 `-AllowDirty` / `--allow-dirty` 临时放行。
- 安卓测试包冒烟：`tools/android_smoke.sh`。
- 正式包仍由 Godot 编辑器导出：导出前先 `git status` 确认工作区干净，并把 commit 写进发布说明。
