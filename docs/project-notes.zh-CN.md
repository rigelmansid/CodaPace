# 项目须知

这份文件记的是**这台机器和这份代码的硬事实**：环境限制、约定、以及那些踩过一次就不该再踩的坑。

配套的两份 backlog 记的是「每条改动为什么长这样」，见文末索引。

最后更新：2026-09-23

---

## 项目

`CodaPace` —— macOS 菜单栏应用，监控中转站与订阅制 API 的额度。

核心概念是 **pace = 剩余额度% − 剩余时间%**：不只报「用了多少」，而是回答「按这个速度撑不撑得到下次重置」。

```
Sources/Core/     纯逻辑，SwiftPM 暴露，全部可单测
Sources/App/      SwiftUI 视图、菜单栏绘制、偏好、通知、钥匙串
Tests/CoreTests/  自建的极简测试框架（CLT 无 XCTest），用例需在 TestRegistry.swift 显式登记
docs/             本文件 + 两份 backlog
Scripts/          图标生成器，平时不用动
```

面向用户的说明在 `README.md` / `README.zh-CN.md`，讲的是「这东西干什么用」；本文件讲的是「怎么接着改」。

---

## 环境硬约束

这些不是偏好，是这台机器的客观限制。**绕过它们的方案不用再试，那条路已经堵死过。**

| 约束 | 实情 |
|---|---|
| **没有 Xcode.app** | 只有 Command Line Tools（`xcode-select -p` → `/Library/Developer/CommandLineTools`） |
| **没有 XCTest** | 它只随 Xcode.app 分发。`swift test` 在这里跑不了，项目自建了极简框架顶替 |
| **SDK 必须显式指定** | 系统装着 MacOSX26 / 26.5 / 27.0 / 27，默认取最新。**必须用 26** |
| **只产 arm64** | `-target arm64-apple-macos13.0`。Intel Mac 跑不了，这是有意的 |
| Swift 版本 | 工具链 6.4，但源码按 `-swift-version 5` 编。不要升语言模式 |

### 为什么 SDK 必须是 26

CLT 升到 Swift 6.4 后，较新 SDK 的 SwiftUI 把 `@State` 声明成了宏，展开需要 `SwiftUIMacros` 插件 —— 而它只随 Xcode.app 分发。于是所有含 `@State` 的文件都编不过。26 的 SwiftUI 还没这么做，所以 CLT 环境仍能独立构建。`build.sh` 已经处理好（按 26 → 26.5 顺序探测），**别改那段探测逻辑，也别让它去取 27**。

**这个坑留下过一道疤**：在解决之前，UI 文件长期只有部分类型检查。解开后第一次全量检查，发现 `PopoverView` 还在用早已改掉的旧签名 —— 那个缺口连**编译期错误**都在吞。所以改完 UI 必须跑全量类型检查（见下）。

### 钥匙串可用（2026-09-22 实测）

ad-hoc 签名、没有 provisioning profile 的 app **能用钥匙串**，写、读、删三步都实机验证过（`Sources/App/KeychainStore.swift`）。

前提是走**文件版**钥匙串——即**不要**设 `kSecUseDataProtectionKeychain`。数据保护版要求 `keychain-access-groups` 权限，而那随 provisioning profile 分发，本项目没有。首次访问时系统会弹一次授权框，这是文件版的正常行为，不是故障。

`import Security` 由 swiftc 自动链接，`build.sh` **不需要**补 `-framework Security`（已验证）。

这条要紧，是因为它是 EXT-001 唯一能否决整条计划的未知：`.secret` 级凭据没地方存的话，需要 API Key 的供应商一家都接不了。

---

## 命令

