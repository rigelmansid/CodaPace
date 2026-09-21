# 交接说明

面向「没有任何对话上下文」的接手者 —— 人或 AI 编码代理皆可。读完这份 + 两份 backlog 即可继续工作。

整理日期：2026-09-21（本次交接前已实测复核，基线见文末）

---

## 项目

`CodaPace` —— macOS 菜单栏应用，监控 [claude-relay-service](https://github.com/Wei-Shaw/claude-relay-service) 中转站的 API 额度。

核心概念是 **pace = 剩余额度% − 剩余时间%**：不只报「用了多少」，而是回答「按这个速度撑不撑得到下次重置」。

```
Sources/Core/     纯逻辑，SwiftPM 暴露，全部可单测（18 个文件）
Sources/App/      SwiftUI 视图、菜单栏绘制、偏好、通知（11 个文件）
Tests/CoreTests/  自建的极简测试框架（CLT 无 XCTest），用例需在 TestRegistry.swift 显式登记
docs/             本文件 + 两份 backlog（见下）
Scripts/          图标生成器，平时不用动
```

面向用户的说明在 `README.md` / `README.zh-CN.md`，讲的是「这东西干什么用」；本文件讲的是「怎么接着改」。

---

## 仓库状态

HEAD = `6686785 Land quota-correctness fixes and the provider abstraction`，**工作区干净**。

这个提交是本次交接的基线：OPT-001…011 和 EXT-002…007 的全部成果此前积压在工作区两周未提交，交接时一次性落库。所以 `git diff HEAD~1` 覆盖的是整整两周的工作，不要拿它当「最近改了什么」看。再往前只有 3 个提交，历史参考价值有限。

含义：

1. **现在有可用的还原点了。** 改坏了可以 `git diff` 比对，也可以放心 `git stash`。这在基线之前是做不到的。
2. **保持这个状态。** 每完成一条 backlog 就提交一次，别再攒成一大坨 —— 上一次攒了两周，期间任何一条误操作的 `git reset --hard` 都会全军覆没。
3. **提交与推送由用户定夺。** 代理不要自作主张 commit / push，远端尚未推送。

接手后第一件事仍然是确认测试全绿（`swift run CoreTests`，应为 321 通过 0 失败），确认基线在你的环境里成立。

---

## 环境硬约束

这些不是偏好，是这台机器的客观限制。**不要建议用绕过它们的方案，那条路已经堵死过。**

| 约束 | 实情 |
|---|---|
| **没有 Xcode.app** | 只有 Command Line Tools（`xcode-select -p` → `/Library/Developer/CommandLineTools`）。用户是建筑师，不装 Xcode 是既定选择。 |
| **没有 XCTest** | 它只随 Xcode.app 分发。`swift test` 在这里跑不了，项目自建了极简框架顶替。 |
| **SDK 必须显式指定** | 系统装着 MacOSX26 / 26.5 / 27.0 / 27，默认取最新。**必须用 26。** |
| **只产 arm64** | `-target arm64-apple-macos13.0`。Intel Mac 跑不了，这是有意的。 |
| Swift 版本 | 工具链 6.4，但源码按 `-swift-version 5` 编。不要升语言模式。 |

### 为什么 SDK 必须是 26

CLT 升到 Swift 6.4 后，较新 SDK 的 SwiftUI 把 `@State` 声明成了宏，展开需要 `SwiftUIMacros` 插件 —— 而它只随 Xcode.app 分发。于是所有含 `@State` 的文件都编不过。26 的 SwiftUI 还没这么做，所以 CLT 环境仍能独立构建。`build.sh` 已经处理好（按 26 → 26.5 顺序探测），**别改那段探测逻辑，也别让它去取 27**。

**这个坑留下过一道疤**：在解决之前，UI 文件长期只有部分类型检查。解开后第一次全量检查，发现 `PopoverView` 还在用早已改掉的旧签名 —— 那个缺口连**编译期错误**都在吞。所以改完 UI 必须跑全量类型检查（见下）。

---

## 命令

```bash
swift run CoreTests    # 321 例，应全绿。改 Core 或测试后必跑
./build.sh             # 构建 build/CodaPace.app（ad-hoc 签名）
```

改了 `Sources/App/` 下任何文件后，**必须**额外跑一次全量类型检查 —— `swift run CoreTests` 完全覆盖不到 UI 层：

```bash
swiftc -typecheck -swift-version 5 -target arm64-apple-macos13.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
  -framework AppKit -framework SwiftUI -framework Charts \
  Sources/Core/*.swift Sources/App/*.swift
```

无输出即通过，约 5 秒。比跑完整 `./build.sh` 快得多，适合改一处查一次。

**新增测试后必须在 `Tests/CoreTests/TestRegistry.swift` 登记，否则不会被执行** —— 框架不做自动发现，漏登记的表现是「测试静悄悄地不存在」，不报错。

---

## 代码风格公约（沿用，不要重构）

用户明确要求：**沿用现有风格，不重构**。这不是审美偏好，是因为这套代码的注释里存着大量「为什么」，重构会把它们冲掉。具体地：

1. **注释用中文，且写的是「为什么」不是「做什么」。** 文件头是一段散文式的说明，讲清这个类型为何存在、解决过什么具体事故。范例见 `Sources/Core/InFlightGate.swift` —— 开头就点明「项目里已经在两处栽过同一个跟头」，并列出两起事故各自的编号。新增文件照这个格式写。

2. **注释里引用 backlog 编号**（`OPT-001`、`EXT-003`）。这是代码和决策记录之间唯一的索引，别省。

3. **保留既有的排版习惯**：`// MARK: -` 分节、`——` 破折号、`「」` 引号、`·` 间隔号。文档里用全角标点，代码注释里沿用现有文件的混排习惯 —— 照着邻近文件抄，不要统一化。

4. **命名**：类型和成员用英文，语义要具体（`isBoundaryInferred`、`hasCompleteUsage`、`unattributed`）。不要缩写成 `flag`、`tmp`、`data`。

5. **不要做这些事**：
   - 不要重排文件、拆分大文件、抽公共基类
   - 不要把中文注释改成英文，或反过来
   - 不要引入新的第三方依赖（项目零依赖，只用系统框架 + sqlite3）
   - 不要「顺手」改掉看着冗余的代码 —— 本项目大量「冗余」是刻意的，理由写在 backlog 的「修复记录」里
   - 不要新建与现有文档平行的说明文件（见不变量 6）

---

## 必须遵守的不变量

这些是跨条目建立起来的，违反会把已修的缺陷重新引入。

### 1. 三种账户键口径，各有其因

| 键 | 组成 | 用途 | 为什么不同 |
|---|---|---|---|
| `storageKey` | 仅 apiId | 历史分区 | 中继换网址还是同一份用量 |
| `preferenceKey` | baseURL + apiId | 偏好分区 | 「日重置在几点」是那个部署的配置 |
| `notificationNamespace` | providerID + baseURL + apiId | 通知去重 | 无迁移成本，可用最严口径 |

前两者**刻意不含 `providerID`** —— 加进去会让存量用户的历史分区键当场改变，等于丢掉他们攒下的曲线。带版本的迁移属 EXT-009。

### 2. 跨 `await` 必须校验身份

刷新、测试连接、通知投递都是同一套：**开头把身份定住 → 提交前比对 → 不符就整份丢弃**（不显示、不入库、不通知）。共用实现是 `InFlightGate<Token>`。

绝不要在流程中途回头读全局配置 —— OPT-001 就是这么串账户的。

### 3. 不发明数据（本项目最核心的立场）

「未知」「零」「不限」是三件事，压成一个值就是撒谎。已体现在：

- `Sample.limits: QuotaLimits?` —— 有上限 / 当时不限(0) / 不知道(nil)
- `UserStats.hasCompleteUsage` —— 响应缺字段就不入历史
- `TokenAttribution.unattributed` —— 归不到某天就如实记成未归属，**不丢也不硬塞**
- `QuotaConnector.isBoundaryInferred` —— 推算的边界不能画成已知事件
- `TokenTooltip.requests: Int?` —— 为 0 时分不清真假，不显示
- `PaceVerdict.unavailable` —— 没有可信当期窗口就不给判断

代理尤其要注意这条：**遇到缺数据时不要「取个合理默认值」让流程跑通**，那正是本项目反复在修的 bug 形态。缺就如实标缺。

### 4. 日历规则 ≠ 固定时长

夏令时切换日会分道扬镳（「每天 0 点」那天只有 23 小时；「每隔 24 小时」会漂到 1 点）。由 `ResetPolicy` 七种策略分别处理，**不要**再引入「统一按秒数往回推」的算法。

### 5. 单一路径，不留平行实现

已删除 `AlertPolicy.newAlerts`、`TimeWindow.cycleStart`、`SnapshotBuilder`，因为它们各自与另一处逻辑重复、会随时间漂移。新增功能时优先合并而非并列。

**这条也适用于文档**：别新建 `NOTES.md`、`TODO.md` 之类跟 backlog 平行的文件，改就改在原处。

### 6. 供应商细节只许待在适配器里

通用层（`UsageService` / `Config` / 历史 / 通知）不该出现 `apiStats`、`admin-next`、`UserStats` 这类字样。核查：

```bash
grep -rn "apiStats\|admin-next\|UserStats" Sources/App \
  Sources/Core/HistoryStore.swift Sources/Core/HistoryModels.swift Sources/Core/AlertPolicy.swift
```

**无输出即通过。** 注意：原先记录的是对整个 `Sources` 排除 `RelayProvider.swift` 后 grep，但那样会命中 `Models.swift:211` 的 `UserStats` 类型定义本身和两处注释引用 —— 那是 DTO 的所在地，不是泄漏。上面这条命令才是真正要守的边界。（把 DTO 挪进适配器属于 EXT-009 范围，现在别动。）

---

## 测试框架的坑

**没有进程隔离，也没有「断言失败即中止」。** 这两件事叠在一起，造出本项目最容易踩的地雷：

```swift
XCTAssertEqual(points.count, 1)   // 失败时只记录，不中止
XCTAssertEqual(points[0].value, …) // 于是继续执行 —— 数组为空则整个进程崩溃
```

在真 XCTest 里前一行会中止当前用例；在这套框架里不会。所以**一个本该报「失败」的用例，会变成整轮测试直接挂掉，且看不出是哪一条**。

现状：测试里有 28 处 `[0]` 强制下标，多数前面有 count 断言保护 —— 但如上所述，那道保护在这套框架里是**无效的**。新写断言一律用 `points.first?`：

```swift
XCTAssertEqual(points.first?.value, 42)   // 空数组时正常报失败，不崩进程
```

已有的 28 处不要为此专门去改（不重构），但如果你正好在改那个文件的那一段，顺手换成 `first?`。

---

## 有效的工作方法

**反向验证**：每修一处，临时把原缺陷注入回去，确认测试真的会失败，再还原。

这条抓到过 **3 个弱测试**和 **2 个先前写错的断言**。两次栽在同一个坑上：

- 测试被**另一条规则顺带兜住** —— 比如「三天断档」同时也跨了日界，日界规则先兜住了，于是间隔规则的缺陷测不出来。必须构造只命中目标规则的用例。
- 采样间隔取得比 30 分钟**空档阈值**还大，于是断开来自「空档」而非要测的那个原因。

完成一条 backlog 后在该条目末尾写「修复记录」，务必包含**未做的部分及理由**。这是本项目的既定惯例，后来者靠它判断「这里为什么长这样」。

---

## 两份 backlog

| 文件 | 内容 | 进度 |
|---|---|---|
| `optimization-backlog.zh-CN.md` | 已有代码缺陷 OPT-001…011 | **11/11 全部完成** |
| `provider-and-chart-backlog.zh-CN.md` | 多供应商与图表扩展 EXT-001…009 | 002/003/004/005 完成；006/007 仅 Core；001/008/009 未开始 |

每条已完成项末尾都有「修复记录」，写明改法、取舍、**以及刻意未做的部分和理由**。动手前先读对应那条 —— 很多看起来「明显该改」的地方，那里已经解释过为什么不改。

---

## 剩余工作

### 可做（工具链已解开）

按此顺序，互有依赖：

1. **EXT-008 图表主题** —— 文档明说可提前独立做；tooltip 要用它的 `tooltipBackground/Text`、`selectionRule`。注意验收标准要求**截图验证**，且文档要求「先复现并定位，不预先认定是系统反色」。**入口是一张亮色主题下的实机截图**，没有它只能猜，而猜正是该条明令禁止的 —— 需要向用户索要截图，代理自己跑不出来。
2. **EXT-006 / EXT-007 渲染** —— Core 部分已就绪（`ChartSelection`、`QuotaTooltip`、`TokenTooltip`、`Fmt.exact`），只差 `chartOverlay` + `ChartProxy` + 指针事件 + 浮层定位。**不可用 `chartXSelection`**（macOS 14 起才有，本项目 target 是 13.0）。

（**OPT-009 已完成**，见 optimization-backlog。它给 `UsageService` 留下了 `accountGeneration` 这个换账户信号 —— 后续任何需要跟着账户重读的视图都该挂它，而不是去看快照变化：两个账户都离线时快照前后都是 nil。）

### 仍阻塞：缺真实第二方供应商样例

- **EXT-001** 动态额度桶。`scope / products / models` 这套 taxonomy 在零真实样本下设计风险很高，已多次建议推迟；它的存储那一半还要改 `samples` 表的四个固定额度列（迁移机制已就位，见 OPT-008）。
- **EXT-005** 按额度周期查看 token —— 中转站没有周期统计接口（`capabilities` 已如实声明 `usageHistory` 为假）。
- **EXT-009** 真实供应商验证。

这三条**不要在没有真实样例的情况下硬做**。前任已经评估过多次，结论一致：凭空设计出来的 taxonomy 迁移成本比收益高。

### 已知的用户可见影响

OPT-008 之后，升级的老用户会看到**额度曲线的历史段消失**（那些采样没记过当时的上限），随新采样积累在 7/14/30 天窗口内自行恢复。这是有意的：替代方案是拿当前上限重写过去，正是该条要修的 bug。

---

## 与用户协作的方式

- **用户是建筑师，不写代码。** 不要把「你看一下这段实现对不对」抛回去，也不要用 diff 当解释。要判断的事，用「现象 + 取舍」讲。
- **凡涉及界面外观的验收，只能由用户截图。** 代理跑不了 GUI，看不到菜单栏。需要看效果时直接说「请构建后截个图给我」，并给出 `./build.sh && open build/CodaPace.app`。
- **提交与推送由用户定夺**，不要自动 commit / push。改完告诉用户改了什么，由他决定是否落库。
- 沟通用中文。

---

## 本次交接前的实测基线

以下全部在 2026-09-21 实机跑过，可复现。接手后若对不上，说明环境或代码有变，先查这里：

| 项目 | 结果 |
|---|---|
| `swift run CoreTests` | **321 通过 · 0 失败** |
| UI 全量类型检查 | **通过，无输出**，约 5 秒 |
| 供应商隔离核查（上文命令） | **干净，无命中** |
| `swift --version` | Apple Swift 6.4，target `arm64-apple-macosx26.0` |
| 可用 SDK | MacOSX26 / 26.5 / 27.0 / 27（构建取 26） |
| Xcode.app | **不存在**，`xcode-select -p` → CommandLineTools |
| git | 5 个提交，HEAD = `6686785`；工作区干净，未推送远端 |

### 已知的文档过时点

暂无。两份 README 里过时的测试数（119 → 321）已于本次交接时更正。

发现新的过时点时记在这里，别让它散落在各文件里。
