# Action Trace Recorder

`Action Trace Recorder` 是一个独立的 `REFramework` 辅助工具，用来在游戏里自动记录你“实际打出来”的动作信息，并写成 `json` 文件。

这个工具的目标不是直接改招式，而是帮我们反查：

- 某个动作当下对应的 `motion id / bank`
- 当前行为树 `node id`
- 当前节点里挂了哪些 `action`
- 这些 `action` 对应的 `ActionIndex`
- 每个 `ActionIndex` 的类型名
- 每个 action 当前的 `_StartFrame / _EndFrame`
- 当前节点有哪些 `transition condition`
- 每个条件会跳去哪个 `state`
- 当前节点上挂了哪些 `transition event`

这对后面继续做 `Custom GP Frames` 很有帮助，因为我们可以先在游戏里把动作打出来，再回头分析候选 action。

## 项目结构

- [ActionTraceRecorder.lua](/home/alexqfmm/workPlace/mhrsAbout/Action%20Trace%20Recorder/reframework/autorun/ActionTraceRecorder.lua)
  实际运行的 REFramework 脚本。

## 中文显示说明

这个项目现在已经按 `Qurious Cheating.lua` 的思路补了东亚字体加载。

脚本会根据游戏当前显示语言，尝试加载这些字体文件：

- `NotoSansJP-Regular.otf`
- `NotoSansKR-Regular.otf`
- `NotoSansTC-Regular.otf`
- `NotoSansSC-Regular.otf`

其中简体中文对应的是：

- `NotoSansSC-Regular.otf`

如果你在游戏里打开 `Action Trace Recorder` 仍然看到中文乱码，通常不是脚本逻辑问题，而是运行环境里缺少对应字体文件，或者字体文件没有放在 `imgui.load_font(...)` 能读取到的位置。

## 这个工具会输出什么

脚本会把录制结果写到随机文件名，例如：

- `ActionTraceRecorder_20260506_163012_4821.json`

这样每次开始录制都会生成一份新的记录文件，不会反复覆盖同名文件。

另外，“整棵动作树导出”现在会写到按武器英文名区分的固定文件名，例如：

- `ActionTreeDump_LongSword.json`
- `ActionTreeDump_Lance.json`

这类文件默认会被同武器的下一次导出覆盖。

这样做的原因是：

- 同一武器的整棵动作树通常相对稳定
- 文件名改成英文后，更方便后面直接做脚本处理、比对和提交到仓库

输出内容大致包含：

- `recordedAt`
  记录时间
- `uptime`
  游戏运行时间
- `weaponType`
  武器类型编号
- `weaponName`
  武器名称
- `weaponNameEn`
  武器英文名称，主要用于稳定命名整树导出文件
- `motionId`
  当前动作 id
- `motionBank`
  当前动作 bank
- `motionFrame`
  当前动作帧
- `recentMotionIds`
  最近几次玩家触发过的 `MotionID` 历史
- `nodeId`
  当前行为树节点 id
- `nodeName`
  当前节点名称
- `actions`
  当前节点绑定的 action 列表

每个 `action` 又会包含：

- `index`
  ActionIndex
- `typeName`
  action 的类型全名
- `startFrame`
  当前 `_StartFrame`
- `endFrame`
  当前 `_EndFrame`
- `fields`
  当前 action 上扫描到的一些常见字段

另外现在每条记录还会额外带上：

- `transitions`
  当前节点的普通过渡列表
- `startTransitions`
  当前节点的起始过渡列表
- `focusConditions`
  当前记录里自动提炼出来的“重点 condition 线索”
- `focusedProbe`
  命中重点动作/重点 condition 时才会额外生成的重型深挖结果
- `lastHitEvent`
  最近一次命中事件的摘要

当录制过程中发生真正的玩家命中时，新版本还会额外插入一条：

- `recordTrigger = "hit"`

这种记录除了当前动作快照外，还会带：

- `hitEvent.attackDataName`
  命中判定对象的原始名字，通常最接近游戏里的“招式名”
