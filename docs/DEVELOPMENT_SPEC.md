# 《RaidDeck（暂定）》完整开发与交付规范文档

> **文档定位**：本文档面向多 Agent 协作开发与最终 Steam 买断制独立游戏交付，涵盖**最终成品规格、核心数值与机制公式、Godot 4 工程架构、数据表 Schema、美术与音频素材获取及风格一致性规范、测试与验收里程碑**。  
> **现有基础**：`d:\mygame` 已存在可运行的 MVP 原型（[project.godot](file:///d:/mygame/project.godot)），后续开发应在此基础上演进，**禁止推倒重写核心解耦思路**。

---

## 1. 最终成品规格（Final Deliverable Scope）

### 1.1 游戏定位
- **类型**：单机“MMO 副本开荒”小队卡牌构筑肉鸽（Party-based Raid Deckbuilder Roguelike）
- **引擎**：Godot 4.2+（GDScript，兼容标准版与 Steamworks 插件扩展）
- **核心卖点**：将 MMORPG 副本开荒的精髓（战法牧配合、仇恨/OT 控制、Boss 读条打断、DOT/HOT 维持、点名驱散、分摊与转阶段）浓缩为快节奏回合制卡牌肉鸽。

### 1.2 最终内容体量目标
| 模块 | MVP 现状 | 最终交付目标 |
| :--- | :--- | :--- |
| **可玩职业** | 3 职业固定（坦/输出/治疗） | **4 职业**（铁壁坦克、影刃输出、圣光治疗、奥术控场），每局上阵 3 人，支持首发阵容搭配 |
| **副本章节** | 3 场连续战斗 | **3 大章节**（地牢哨所 → 瘟疫回廊 → 暗影圣殿），每章 10 层分支节点地图 |
| **节点类型** | 纯战斗 | 普通战、精英战、营地（回血/升级卡牌）、神秘事件、副本商人（买遗物/删牌）、关底 Boss |
| **卡牌数量** | 12 张 | **90~120 张**（每职业 20~25 张 + 通用战术牌，每张牌支持 `+` 升级强化形态） |
| **遗物/光环** | 0 个 | **35+ 个**（含职业专属遗物与改变底层规则的 Boss 掉落遗物） |
| **敌人与 Boss** | 4 种敌人 | **18+ 种普通/精英怪 + 6 个机制 Boss**（含转阶段 P1→P2、召唤、点名、狂暴倒计时） |
| **局外与重玩** | 无 | 完整本地存档（自动保存每层进度）、图鉴系统、**秘境难度层数（1~10 层词缀挑战）** |

---

## 2. 核心玩法系统与精确数值规则

所有程序 Agent 必须严格按以下规则实现逻辑，避免出现边缘情况歧义。

### 2.1 战斗回合状态机
```text
BattleStart (触发开战遗物、初始化牌库与初始仇恨)
  └─> TurnStart (护盾清零[除非有保留遗物]、回复能量、抽牌、生成敌方意图、触发 TurnStart 遗物/Buff)
        └─> PlayerAction (玩家出牌；出牌后立即检查胜负)
              └─> TurnEnd (弃掉剩余手牌、触发 TurnEnd 遗物)
                    └─> EnemyAction (存活敌人按位置从左到右依次执行未被中断的意图)
                          └─> StatusTick (依次结算双方 Poison/Burn -> Regen -> Vulnerable/Weak 递减)
                                └─> CheckBattleEnd (全灭判定 -> 胜利/失败，否则 turn_number += 1 回到 TurnStart)
```

### 2.2 MMO 核心机制定义

1. **仇恨与 OT 系统（Threat / Aggro）**
   - **初始仇恨**：开战时坦克初始仇恨为 `10`，其余职业为 `0`。
   - **仇恨产生**：
     - 造成伤害：`threat += round(actual_or_raw_damage * card.threat_mult)`（默认坦克技能 `1.5~2.0`，输出技能 `1.0`）。
     - 产生治疗：`threat += round(actual_healed * 0.4)`（过量治疗不计入仇恨）。
     - 嘲讽技能：直接设为 `当前全队存活最高仇恨 + bonus`（而非固定加值，确保必定拉回仇恨）。
   - **目标锁定规则**：敌方 `ATTACK_AGGRO` 锁定**存活我方中 `threat` 最高者**；若出现平局，按 `TANK > HEALER > DPS` 顺序优先。
   - **OT 惩罚与策略**：当输出或治疗仇恨超过坦克时，UI 立即将敌方连线/目标高亮切至脆皮单位并弹出 `[OT 警告]`。

2. **读条与打断系统（Cast & Interrupt）**
   - 敌方意图分为 3 级：
     - `NORMAL`：普通攻击/小技能（不可打断）。
     - `CAST_INTERRUPTIBLE`：危险读条技能（如毁灭打击、全体毒雾），带有明确黄色/紫色读条边框，可被带 `interrupt` 效果的卡牌打断。
     - `CAST_UNINTERRUPTIBLE`：Boss 终极机制（不可打断，只能靠护盾、减伤、驱散或分摊处理）。
   - **打断收益**：打断成功后，该敌人本回合跳过行动；Boss 类敌人可配置 `interrupt_resist`（被连续打断后下一次免疫打断 1 次，防止无限白嫖）。

3. **点名、分摊与驱散（Raid Mechanics）**
   - **定时炸弹（Bomb Debuff）**：挂在某队员身上，倒计时 `2` 回合，归零时对**全队**造成爆发伤害；可被治疗位的【净化术】驱散。
   - **分摊点名（Soak）**：Boss 锁定 1 名目标，下回合造成高额伤害（如 `36`），由**该目标及其相邻存活队友**平摊伤害（如 3 人存活每人仅受 `12` 伤，1 人阵亡则压力剧增）。
   - **Boss 阶段转换（Phase Transition）**：Boss 血量首次跌破 `50%` 时立即触发转阶段：清除自身负面/或刷新护盾、召唤随从、并切换至 P2 意图池（如开启 `5 回合狂暴倒计时`）。

4. **伤害计算管线（Damage Pipeline）**
   按固定顺序计算，最终结果向下取整（`floor`），最低为 `0`：
   ```text
   damage = base_damage + attacker_strength
   damage = damage * (0.75 if attacker.weak > 0 else 1.0)
   damage = damage * (1.50 if target.vulnerable > 0 else 1.0)
   damage = damage * relic_damage_multipliers
   final_damage = max(0, int(floor(damage)))
   ```
   扣血顺序：**优先扣除 `target.shield`，剩余伤害扣除 `target.hp`**。

---

## 3. 技术架构与代码规范（Godot 4）

### 3.1 核心原则：Headless Core + Thin Client
严禁将战斗逻辑写进 `Control` / `Node` UI 脚本中。所有核心系统必须可在无界面环境下通过命令行单元测试直接运行。

### 3.2 目录结构规范
```text
d:\mygame\
├── project.godot
├── data\                         # 纯数据驱动配置表（JSON）
│   ├── cards.json
│   ├── relics.json
│   ├── enemies.json
│   ├── encounters.json
│   └── events.json
├── assets\                       # 所有美术与音频资源（严禁散落根目录）
│   ├── sprites\
│   │   ├── units\                # 角色与怪物像素图/序列帧
│   │   ├── icons\                # 统一风格的技能/Buff/遗物图标
│   │   └── backgrounds\          # 副本章节背景
│   ├── ui\                       # NinePatchRect 边框、按钮、卡牌框
│   ├── fonts\                    # 统一字体文件
│   └── audio\                    # BGM 与 SFX
├── scripts\
│   ├── core\                     # 纯逻辑层（extends RefCounted，禁止引用 SceneTree）
│   │   ├── enums.gd
│   │   ├── models.gd
│   │   ├── event_bus.gd          # 战斗生命周期事件总线（遗物/被动监听）
│   │   ├── action_queue.gd       # 演出指令队列（Logic -> UI 桥梁）
│   │   ├── battle_engine.gd      # 战斗结算引擎
│   │   ├── map_generator.gd      # 分支节点地图生成器（Slay the Spire 式有向无环图）
│   │   ├── run_manager.gd        # 单局流程管理（地图、金币、卡组、遗物、难度词缀）
│   │   └── save_manager.gd       # JSON 持久化存档（user://save_run.json, user://meta.json）
│   ├── data\
│   │   └── data_loader.gd        # 读取并校验 data/*.json
│   └── ui\                       # 表现层（只消费 ActionQueue 与渲染 State）
│       ├── main.gd
│       ├── battle_view.gd        # 战场、飘字、受击闪白、Tween 动画播放器
│       ├── map_view.gd           # 章节路线图界面
│       ├── shop_view.gd          # 商人/营地/事件界面
│       └── components\           # 卡牌控件、单位血条控件、Tooltip 悬浮窗
├── scenes\
│   └── ...
└── tests\                        # 自动化测试（GUT 或 headless GDScript）
    └── test_battle_sim.gd        # 1000 次自动随机出牌压测，验证无崩溃与死锁
```

### 3.3 从 MVP 升级到正式版的 3 个关键重构

1. **引入 `EventBus`（支持 35+ 遗物与复杂被动）**
   - 定义标准上下文对象 `BattleContext`（包含 `source`, `target`, `card`, `amount`, `cancelled` 等字段）。
   - 钩子列表：`on_battle_start`, `on_turn_start`, `on_card_played`, `on_calculate_damage`, `on_after_damage`, `on_interrupt_success`, `on_dispel_success`, `on_unit_death`, `on_turn_end`。
   - 所有遗物继承基类 `RelicBase`，只需覆写对应钩子即可生效，避免在 `BattleEngine` 里写 `if has_relic("xxx")` 的面条代码。

2. **引入 `ActionQueue`（逻辑与演出动画彻底解耦）**
   - `BattleEngine.play_card()` 同步瞬间算完所有数值变化，并往 `ActionQueue` 推入结构化演出指令：
     ```gdscript
     {"type": "CARD_PLAY", "card_id": "shield_bash"}
     {"type": "DAMAGE", "target_id": "boss", "amount": 6, "is_crit": false}
     {"type": "INTERRUPT", "target_id": "boss"}
     {"type": "THREAT_CHANGE", "unit_id": "tank", "new_threat": 26}
     ```
   - `battle_view.gd` 使用 `await` 顺序消费指令队列：播卡牌飞出 → 怪物闪白震动 + 飘字 → 播放打断音效 → 刷新血条。播放期间锁定玩家出牌输入，防止并发状态错乱。

3. **数据表 Schema 规范（以 `data/cards.json` 为例）**
   ```json
   {
     "shield_bash": {
       "title": "盾牌猛击",
       "cost": 1,
       "role": "TANK",
       "target": "ENEMY",
       "rarity": "COMMON",
       "description": "造成 {val0} 点伤害，产生 {threat} 仇恨；若目标正在读条，则打断它！",
       "effects": [
         {"op": "damage", "val": 6, "threat_mult": 1.6},
         {"op": "interrupt"}
       ],
       "upgrade": {
         "title": "盾牌猛击+",
         "effects": [
           {"op": "damage", "val": 10, "threat_mult": 2.0},
           {"op": "interrupt"}
         ]
       }
     }
   }
   ```

---

## 4. 美术风格、素材获取与一致性规范

个人/小团队最忌讳“淘宝拼凑感”。必须严格执行**单一美术风格 + 锁定调色板 + 统一 UI 框架**。

### 4.1 推荐视觉风格：**暗黑奇幻像素风（Dark Fantasy Pixel Art）**
- **原因**：像素风在 itch.io / CraftPix 上拥有最海量的成套商用/免费资源，且分辨率低（16×16 / 32×32），修改和补画成本极低。

### 4.2 推荐素材获取清单（可直接搜索获取）
| 资产类别 | 推荐具体素材包 / 来源 | 使用说明 |
| :--- | :--- | :--- |
| **技能/卡牌/遗物图标** | itch.io 搜索：**Shikashi's Fantasy Icons Pack** 或 **Kyrise's 16x16 RPG Icon Pack** 或 **Raven Fantasy Icons** | **铁律：全游戏所有图标必须出自同一套包**，确保描边粗细和光影方向一致 |
| **角色与怪物精灵** | itch.io 搜索：**0x72 DungeonTileset II**、**Elthen's Pixel Art**、**Szadi art (Dark Fantasy)** | 选用含 `Idle` + `Hit` + `Attack` 2~4 帧即可，无需复杂骨骼动画 |
| **UI 框体与按钮** | **Kenney.nl (UI Pack: RPG Expansion)** 或 itch.io **Fantasy Pixel UI** | 导出为 PNG 后在 Godot 中全部使用 **`NinePatchRect`** 制作自适应卡牌框、面板和血条 |
| **背景氛围图** | itch.io 搜索 **Pixel Art Dungeon Background**（深色低饱和度） | 背景必须做暗化（叠加 `rgba(10, 12, 18, 0.65)` 遮罩），绝不能抢走卡牌和血条的视觉焦点 |
| **中文字体** | **Fusion Pixel Font（融合像素字体）** 或 **思源黑体 (Noto Sans SC)**（SIL OFL 1.1 开源可商用） | 标题/数字可用像素字体，卡牌长段描述建议用清晰无衬线体（小字号像素中文易糊） |
| **音效（SFX/BGM）** | **Freesound.org (筛选 CC0)**、**Kenney RPG Audio**、**JSFXR** | 至少配齐 8 个核心音效：出牌、格挡、重击、治疗、读条警报、打断成功、OT 警报、胜利/失败 |

### 4.3 风格一致性强制规范（Style Guide）
1. **调色板锁定（Palette Lock）**：
   - 背景底色：`#14161F`（深石板蓝灰）
   - 面板底色：`#1F2330`，边框高亮：`#4A5168`
   - 主文字：`#EAE4D3`（暖羊皮纸白，避免刺眼纯白 `#FFFFFF`）
   - 职业主题色（用于卡牌边框顶部条与职业标识）：
     - 坦克（TANK）：钢蓝 `#3B82F6`
     - 输出（DPS）：绯红 `#EF4444`
     - 治疗（HEALER）：圣翠 `#10B981`
     - 奥术（ARCANE）：秘紫 `#A855F7`
   - 警告色：可打断读条 `#F59E0B`（琥珀金闪烁），OT 危险警报 `#DC2626`。
2. **像素渲染规则**：
   - 在 Godot `Project Settings -> Rendering -> Textures -> Canvas Textures -> Default Texture Filter` 设为 **`Nearest`**，严禁像素图开启 `Linear` 模糊。
   - 所有图标保持整数倍缩放（如 16×16 放大为 32×32 或 48×48），禁止出现 1.37 倍这种非整数倍缩放导致的像素畸变。
3. **禁止事项**：
   - 严禁在同一界面混用“AI 生成的高清写实立绘”和“16×16 像素图标”。如果部分 Boss 需要 AI 辅助补图，必须经过降采样 + 统一 32 色调色板量化（如 Aseprite / Python Pillow）+ 统一 1px 深色外描边处理。

---

## 5. 多 Agent 协作开发里程碑（Roadmap）

建议按以下 4 个阶段拆解任务派发给开发 Agent，每阶段结束必须通过对应验收标准：

### Phase 1：架构升级与无头测试（Core Engineering）
- **任务**：
  1. 将 `card_db.gd` 与 `enemies` 迁移至 `data/*.json` + `data_loader.gd`。
  2. 实现 `event_bus.gd` 与 `action_queue.gd`，重构 `battle_engine.gd`。
  3. 编写 `tests/test_battle_sim.gd`，用无头模式自动跑 1000 场随机出牌战斗。
- **验收标准**：`godot --headless --script tests/test_battle_sim.gd` 0 报错通过。

### Phase 2：完整局内循环与 MMO 机制（Gameplay Complete）
- **任务**：
  1. 实现 `map_generator.gd` 与 `map_view.gd`（10 层分支路线，含战斗/精英/营地/商店/事件/Boss）。
  2. 补齐点名炸弹、分摊（Soak）、Boss P1→P2 转阶段机制。
  3. 扩充至 40 张卡牌 + 15 个遗物 + 10 种敌人，接入 `save_manager.gd` 局内自动存档。
- **验收标准**：能从主菜单开局，打通 1 个完整 10 层章节并在中途退出后读档恢复。

### Phase 3：美术、动效与音频接入（Polish & Juice）
- **任务**：
  1. 导入选定的像素图标包与 `NinePatchRect` UI 边框，替换所有临时 `Button` 占位符。
  2. 实现 `battle_view.gd` 演出：出牌悬停放大、目标连线指示器（敌方意图指向最高仇恨）、受击闪白（Shader/Modulate）、伤害飘字与屏幕微震。
  3. 接入 `AudioStreamPlayer` 池，配置全部核心 SFX 与章节 BGM。
- **验收标准**：关闭所有文字日志仅靠视觉与音效反馈，能清晰看懂谁在 OT、Boss 在读什么条、打断是否成功。

### Phase 4：全量内容与数值平衡（Production Ready）
- **任务**：
  1. 扩充至 3 大章节、4 职业、100+ 卡牌（含升级 `+`）、35+ 遗物、秘境难度词缀（1~10 层）。
  2. 补齐图鉴、统计面板、设置菜单（分辨率/音量/快捷键）、多分辨率适配。
  3. 运行自动化数值模拟脚本统计各职业胜率与平均通关回合数，调优卡牌费用与 Boss 血量曲线。
- **验收标准**：全流程无卡死 Bug，可打包导出 Windows 可执行文件（`.exe` + `.pck`）直接分发试玩。
