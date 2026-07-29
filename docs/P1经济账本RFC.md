# P1 服务端权威经济账本 RFC（设计稿，未实现）

> 状态：**待审**。本文只定方案，不含代码。
> 第四节是**需要你拍板的清单**，其余是设计。
>
> 配套：`docs/联机审计与整改方案.md`（A5 / A10 / C1 / C2 / C6 / C18）、`docs/状态信封RFC.md`

---

## 一、为什么不能只补三个按钮

最容易想到的做法是"给宝物刷新、黄金祭坛、慷慨命运各补一个扣款 RPC"。**这条路走不通**，
因为金币的入口远不止这三个。

只修三个按钮之后，改客户端的人**仍然可以**：
- 直接改存档里的 `gold`
- 白嫖买单位（客户端自己扣钱，服务器不知道）
- 重复出售同一个单位刷钱
- 提交一个没有任何购买记录的高星阵容

所以最小可信边界必须**同时**包含：金币、商店 offer、单位 UID 与来源、实际投入成本、
宝物归属、幂等回执。少一样，整套就漏。

---

## 二、现状：八条改金币的路径（代码实证）

`grep GameState.gold` 的结果，每一条都是客户端自己算完直接改：

| # | 路径 | 位置 | 现在怎么做 |
|---|---|---|---|
| 1 | 买单位 / 合成 | `PrepBoardController.gd:295–336`（4 处） | `GameState.gold -= cost` |
| 2 | 买佣兵 | `PrepBoardController.gd:206–208` | `GameState.gold -= cost` |
| 3 | 出售单位 | `PrepBoardController.gd:508, 520` | `GameState.gold += refund` |
| 4 | 商店刷新 | `PrepBoardController.gd:698–700` | `GameState.gold -= cost` |
| 5 | 宝物刷新 | `PrepFlowController.gd:79–81` | `GameState.gold -= cost` |
| 6 | 黄金祭坛 | `PrepFlowController.gd:177–178` | **已是 intent**，服务端授权后客户端加钱 |
| 7 | 慷慨命运赌博 | `PrepFlowController.gd:187–195` | 客户端跑 `randf()` 自己开奖 |
| 8 | 战后结算 | `Main.gd:543` | 本地 fallback；专服路径由服务端算 |

**只有第 6 条已经服务端权威**（而且还缺持有权校验，见 C1）。

服务端唯一的权威金币是 `room.slot_gold[]`，它只在战后结算时更新 ——
备战期发生的一切它都不知道。这就是 `shadow gold_delta` 那条影子日志的由来。

---

## 三、代码里可验证的现有规则（设计输入）

这些是我从代码里读出来的**当前实际行为**，不是提案。设计以它们为基准。

| 规则 | 实际实现 | 位置 |
|---|---|---|
| 商店刷新 | 每回合**第一次免费**，之后 `escalating_unit_price(次数)` 翻倍递增 | `EconomyService.shop_refresh_cost` |
| 宝物刷新 | `50 / 100 / 200 / 400`，之后持续翻倍，无上限 | `TreasureService.REFRESH_COSTS` |
| 4 Money 套装 | 商店刷新与宝物刷新**都免费**（两处都传 `money_set_active`/`all_free`） | 同上两处 |
| 宝物持有上限 | `MAX_OWNED = 5` | `TreasureService` |
| 黄金祭坛 | `-1` 水晶血量 → `+50` 金；每回合 3 次；血量 > 10 才能用 | `NetworkService.ALTAR_*` |
| 慷慨命运 | 50% 翻倍 / 50% 保留 20%；诡诈命运联动 → 60% / 保留 50%；**每回合一次** | `PrepFlowController:187–195`、`GameState.reset_shop_refreshes` |
| 出售退款 | `floor(def.cost × star × 0.5)` | `PrepBoardController._sell_refund_for_cell` |
| 金币上限 | **不存在**。代码里没有任何 clamp | — |

---

## 四、⛔ 需要你拍板的清单

这一节是这份文档的目的。**每一条都会改变玩家实际体验或数值**，我不该替你定。

### 4.1 出售退款按什么算？

现在是 `floor(def.cost × star × 0.5)` —— 按**当前定价表**算，不是按你实际花了多少。

**实测有正收益，但很小。** 数据表里只有一个单位带 `shop_cost_multiplier`：
`undead_small`（`cost = 10`，倍率 `0.5`）。

| 买入方式 | 买入价 | 1 星退款 | 单笔净收益 |
|---|---:|---:|---:|
| 无折扣 | 5 | 5 | **±0**（打平） |
| `money_discount`（×0.8） | 4 | 5 | **+1** |
| `clearance_sale` 联动（×0.6） | 3 | 5 | **+2** |