- `hitEvent.damageDataName`
  伤害数据名字
- `hitEvent.damageType / damageAttackerType`
  伤害类型信息
- `hitEvent.totalDamage / physicalDamage / elementDamage / criticalResult`
  本次命中的结算摘要
- `hitEvent.recentMotionIds`
  这次命中发生前，最近一小段 MotionID 历史

每个 `transition` 条目里会包含：

- `slot`
  当前过渡在节点数组里的槽位
- `condition`
  对应 condition 的编号、类型名和部分可读字段
- `targetState`
  这个 condition 命中后跳去的 state
- `events`
  这条过渡挂着的 transition events

现在录制版 `transition` 里还会额外带上：

- `targetNode`
  这条过渡要跳去的目标节点摘要

`targetNode` 会尽量带出：

- `stateIndex`
  当前 transition 指向的状态索引
- `nodeId`
  目标节点 id
- `nodeName`
  目标节点完整名称
- `actionIndices`
  目标节点上挂着的 action index 列表
- `actionTypes`
  对应 action 的类型名
- `transitionCount`
  目标节点自己的 transitions 数量
- `startTransitionCount`
  目标节点自己的 startTransitions 数量
- `transitionPreview`
  目标节点下一层过渡的简要预览

`focusedProbe` 则是更激进的一层专项信息，主要用于：

- 已经知道目标动作范围后
- 想围绕这些动作一次性多挖一点底层线索时

它目前会尽量带出：

- `sourceNode`
  当前命中节点的完整深探针
- `focusConditionProbes`
  当前记录里命中的重点 condition 深探针
- `globalFocusedConditions`
  直接按 index 读取的全局重点 condition 对象
- `relatedNodes`
  这些重点 condition 实际跳去的关键节点深探针

另外，录制版 `action / condition / event` 现在除了原先的常见候选字段外，还会带：

- `scannedFields`
  通过反射额外扫描到的“可直接读出的简单字段”
- `scannedProperties`
  通过零参数 getter 额外扫到的简单属性
- `typeHierarchy`
  当前对象的类型继承链
- `fieldCatalog`
  这个对象有哪些 field、类型是什么、定义在哪一层
- `methodCatalog`
  这个对象有哪些 getter-like 或关键字命中的方法

这个字段的目标是帮我们尽量把：

- 帧段
- 判定开关
- 受击相关标志
- see through / damage / muteki / invincible 一类线索

直接保留下来，减少回头反复补录的次数。

这里特别要说明一下：

- 有些 condition 关键信息不在 field 上
- 它们可能藏在 `get_xxx()` 这种 getter 属性里

所以现在新版本会同时扫：

- field
- property getter
- type hierarchy
- field catalog
- method catalog

这样更适合深挖 `SeeThrough`、`Damage` 这类“字段表面看起来很空”的 condition。

### focusConditions 是干什么的

当录制器碰到我们当前重点盯的 condition 时，会自动把它们单独抽出来，放到：

- `focusConditions`

这一块目前默认重点关注的是：

- `6944`
  `snow.player.fsm.PlayerFsm2ConditionQuestBaseSeeThrough`
- `6981`
  `snow.player.fsm.PlayerFsm2ConditionQuestBaseDamage`
- `7026`
  `snow.player.fsm.PlayerFsm2ConditionLongSwordIaiAutoCounter`
- `7068 / 7069 / 7087 / 7088`
  `snow.player.fsm.PlayerFsm2ConditionLongSwordIaiCounterDerived`

每条 `focusConditions` 里会尽量带上：

- 它是从当前节点的哪条 transition 来的
- 它来自当前节点，还是某个 `targetNode.transitionPreview`
- condition 自己的 `fields / scannedFields / scannedProperties / typeHierarchy`
- 这条 condition 会跳去哪个 `targetState`
- 它前一跳和后一跳的大概上下文

这样你后面分析太刀见切、居合时，就不用先在整份 JSON 里肉眼翻所有 transition 了，先搜 `focusConditions` 即可。

## 命中招式名记录有什么用

