# final status 数值发布流程

final status.xlsx 是后续数值与文案变更的编辑源。它保留原有 16 页，增加：

- 90_运行配置：14 份客户端、Godot 专服和账号商城使用的 JSON 配置，按路径与类型逐项存放。
- 91_来源清单：纳入的文件及初始快照哈希。
- 92_代码参数：目前纳入的 8 项 GDScript/Python 固定数值，发布检查会核对代码实际值。
- 93_商城目录：全部商城商品、名称、货币和售价，包括新头像框。头像框目录也已纳入机器配置；普通商店头像框名称会与目录交叉校验。

棋子、宠物、羁绊、宝藏等中文显示经 data/balance/final_status.json 和 FinalStatusCatalog.gd 进入备战、背包、图鉴、商城及共用详情。局内战斗和专服使用同一批工作簿生成的运行 JSON；账号商城使用其中的 shop.json、pets.json 等文件。动态战斗状态、玩家资产与服务器成交价仍由权威运行服务计算，界面不能自行改写。

## 改数值

1. 先改工作簿的业务页和对应的 90_运行配置 值；两处重叠字段必须一致。修改代码固定参数时先改 92_代码参数，随后在批准的玩法改动中改代码。
2. 在项目根目录执行：

   python tools/export_final_status.py --apply-runtime
   python tools/export_final_status.py --check
   python tools/test_final_runtime.py

3. 运行受影响的 Godot 检查；至少运行 tools/final_status_check.tscn。涉及联机协议或数值版本时运行 tools/network_transport_check.tscn 与 tools/handshake_check.tscn 的 ok、balance 两个场景。
4. 在同一个提交中放入 Excel、生成的 JSON、相应代码和验证记录。CI 的 Final status consistency 会拒绝表格、运行 JSON 和已纳入的代码参数不一致的提交。使用 tools/make_server_bundle.py 制作专服源码包时也会先执行 --check。

--check 不改文件。默认导出只写显示目录；有数值修改时必须使用 --apply-runtime，才能同步运行配置。导出器会拒绝业务页与机器页不一致的工作簿。现有 14 份 JSON 的其他字段在 90_运行配置 中完整保留，不能只改运行 JSON 绕过工作簿。

## 三端版本核对

导出器按显示内容、运行配置和代码参数生成 balance_version。客户端与 Godot 专服在联机握手时比较该值；不一致的连接会被拒绝并在服务端日志注明双方版本。账号商城的 /v1/shop 响应携带其 balance_version；商城界面发现与客户端不同会提示。专服构建清单也记录该值。

这项握手变更需要客户端与专服协调发布：旧客户端没有数值版本字段，连接新版专服会被拒绝。账号后端首次安装与更新脚本会复制工作簿生成的商城目录和 final_status.json。发布完成后，核对客户端启动日志、专服启动日志和 /v1/shop 返回的版本完全相同，再进行线上实战验证。仓库内存在专服与账号后端源码，但仅凭本机代码不能证明线上已部署相同提交。

本次已审定：灵族 1 为双毒、灵族 2 为中毒期间 30% 减疗；凤凰涅槃以 40% 最大生命复活；赌博获胜为 2.5 倍。旧表中的克隆羁绊不用于当前游戏。