合成 2 星更明显（`STAR_UPGRADE_COPIES = {1: 2}`）：
`clearance` 买 2 个 = 6 金 → 合成 2 星 → 退款 `floor(10 × 2 × 0.5) = 10` → **净 +4**。

**不是"无限刷钱"**：每个商店格子只能买一次（`shop_sold`），要再买必须刷新，
而刷新每回合只有第一次免费、之后 `10/20/40/80…` 翻倍。所以每回合的净收益上限
就是"免费那次刷新里出现几个 `undead_small`"，量级是几金。

> ⚠️ 本节初稿写成"差价白赚、可以反复刷"，是夸大。实测后已改正。

**真正的问题不是这几金，是规则的形状**：退款口径与买入口径不一致。
现在只有一个低倍率单位、两个折扣来源，所以收益很小；
**再加一个低倍率单位或更强的折扣，收益就会放大，而且不会有人注意到。**

| 选项 | 后果 |
|---|---|
| **A. 改成按实际投入退款**（`cost_basis`） | 口径一致，以后加数值不会再冒出这类洞。合成单位的 `cost_basis` = 被合成单位投入之和。**这也正是账本本来就要记的字段** |
| **B. 保持现状** | 洞很小，但账本会记录一个自己有洞的规则 |

**我建议 A** —— 主要理由不是堵这几金，而是 `cost_basis` 本来就是账本的必需字段
（没有它就无法判断"这个单位是不是买过、花了多少"），顺手把口径统一了。

但它会让"折扣宝物 + 出售"的收益下降，属于**数值改动**，需要你确认。

### 4.2 ~~黄金祭坛 UI 显示 `+5` 而实际给 `+50`~~ ✅ 已确认是 UI 写错，已修

`PrepUI.gd` 硬编码了 `5`，而 `ALTAR_GOLD = 50` —— 玩家看到的和拿到的差一个数量级。
已改成读常量（`NetworkService.ALTAR_GOLD`），以后调数值不会再漏改这一处。

### 4.3 要不要给金币加上限？

代码里**没有任何上限**。审计文档提过 `99,999`，但那是提案不是现状。

加上限的理由：翻倍类效果（赌博、刷新费用递增）在极端情况下会溢出成负数。
不加的理由：玩家攒不到那个数，属于假想问题。

**问**：加吗？加多少？如果加，所有加减金币的路径都要做饱和运算（不是简单 clamp
一次，中间步骤也不能溢出）。

### 4.4 慷慨命运的随机由谁开奖？

现在是客户端 `randf()`。改成服务端开奖之后：

- 服务端算出结果 → 写进不可变回执 → 回给客户端
- ACK 丢了、重连、重复点击，都**只重放同一个回执，绝不重新开奖**

**问**：确认这个语义吗？（我认为必须这样，否则玩家可以断线重连刷到好结果）

### 4.5 账本要不要覆盖单机 / 教学？

单机没有作弊动机（改自己的存档不影响别人），而双路径（联机走 receipt、单机走本地）
是维护成本的主要来源 —— 现在已经有一批 `if NetworkService.team_active` 分支了。

**我建议：账本只覆盖联机，单机/教学保持现有本地路径。**

代价：每个交易都要写两遍逻辑；好处：单机不受任何网络延迟影响。

**问**：同意吗？

### 4.6 联机宝物刷新在账本做完之前，保留还是关闭？

审计文档在这一条上**前后矛盾过**：早期写"暂时禁用"，后来改成"始终保留"。

现状：客户端自己扣钱、服务端只重摇候选。**改客户端就能无限免费刷新**
（但只能从服务器发的候选里选，拿不到没被 offer 过的宝物）。

| 选项 | 后果 |
|---|---|
| **保留** | 免费刷新的洞继续存在到账本完成 |
| **关闭** | 联机玩家只能从最初 3 个候选里选，直到账本完成 |

**我建议保留** —— 洞的危害是"多刷几次"，不是"拿到不该有的东西"；而关掉是实打实删功能。

**问**：同意吗？

### 4.7 分阶段的切分点

账本很大。我建议按**"谁能凭空造钱"**排序，而不是按功能模块：

| 阶段 | 内容 | 堵住什么 |
|---|---|---|
| **L1** | 金币本身权威化：`room.prep[slot].gold` 成为唯一真相；战后结算只读账本，不读 `snapshot.gold` | 改存档直接改钱 |
| **L2** | 商店 offer 服务端生成 + `offer_id`；购买/合成/出售走 intent，服务端记 `unit_uid` 和 `cost_basis` | 白嫖单位、重复出售、无来源高星阵容 |
| **L3** | 刷新 / 祭坛 / 赌博走 intent + 幂等回执 | 免费刷新、重复开奖 |
| **L4** | 客户端切成 receipt-only（不再预改任何金币） | 显示与实际脱节 |

**注意 L4 必须和 L1–L3 一起发布**，不能只切一半 —— 客户端不预扣但服务端还没扣，
就是所有东西免费。