现在录制器除了动作树侧的信息，还会在真正造成伤害时，额外记录：

- `AttackData:ToString()`

这一层通常会直接出现类似：

- `DummyHitShapeData(41_見切り斬り（成功）)`
- `DummyHitShapeData(63_居合気刃斬り（成功）)`

所以新版本更适合拿来做三层对照：

- 动作树节点名
- ActionIndex / Action 类型
- 实际命中招式名

后面要给某把武器做可配置 GP 时，这三层一起看会比只看动作树快很多。

如果你已经明确知道当前要追的是：

- `atk_147`
- `atk151`
- `motion 147 / 154 / 155 / 156`

那么现在更推荐直接看：

- `focusedProbe`

因为它会比 `focusConditions` 再多带一层：

- 当前节点完整 actions
- 当前节点完整 transitions
- 当前节点里命中的重点 action 深探针
- 全局重点 action 快捷探针
- 重点 condition 对象自身的成员目录
- 全局重点 condition 快捷探针
- 重点 condition 实际跳到的关键节点

现在对太刀居合专项，录制器还会额外重点盯这些 action：

- `9250`
  `snow.player.fsm.PlayerFsm2ActionSeeThroughAttack`
- `9388`
  `snow.player.fsm.PlayerFsm2ActionLongSwordEscapeMutekiTimerIaiCounterStep`
- `9393`
  `snow.player.fsm.PlayerFsm2ActionEscapeDamageCheck`
- `9460`
  `snow.player.fsm.PlayerFsm2ActionSeeThroughAttack`

并且会把这些节点名自动纳入重型深挖命中条件：

- `atk.atk151`
- `atk.atk_147`
- `atk.atk_161_MR`

## 工作方式

这个工具现在同时支持两类输出：

1. 动作轨迹录制
2. 当前武器整棵动作树导出

### 动作轨迹录制

默认按“动作变化”自动记录。

也就是说，当这些信息的组合发生变化时，它会写一条新记录：

- 当前武器类型
- 当前 `motion bank`
- 当前 `motion id`
- 当前 `node id`
- 当前节点上的 `action` 列表

这样做可以避免每帧都疯狂写文件，同时又能在你打出不同动作时留下轨迹。

现在的录制还会额外把“当前节点指向的下一层目标节点摘要”一起带上。

这对太刀见切、居合这类“成功 / 失败不是写在 action 里，而是写在 transition condition 里”的动作特别有用，因为你可以直接看到：

- 当前节点命中了什么 condition
- 这条 condition 会跳去哪个 target state
- target state 对应的目标 nodeName 是什么
- 目标节点自己还有哪些下一层转场

如果当前记录里正好出现了重点 condition，那么这次记录还会顺手把它们整理到 `focusConditions` 里，方便直接看结论。

如果当前记录本身就是重点动作节点，或者命中了重点 condition，还会再附带 `focusedProbe`，方便你做“一次性重挖”。

### 当前武器整棵动作树导出

你不一定每次都要靠“实际打动作”来找数据。

现在同一个工具里还带了一个按钮，可以直接把“当前装备武器的整棵动作树”暴力导出成 JSON，内容包括：

- 全部 actions
- 全部 conditions
- 全部 transition events
- 全部 nodes
- 每个 node 的 actions / transitions / startTransitions

这适合你想先全量看结构，再决定后面录制哪些动作时使用。

## 使用方式

1. 把 `Action Trace Recorder` 文件夹放进你游戏侧的 `REFramework` mod 目录。
2. 启动游戏。
3. 打开 `REFramework` UI。
4. 展开 `Action Trace Recorder`。
5. 点击 `开始录制`。
6. 在游戏里实际打出你想分析的动作。
7. 打完后点击 `停止录制`。
8. 查看这次新生成的 `ActionTraceRecorder_*.json`。

## 圆月专项排查

为了排查太刀圆月的创建、出圈和消失链路，现在工具里额外有两个圆月相关入口：