```bash
swift run CoreTests    # 381 例，应全绿。改 Core 或测试后必跑
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

界面外观类的改动（菜单栏图标、面板配色、图表）**没有任何自动化验收**，typecheck 和测试一条都盖不住，只能构建后实机截图看：

```bash
./build.sh && open build/CodaPace.app
```

注意：app 已在运行时 `open` 只会激活旧实例。要看新构建得先退出：

```bash
pkill -f "CodaPace.app/Contents/MacOS/CodaPace"; sleep 1; open build/CodaPace.app
```

---

## 代码风格公约（沿用，不要重构）

**沿用现有风格，不重构。** 这不是审美偏好，是因为这套代码的注释里存着大量「为什么」，重构会把它们冲掉。具体地：

1. **注释用中文，且写的是「为什么」不是「做什么」。** 文件头是一段散文式的说明，讲清这个类型为何存在、解决过什么具体事故。范例见 `Sources/Core/InFlightGate.swift` —— 开头就点明「项目里已经在两处栽过同一个跟头」，并列出两起事故各自的编号。新增文件照这个格式写。

2. **注释里引用 backlog 编号**（`OPT-001`、`EXT-003`）。这是代码和决策记录之间唯一的索引，别省。

3. **保留既有的排版习惯**：`// MARK: -` 分节、`——` 破折号、`「」` 引号、`·` 间隔号。文档里用全角标点，代码注释里沿用现有文件的混排习惯 —— 照着邻近文件抄，不要统一化。

4. **命名**：类型和成员用英文，语义要具体（`isBoundaryInferred`、`hasCompleteUsage`、`unattributed`）。不要缩写成 `flag`、`tmp`、`data`。

5. **不要做这些事**：
   - 不要重排文件、拆分大文件、抽公共基类
   - 不要把中文注释改成英文，或反过来
   - 不要引入新的第三方依赖（项目零依赖，只用系统框架 + sqlite3）
   - 不要「顺手」改掉看着冗余的代码 —— 本项目大量「冗余」是刻意的，理由写在 backlog 的「修复记录」里
   - 不要新建与两份 backlog 平行的说明文件（见不变量 5）

---

## 必须遵守的不变量

这些是跨条目建立起来的，违反会把已修的缺陷重新引入。**代码注释里直接按编号引用它们。**

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
- `QuotaUnit.unknown` —— 供应商没说单位就显示裸数字，不默认美元

**遇到缺数据时不要「取个合理默认值」让流程跑通**，那正是本项目反复在修的 bug 形态。缺就如实标缺。

### 4. 日历规则 ≠ 固定时长

夏令时切换日会分道扬镳（「每天 0 点」那天只有 23 小时；「每隔 24 小时」会漂到 1 点）。由 `ResetPolicy` 七种策略分别处理，**不要**再引入「统一按秒数往回推」的算法。

### 5. 单一路径，不留平行实现

已删除 `AlertPolicy.newAlerts`、`TimeWindow.cycleStart`、`SnapshotBuilder`，因为它们各自与另一处逻辑重复、会随时间漂移。新增功能时优先合并而非并列。

**这条也适用于文档**：别新建 `NOTES.md`、`TODO.md` 之类跟 backlog 平行的文件，改就改在原处。

### 6. 供应商细节只许待在适配器里

通用层（`UsageService` / `Config` / 历史 / 通知）不该出现 `apiStats`、`admin-next`、`UserStats` 这类字样，也不该认识任何一条具体额度的名字。核查：

```bash
grep -rn "apiStats\|admin-next\|UserStats" Sources/App \
  Sources/Core/HistoryStore.swift Sources/Core/HistoryModels.swift Sources/Core/AlertPolicy.swift
```

**无输出即通过。** 注意：对整个 `Sources` 排除 `RelayProvider.swift` 后 grep 会命中 `Models.swift` 里 `UserStats` 的类型定义本身和两处注释引用 —— 那是 DTO 的所在地，不是泄漏。上面这条命令才是真正要守的边界。（把 DTO 挪进适配器属于 EXT-009 范围。）

这条最近一次被违反是在菜单栏自动选择里：原先写死「排除叫 `window` 的那条额度」，那是中转站的额度名漏进了通用层。已改为按**周期长度**判定（EXT-001）。

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

已有的 28 处不要为此专门去改（不重构），但如果正好在改那个文件的那一段，顺手换成 `first?`。

---

## 有效的工作方法

**反向验证**：每修一处，临时把原缺陷注入回去，确认测试真的会失败，再还原。

这条抓到过 **4 个弱测试**和 **2 个先前写错的断言**。反复栽在同一个坑上：

