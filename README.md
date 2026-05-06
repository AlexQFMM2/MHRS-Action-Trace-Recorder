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

## 这个工具会输出什么

脚本会把记录写到：

- `ActionTraceRecorder.json`

输出内容大致包含：

- `recordedAt`
  记录时间
- `uptime`
  游戏运行时间
- `weaponType`
  武器类型编号
- `weaponName`
  武器名称
- `motionId`
  当前动作 id
- `motionBank`
  当前动作 bank
- `motionFrame`
  当前动作帧
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

每个 `transition` 条目里会包含：

- `slot`
  当前过渡在节点数组里的槽位
- `condition`
  对应 condition 的编号、类型名和部分可读字段
- `targetState`
  这个 condition 命中后跳去的 state
- `events`
  这条过渡挂着的 transition events

## 工作方式

这个工具默认按“动作变化”自动记录。

也就是说，当这些信息的组合发生变化时，它会写一条新记录：

- 当前武器类型
- 当前 `motion bank`
- 当前 `motion id`
- 当前 `node id`
- 当前节点上的 `action` 列表

这样做可以避免每帧都疯狂写文件，同时又能在你打出不同动作时留下轨迹。

## 使用方式

1. 把 `Action Trace Recorder` 文件夹放进你游戏侧的 `REFramework` mod 目录。
2. 启动游戏。
3. 打开 `REFramework` UI。
4. 展开 `Action Trace Recorder`。
5. 点击 `开始录制`。
6. 在游戏里实际打出你想分析的动作。
7. 打完后点击 `停止录制`。
8. 查看生成的 `ActionTraceRecorder.json`。

## UI 说明

- `开始录制 / 停止录制`
  开关自动记录。

- `强制记录当前动作`
  不等动作变化，直接把当前状态写一条进去。

- `只在拔刀时记录`
  开启后，只有角色拔刀时才会记录，减少待机和杂项数据。

- `当前动作信息`
  实时显示你当前武器、motion、node，以及当前节点下挂着的 actions。

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
5. 打开 `ActionTraceRecorder.json`。
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