- `导出圆月专项 Dump`
  - 输出 `HarvestMoonDump_*.json`
  - 包含 `atk.WireReplaceF_MR.plw_LongSword_100_160` 节点、`9529/9530/9531` 等圆月创建/特效 action 深挖结果
  - 包含 `snow.player.LongSword`、`snow.shell.LongSwordShell010`、`snow.shell.LongSwordShellManager`、`snow.PlayerNetwork.LongSwordDestroySpacingShellPacket` 的字段/方法目录
- `记录圆月生命周期`
  - 默认开启
  - 在普通“开始录制”期间，把圆月相关事件追加到录制文件的 `harvestMoonEvents`
  - 目前会尝试捕获 `createSpacingShell`、`LongSwordShell010` 的创建/销毁候选方法，以及 `LongSwordDestroySpacingShellPacket` 的候选读写/发送方法

推荐排查流程：

1. 装备太刀，打开 `Action Trace Recorder`。
2. 确认 `记录圆月生命周期` 勾选。
3. 点 `开始录制`。
4. 释放圆月，走出圈，让圆月按原版逻辑消失。
5. 点 `停止录制`。
6. 把生成的 `ActionTraceRecorder_*.json` 里的 `harvestMoonEvents` 一起看。

如果出圈没有触发 `LongSwordShell010.destroy/onDisable/deactivate`，但出现了 `LongSwordDestroySpacingShellPacket` 且 `_IsOutSide=true`，后续圆月自动重开就应该优先 hook 这个包或对应 manager 逻辑，而不是继续猜 shell 销毁方法。

## 怪物目标专项排查

为了后续做“怪物切换仇恨时本机提示”，工具里现在加了怪物目标专项探针。第一轮只负责录数据，不会往聊天里发消息，也不会假定某个字段一定就是正式目标。

新增入口：

- `导出怪物目标专项 Dump`
  - 输出 `MonsterTargetTrace_*.json`
  - 包含 `EnemyManager` 当前运行时探针
  - 包含 `EnemyCharacterBase`、`EnemyTargetInfo`、`EnemyTargetParam`、`EnemyUpdateTarget`、`EnemyPredatorUpdateTarget`、`HateCore` 等相关类型的字段/方法目录
- `记录怪物目标采样`
  - 默认开启
  - 在普通“开始录制”期间，每约 `0.5s` 采样一次怪物目标候选值
  - 采样结果写入录制文件的 `monsterTargetSamples`
- `强制记录怪物目标`
  - 不等定时采样，立即追加一条当前怪物目标样本，适合看到怪物明显换目标时手动点一下

每条 `monsterTargetSamples` 会尽量记录：

- 当前本地玩家 index
- `EnemyManager` 上与 `target / hate / player / boss / unique / rank / point / lock / aim` 等关键词相关的简单字段和零参数 getter
- 从 `EnemyManager` 常见列表入口里找到的怪物对象
- 每个候选怪物对象的类型名、地址、继承链、关键词字段、关键词 getter、字段目录和方法目录

推荐排查流程：

1. 打开 `Action Trace Recorder`。
2. 确认 `记录怪物目标采样` 勾选。
3. 如果只想看仇恨数据，关闭 `记录武器动作` 和 `记录圆月生命周期`。
4. 点击 `开始录制`。
5. 单人或多人任务里让怪物攻击、转头、换目标。
6. 看到明显切目标时，可以点一次 `强制记录怪物目标`。
7. 点击 `停止录制`。
8. 查看生成的 `ActionTraceRecorder_*.json` 里的 `monsterTargetSamples`。
9. 需要静态目录和当前快照时，再点 `导出怪物目标专项 Dump`，查看 `MonsterTargetTrace_*.json`。

后续只有在样本里确认某个 getter/字段能稳定对应真实目标玩家后，才适合把它做成独立的 `Monster Target Alert` Mod，并通过本机聊天信息窗口提示，例如 `[仇恨] 怪物 -> P2`。

如果你想直接导出当前武器的完整动作树：

1. 进游戏并装备目标武器。
2. 打开 `REFramework` UI。
3. 展开 `Action Trace Recorder`。
4. 点击 `导出当前武器整棵动作树`。
5. 查看生成的 `ActionTreeDump_*.json`。