- 测试被**另一条规则顺带兜住** —— 比如「三天断档」同时也跨了日界，日界规则先兜住了，于是间隔规则的缺陷测不出来。必须构造只命中目标规则的用例。最近一次是 EXT-001 的「长周期不该被避开」：额度剩余设得低于危险线，于是它走了「高频且吃紧就顶上来」那条分支而同样返回正确答案，缺陷藏住了。
- 采样间隔取得比 30 分钟**空档阈值**还大，于是断开来自「空档」而非要测的那个原因。

**注入本身也会骗人。** 用 `perl -0pi -e` 做多行替换时锚点没命中，会**静默失败**，于是「全绿」被误读成「缺陷没被抓到」。改用带 `assert` 的 python 脚本先断言锚点存在，再替换。

完成一条 backlog 后在该条目末尾写「修复记录」，务必包含**未做的部分及理由**。这是本项目的既定惯例，靠它判断「这里为什么长这样」。

---

## 两份 backlog

| 文件 | 内容 | 进度 |
|---|---|---|
| `optimization-backlog.zh-CN.md` | 已有代码缺陷 OPT-001…012 | **12/12 全部完成** |
| `provider-and-chart-backlog.zh-CN.md` | 多供应商与图表扩展 EXT-001…009 | 002/003/004/005/008 完成；006/007 只保留 Core，渲染已决定不做；001 进行中；009 部分完成 |

每条已完成项末尾都有「修复记录」，写明改法、取舍、**以及刻意未做的部分和理由**。动手前先读对应那条 —— 很多看起来「明显该改」的地方，那里已经解释过为什么不改。

---

## 当前进行中：EXT-001 动态额度桶 + 接入 tu-zi

分四个阶段，每阶段自己能编译、能跑、能提交：

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 钥匙串可行性 | **完成**（见上文「钥匙串可用」） |
| 1 | 额度桶进显示路径（`QuotaKind` → `QuotaBucket`） | **完成** |
| 2 | 历史表改高表（v3 → v4） | **完成** |
| 3 | tu-zi 适配器 | **完成** |

阶段 1 那三处 `⚠︎` 临时桥接**已全部删除**，`QuotaKind` / `QuotaLimits` / `Sample.cost(for:)` 连同消失。现在历史层存的是 `Sample.quotas: [String: QuotaReading]`，适配器报几条额度就存几条。

一个贯穿的支点：**中转站的四个桶 ID 取值刻意等于旧 `QuotaKind` 的 rawValue**（`total` / `daily` / `weeklyOpus` / `window`）。同一个字符串活在三处存量数据里 —— 菜单栏固定选择的偏好、通知去重键、以及 v3 → v4 迁移时从四个固定列摊出来的桶行。改了它，老用户的菜单栏选择会失效、当前周期已发过的告警会重发一遍、历史曲线会对不上。**不要改**（`testUpgradingFromV3ExpandsTheFixedColumnsIntoBuckets` 会当场变红）。

### 现在有两个适配器

| | 中转站 | tu-zi |
|---|---|---|
| 用户输入 | 用量页面网址 | 一把 `sk-` key |
| 认证 | 查询参数里的 apiId | `Authorization: Bearer` |
| 信封 | `{success, data}` | `{code, message, data}` |
| 额度 | total / daily / weeklyOpus / window | daily / weekly / monthly |
| 单位 | 美元（字段名就是 cost） | **`.unknown`**（对方没标单位） |
| 重置时刻 | 要靠观测学习 | 服务端每次都给 |
| 账户身份 | 网址里的 apiId | **响应里的 `key_id`** |
| 凭据存储 | UserDefaults 明文 | **钥匙串** |

几乎没有一处相同，而通用层为此**没有长出一个 `if`** —— 那正是 EXT-002 的验收标准。

两条因此立下的规矩：

- **身份在响应里的适配器必须先「测试连接」才能保存**（`accountIDComesFromResponse`）。没跑过就没有身份，编一个会在真身份到手那天把历史和偏好劈成两半。界面上保存按钮会灰着，并说明为什么。
- **安全说明跟着 `credentialSensitivity` 走**。从前设置窗口写死一句「apiId 只能查看用量，不能发起请求」—— 那是中转站的性质被当成了通用前提。对一把能花钱的 key 照搬那句，是个假的安全承诺。