**问**：认可这个切分吗？还是你希望先做某个具体的洞？

### 4.8 4 Money 套装的免费范围

代码里 4 Money 让**商店刷新和宝物刷新都免费**。审计文档还提到"不影响队友"。

**问**：确认"只对本人免费、不影响队友、不影响购买价格"吗？

---

## 五、数据结构

```text
room.prep[slot] = {
    economy_revision : int      # 每笔经济变更 +1；客户端用它拒收迟到回执

    gold             : int
    shop : {
        offer_id     : String   # 本轮商店的唯一标识
        offers       : Array    # 服务端生成，含每格是否已售
        refresh_uses : int      # 本回合已刷新次数（费用递增依据）
    }
    roster : {                  # unit_uid -> 单位
        <uid> : {
            unit_id    : String
            star       : int
            cost_basis : int    # **实际投入**，不是定价表价格
            location   : String # board / bench
        }
    }
    owned_treasures : Array
    treasure_offer  : { offer_id, candidates, refresh_index }
    altar_uses      : int
    gamble_used     : bool

    receipts        : Dictionary   # request_id -> receipt
    request_high_water : int
}
```

**`cost_basis` 是整个设计的关键字段**：出售退款、合成成本、套利防护全靠它。
合成时新单位的 `cost_basis` = 被合成单位的 `cost_basis` 之和。

---

## 六、intent / receipt

客户端**只发意图**，不发"我该扣多少钱"、"我有 4 Money"、"随机结果是什么"、
"扣完之后我有多少钱"。

```text
intent = {
    request_id                : String   # room + match + slot 作用域，单调递增
    match_epoch, round_id     : int      # 与状态信封一致
    expected_economy_revision : int
    action                    : String   # buy / merge / sell / shop_refresh /
                                         # treasure_choice / treasure_refresh /
                                         # altar / gamble
    payload                   : Dictionary
}

receipt = {
    request_id, action_fingerprint : String
    status                         : String   # ok / rejected
    error                          : String
    gold_before, delta, gold_after : int
    resulting_revision             : int
    result                         : Dictionary  # 随机结果、新 uid、新候选等
}
```

### handler 顺序（**不能变**）

```text
1. 认证 sender / slot
2. 限制输入长度，算出 canonical fingerprint
3. ★ 先查 receipt / high-water / tombstone
4. 同 request_id 同内容 → 重放原 receipt
   同 request_id 异内容 → 拒绝并记录
5. 只有新请求才继续：检查 phase / round / revision / 余额 → 执行
```

**第 3 步必须在第 5 步之前。** 反过来的话，"执行成功但回执丢了"的重试，
会被新的 `economy_revision` 判成 stale 而拒绝 —— 玩家再也拿不回那个回执，
钱扣了东西没拿到。这是整个幂等设计里最容易写反的一处。

---

## 七、一个必须先解决的阶段问题

战后客户端已经进入备战/宝物界面时，**服务端可能还停在 `RESULT`**
（`round_index` 是惰性推进的，要等有人按准备才切 `PREP`）。

如果直接给经济 intent 加一个裸的 `phase == PREP` 门，**会误拒合法的第一笔宝物或祭坛请求**。

两个选择：

- **A（推荐）**：先把"战果已应用 → 下一轮权威 PREP → 开放商店/宝物/摆放"这个切换时点闭环，
  再只允许 canonical PREP 的经济 intent。这依赖状态信封的 `phase_revision`
- **B（过渡）**：允许跨 `RESULT`/`PREP`，但必须绑定明确的
  `match_epoch + round_id + economy_window_id + phase_revision`，**不能笼统放行 RESULT**

**这条也说明：账本应该排在状态信封之后。**

---

## 八、最低验收

- 同一 `request_id` 重放 100 次，只产生一次变更
- 同 ID 不同内容 → 拒绝
- ACK 丢失 / 断线发生在提交前 / 提交后
- 旧回合、旧 offer、乱序请求 → 零变更拒绝
- 0–3 Money 正常收费、4–5 Money 免费
- 祭坛：血量 10/11 边界、同队三人并发（不能把共享血量扣到 10 以下）
- 赌博：两组概率分支、奇数取整
- 购买一次 / 出售一次 / 合成来源 UID 正确
- 六个 slot 完全镜像、leader 无特权
- **无本地存档时，仅靠 resume 快照恢复，且不产生任何额外金币**

---

## 九、这份设计**不解决**什么

- **不解决传输与顺序** —— 那是状态信封（`docs/状态信封RFC.md`）
- **不解决单线程阻塞** —— B4
- **不解决 `race_relations`** —— C9 需要的是"跨回合玩家状态"，是另一套账
- **不提供 L2 证据** —— 实现完仍需独立进程真实 ENet 黑盒测试

---

*本文档随实现推进更新。*