注意：

- 现在整树导出会覆盖同武器的旧文件
- 例如太刀永远写到 `ActionTreeDump_LongSword.json`

## UI 说明

- `开始录制 / 停止录制`
  开关自动记录。

- `强制记录当前动作`
  不等动作变化，直接把当前状态写一条进去。

- `记录武器动作`
  控制是否把玩家 motion/node/action 变化和玩家命中快照写入 `records`。关闭后可以专门录怪物目标采样。

- `导出当前武器整棵动作树`
  直接把当前装备武器的整棵动作树导出成 JSON，不需要先录制动作。

- `只在拔刀时记录`
  开启后，只有角色拔刀时才会记录武器动作，减少待机和杂项数据；不影响怪物目标采样。

- `当前动作信息`
  实时显示你当前武器、motion、node，以及当前节点下挂着的 actions。

- `重点 Condition 线索`
  当前这一帧如果命中了重点 condition，会在 UI 里显示简要摘要，方便你边打边确认有没有踩到我们要的判定链。

- `最后一条记录`
  快速查看刚刚写进去的那条数据。

- `手动保存`
  手动把当前内存里的记录重新写一次到 json。

- `清空记录`
  清空内存和文件里的记录内容。

## 怎么用它来找 GP

推荐流程：

1. 只装备你要研究的武器。
2. 打开录制。
3. 在游戏里反复打出目标 GP 动作。
   例如长枪精准防御、太刀见切、盾斧 GP 等。
4. 停止录制。
5. 打开这次生成的 `ActionTraceRecorder_*.json`。
6. 找到目标动作触发时对应的记录。
7. 看这一条记录里的：
   - `motionId`
   - `nodeId`
   - `actions`
   - `transitions`
8. 在 `actions` 里找最像 GP 的候选 action。
   通常重点看：
   - `typeName`
   - `startFrame`
   - `endFrame`

如果像太刀居合、见切这类动作看起来不像“某个 action 直接带 GP 帧”，那就进一步看：

- 哪些 `transition.condition.typeName` 看起来像成功判定条件
- 哪条 `transition` 会跳向成功节点
- 成功节点和失败节点的 `nodeName` 有什么区别

也就是说，升级版记录器除了帮你看 action，也能帮你看“这个动作是怎么从当前节点跳去成功/失败分支”的。

如果你现在要分析太刀见切、居合这种动作，推荐重点先看：

- `focusedProbe`
- `focusConditions`
- `transition.condition.typeName`
- `transition.condition.fields`
- `transition.condition.scannedFields`
- `transition.condition.scannedProperties`
- `transition.targetNode.nodeName`
- `transition.targetNode.transitionPreview`

这样通常能比单看 `actions` 更快定位到真正的“成否判定节点”。

如果你还不确定应该录哪个动作，也可以先点一次“导出当前武器整棵动作树”，从整树 JSON 里先筛：

- 哪些 nodeName 最像目标招式
- 哪些 condition / transition 看起来最像成功判定
- 哪些 action 类型名最值得重点观察

## 一个现实限制

这个工具记录的是：

- 当前 node 下挂着哪些 action
- 当前 node 上挂着哪些 transitions / conditions / events

但不会直接告诉你：

- “这一个 action 就一定是 GP 本体”
- “这一个 condition 就一定是居合成功判定”

因为有些节点可能挂了多个 action，而且某些 `ActionIndex` 还可能被复用；同样，某个成功判定也可能是多条 condition / transition 联动的结果。

所以这份记录更像是“候选集合”，不是 100% 自动判定结果。

最好把它和 `RE-BHVT-Editor` 结合起来看。

## 和 Custom GP Frames 的关系

可以把两个项目理解成上下游：

- `Action Trace Recorder`
  负责帮我们在游戏里采集候选 action 信息

- `Custom GP Frames`
  负责把确认过的 GP 动作做成武器下拉 + 招式滑条

前者是找数据，后者是用数据。
