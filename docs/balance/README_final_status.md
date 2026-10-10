# final status 数值发布流程

`docs/balance/final status.xlsx` 与同步工具都在 Git 仓库内，团队成员拉取同一提交即可使用。游戏和专服读取仓库内生成的 JSON，不在运行时打开 Excel。线上部署仍需发布同一提交的客户端、专服和账号后端。

## 字段归属

| 对象 | 在 Excel 中编辑 | 对应运行 JSON |
| --- | --- | --- |
| 棋子 | `01_棋子基础` G/K/O：1★ HP/攻击/防御 | `data/units/race_units.json` 的 `hp/atk/def` |
| 黑龙黑洞 | `02_棋子技能` O11/P11：1–3★/4★伤害百分比，填 `160` 表示 160% | `data/units/race_units.json` 的 `dark_dragon.damage_atk_pct` / `star4.damage_atk_pct` |
| 野怪 | `05_野怪` E/F/G：基础 HP/攻击/防御 | `data/pve/pve_monsters.json` 的 `hp/atk/def` |
| Boss | `06_Boss` D/E/O：首场 HP/攻击/R5 防御 | `data/boss/bosses.json` 的 `hp/atk/def` |
| 法阵友军 | `08_法阵友军` E/F/G：HP/攻击/防御 | `data/formation/formation_allies.json` 的 `hp/atk/def` |
| 宠物 | `03_宠物与商城` E：效果百分比 | `data/pets/pets.json` 的 `value` |
| 黄金祭坛 | `09_宝藏与套装` E23：每次扣除的法阵 HP | `data/treasure/treasures.json` 的 `hp_cost` |

Boss 的 JSON 保存战斗前整数基础值，入场时 HP/攻击/防御乘 1.5。工具会反算并拒绝无法从整数基础值产生的输入。棋子 2–4★ 与 Boss 后续回合列为 Excel 公式，游戏显示目录也按当前基础值重新计算。死侍各星攻击固定为 1。改宠物 E 列时还要更新 F、N 两列百分比文案；工具会拒绝不一致的描述。

上述字段只在业务页编辑。黑龙伤害倍率只改 O11/P11，填普通数字 `160` 或 `320`，不要输入 Excel 百分比格式的 `160%`；G/H/I/L/M11 文案和参数说明由公式自动跟随。保存 Excel 后运行工具，游戏实际技能伤害也会更新。1–3★共用 O11，4★使用 P11。K11 是旧倍率的实测记录，不代表修改后的伤害。除这一项以外，技能、成长系数、羁绊机制及其他复杂配置继续在对应 JSON / GDScript 中维护；同步工具不会覆盖这些字段。`90_运行配置` 是最初运行配置的历史快照，现不参与同步。`92_代码参数` 保留硬编码参数校验；更改其所列规则时须同步更新代码与表格。`93_商城目录` 是商城 JSON 的审阅页，须与 `data/shop.json` 保持一致。

## 本机启动

保存并关闭 Excel 后，双击 `tools/run_with_final.cmd`。窗口会列出同步结果，按提示查看后关闭。工具会在 Windows 桌面自动寻找唯一的 Godot 控制台程序。若有多个 Godot，设置 `GODOT_BIN` 环境变量指向要用的程序。每位同事从同一 Git 提交拉取 Excel、工具、JSON 和游戏代码后，可使用同一启动方式。需要先安装 Python 和 `openpyxl`。

也可从项目根目录手动运行：

```powershell
python tools/run_with_final.py --godot "C:\path\to\Godot.exe"
# 若要打开编辑器：
python tools/run_with_final.py --editor --godot "C:\path\to\Godot.exe"
```

工具先验证 ID、数值范围和宠物文案，列出 Excel → JSON 的字段差异，只写发生变化的运行 JSON，再生成显示目录并运行 `--check`，成功后启动 Godot。校验失败时不会启动。也可单独运行：

```powershell
python tools/export_final_status.py --apply-runtime
python tools/export_final_status.py --check
python tools/test_final_runtime.py
```

直接按已打开的 Godot 编辑器的 F5 不会自动执行外部 Python 工具；每次保存 Excel 后先重新运行双击工具或上述同步命令，再按 F5。团队提交时一并提交 Excel、发生变化的 JSON 和相关代码。CI 的 `Final status consistency` 会检查未同步的 Excel 数值及显示目录。专服打包也会运行 `--check`。黄金祭坛以外的宝藏机制、修女技能范围等复杂规则仍按 JSON 和 GDScript 一起审定，不能只改 Excel 文案。

## 联机版本

显示内容、运行 JSON 与已登记代码参数共同生成 `balance_version`。客户端与 Godot 专服联机握手时比较版本，不同则拒绝连接；账号商城的 `/v1/shop` 返回其版本，客户端可提示差异。发布后核对三端版本，并用线上实战验证。仓库中的文件只能证明本地或该提交的配置，不能证明线上已经部署同一版本。

本次已审定：灵族 1 为双毒、灵族 2 为中毒期间 30% 减疗；凤凰涅槃以 40% 最大生命复活；赌博获胜为 2.5 倍。旧表中的克隆羁绊不用于当前游戏。