### 阶段 2 / 3 留下的三件事

- **`samples` 表的四个额度列没删**，新行一律写 0 占位，**任何代码都不再读它们**。留着是为了万一要退回 v4 之前的版本，那之前的历史还在原处。SQLite 的 `DROP COLUMN` 支持看版本，删了反而不好回头。
- **`Sample.allTokens` / `requests` 仍是非可选的**。不报累计值的供应商（tu-zi 一个都不报）在库里留下的是 0 而不是「未知」。眼下骗不到人：相邻两条都是 0，`TokenDelta` 返回 nil，一条 token 记录都不写，面板那行也整行不显示。但要加「累计 token 趋势」之前，得先把这两列也改成可选。
- **`Snapshot.totalCost` 没有任何读者**，纯写入。删一个 public 字段是另一个决定，没顺手做。

---

## 其余剩余工作

### 还欠的验证：OPT-009

该条的主体是 SwiftUI 的视图依赖，测试框架碰不到，三处 `onChange` 的实际触发行为**至今未经运行验证**。不需要写代码，只需要一个真实账户：开着历史窗口等一次定时刷新、切一次额度来源、切一次账户，各看一眼曲线和标题有没有跟着变。

阶段 3 之后这条终于有条件验完了：**中转站 ↔ tu-zi 来回切一次**，两个账户的额度表完全不同（四条 vs 三条），切换没生效会一眼看出来。代价是换账户会丢弃 token 增量基线，跨过那次切换的几分钟用量不会被计入某一天。

### 经判断不做的

- **EXT-006 / EXT-007 的渲染与交互**。收益是锦上添花，而成本全落在「只能靠截图验收」上，且有几条验收标准（空档、重置边界、跨月）只能等数据凑巧出现，无法按需构造。**Core 部分刻意保留**（`ChartSelection.swift` + 其测试、`Fmt.exact`、`QuotaSeriesBuilder.plotted`）—— 有完整测试和反向验证，是这条需求里最容易悄悄撒谎的那半，**不是死代码，别顺手删**。
- **EXT-008 的面板与图表配色**，含 `ChartPalette` 整条。菜单栏图标那部分已做完并验收。

### 已知的用户可见影响

OPT-008 之后，升级的老用户会看到**额度曲线的历史段消失**（那些采样没记过当时的上限），随新采样积累在 7/14/30 天窗口内自行恢复。这是有意的：替代方案是拿当前上限重写过去，正是该条要修的 bug。OPT-012 已让界面如实说明有多少条采样画不出来。

EXT-001 阶段 2 的 v3 → v4 迁移**不丢任何历史**（四个固定列原地摊成四条桶行，NULL 原样保留），但它是**单向的**：v4 之后写入的采样，旧版本读不到额度部分（旧代码读的是那四个列，而新行往那里写的是 0 占位）。所以回滚到 v4 之前的版本会看到「迁移那天之后的额度曲线是空的」，之前的完好。

---

## 实测基线

以下全部在 2026-09-22 实机跑过，可复现。若对不上，说明环境或代码有变，先查这里：

| 项目 | 结果 |
|---|---|
| `swift run CoreTests` | **381 通过 · 0 失败** |
| UI 全量类型检查 | **通过，无输出**，约 5 秒 |
| 供应商隔离核查（上文命令） | **干净，无命中** |
| 构建产物 | arm64，`minos 13.0`，ad-hoc 签名 |
| `swift --version` | Apple Swift 6.4，target `arm64-apple-macosx26.0` |
| 可用 SDK | MacOSX26 / 26.5 / 27.0 / 27（构建取 26） |
| Xcode.app | **不存在**，`xcode-select -p` → CommandLineTools |
| git | 远端 `origin` 在 GitHub，本地领先若干提交；以 `git status -sb` 为准 |

### 已知的文档过时点

- **测试数散落在 5 个地方**，加用例时必须一起改，否则会拿一个对不上的数去核基线：本文两处（「命令」+ 文末基线表）、`README.md`、`README.zh-CN.md`。当前值 **381**。

发现新的过时点时记在这里，别让它散落在各文件里。
