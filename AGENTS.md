<!-- profile: code -->
# AGENTS.md

写给 AI 编程助手和维护者的工作规则。`CLAUDE.md` 是指向本文件的符号链接，只改本文件。

本文件只写**怎么做**。项目内容在 `docs/`：
[project-notes.md](docs/project-notes.md)（进行中、现状、架构、待办、规划；下文 § 指它的章节）、
[decisions.md](docs/decisions.md)（D-n）、[pitfalls.md](docs/pitfalls.md)（坑 n）、
[log.md](docs/log.md)（阶段记录与验证记录），以及逐条记录改动缘由的两份 backlog：
[optimization-backlog.zh-CN.md](docs/optimization-backlog.zh-CN.md)（OPT-n）、
[provider-and-chart-backlog.zh-CN.md](docs/provider-and-chart-backlog.zh-CN.md)（EXT-n）。
不要把项目内容抄进本文件。

## 接手

1. 读 project-notes 的「进行中」和 §5 待办，先向用户报告现状再动手：最新进展、本地 git
   状态（`git status -sb`、`git log --oneline -5`）、GitHub 状态
   （`gh release view --json tagName,publishedAt`、origin 是否同步）、待确认与待执行各几项。
   数字要现查，不要照抄文档。
2. 动某个模块前，先读对应的 OPT / EXT 条目末尾的「修复记录」和相关的坑。很多看起来
   「明显该改」的地方，那里已经解释过为什么不改。
3. 现有的东西：`Sources/Core/`（纯逻辑，可单测）、`Sources/App/`（SwiftUI、菜单栏、钥匙串）、
   `Tests/CoreTests/`（自建测试框架）、`build.sh`、`Scripts/make-icon.swift`。四个适配器：
   中转站（claude-relay-service）、tu-zi Coding、sub2api、claude-code-hub。智谱、Kimi、MiniMax
   只有调研，**没有实现**。

## 环境

只有 Command Line Tools，没有 Xcode.app 和 XCTest；SDK 必须用 MacOSX26（坑 1）；只产
arm64，`-target arm64-apple-macos13.0`；源码按 `-swift-version 5` 编，不要升语言模式。
细节见 §2。`build.sh` 的 SDK 探测逻辑不要改，也别让它取 27。

## 命令

```bash
swift run CoreTests    # 481 例，应全绿。改 Core 或测试后必跑
./build.sh             # 构建 build/CodaPace.app（ad-hoc 签名）
```

改了 `Sources/App/` 下任何文件，**必须**再跑一次全量类型检查（CoreTests 覆盖不到 UI 层，坑 1）。
无输出即通过，约 5 秒：

```bash
swiftc -typecheck -swift-version 5 -target arm64-apple-macos13.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
  -framework AppKit -framework SwiftUI -framework Charts \
  Sources/Core/*.swift Sources/App/*.swift
```

- 新增测试必须在 `Tests/CoreTests/TestRegistry.swift` 登记，否则不会执行，也不报错（坑 4）。
- 测试数写在 4 处：本文件、project-notes 的实测基线、`README.md`、`README.zh-CN.md`。
  加用例时一起改。
- 界面外观（菜单栏图标、配色、图表）没有自动化验收，只能构建后实机看。app 已在运行时
  `open` 只会激活旧实例（坑 10）：

  ```bash
  pkill -f "CodaPace.app/Contents/MacOS/CodaPace"; sleep 1; open build/CodaPace.app
  ```

## 写测试

- 这套框架断言失败不中止，也没有进程隔离（坑 3）。新断言一律用 `points.first?`，
  不用 `[0]`。已有的 `[0]` 不专门去改，正好改到那一段时顺手换。
- 异步路径用 `runAsync { }` 测，它带 5 秒超时，超时如实报失败。
- **反向验证**：每修一处，临时把原缺陷注入回去，确认测试会失败，再还原。用例只能命中
  目标规则，不能被别的规则顺带兜住（坑 5）。注入用带 `assert` 的 python 脚本，先断言
  锚点存在再替换，不用 `perl -0pi`（坑 6）。

## 代码风格（沿用，不要重构）

这套代码的注释里存着大量「为什么」，重构会把它们冲掉。

1. 注释用中文，写「为什么」不写「做什么」。文件头是一段散文式说明，范例见
   `Sources/Core/InFlightGate.swift`。新文件照这个格式写。
2. 注释里引用 OPT / EXT 编号、不变量编号、D-n。这是代码和记录之间的索引，别省。
3. 保留排版习惯：`// MARK: -` 分节、`——`、`「」`、`·`。照邻近文件抄，不要统一化。
4. 类型和成员用英文，语义要具体（`isBoundaryInferred`、`hasCompleteUsage`），不缩写成
   `flag`、`tmp`、`data`。
5. 不要：重排文件、拆大文件、抽公共基类；把中文注释改成英文或反过来；引入第三方依赖
   （项目零依赖，只用系统框架和 sqlite3）；「顺手」删看着冗余的代码，理由在 backlog 的
   修复记录里。

## 必须遵守的不变量

跨条目建立的规则，违反会把已修的缺陷重新引入。代码注释按这里的编号引用，**编号不要改**。
每条的来龙去脉见 §1 和对应的 backlog 条目。

1. **三种账户键口径各有其因**：`storageKey`（providerID + apiId，历史分区）、
   `preferenceKey`（baseURL + apiId，偏好分区）、`notificationNamespace`（providerID +
   baseURL + apiId，通知去重）。只有兜底适配器的账户能认领 `legacyStorageKey` 下的老分区。
   中转站的四个桶 ID（`total` / `daily` / `weeklyOpus` / `window`）不要改。
2. **跨 `await` 必须校验身份**：开头定住身份 → 提交前比对 → 不符就整份丢弃（不显示、
   不入库、不通知），共用 `InFlightGate<Token>`。流程中途不回头读全局配置（OPT-001）。
3. **不发明数据**：「未知」「零」「不限」是三件事。缺数据时不取「合理默认值」，如实标缺。
   采信供应商自己可核对的声明不算发明（如 tu-zi 的美元单位，证据在其用量页面）。
4. **日历规则 ≠ 固定时长**：由 `ResetPolicy` 的各策略处理，不引入「统一按秒数往回推」。
5. **单一路径，不留平行实现**：新功能优先合并而非并列。文档也一样：一件事只记在一处，
   不新建 `NOTES.md`、`TODO.md` 这类文件；文档分工见下文「文档」（D-1）。
6. **供应商细节只待在适配器里**：通用层不出现 `apiStats`、`admin-next`、`UserStats`，
   也不认识任何一条具体额度的名字。核查（无输出即通过）：

   ```bash
   grep -rn "apiStats\|admin-next\|UserStats" Sources/App \
     Sources/Core/HistoryStore.swift Sources/Core/HistoryModels.swift Sources/Core/AlertPolicy.swift
   ```

另外两条接着改时容易踩的：

- 身份在响应里的适配器（`accountIDComesFromResponse`）必须先「测试连接」才能保存。
- 安全说明跟着 `credentialSensitivity` 走，不写死成某一家的性质。

## 数据兼容（每一版都要守）

用户数据全在 app 包外（偏好 plist、`History.sqlite`、钥匙串）。所以 bundle ID
`com.hesher.codapace`、偏好键名、钥匙串服务名 `CodaPace` **永远不改**，数据库迁移只向前。
钥匙串只用文件版，不设 `kSecUseDataProtectionKeychain`（坑 2）。

## 验证

- Core 改动：`swift run CoreTests` 全绿，且做过反向验证。
- App 改动：全量类型检查通过；界面或交互改动还要构建后实机确认，没实机看过的，在汇报和
  修复记录里写明「验证缺口」。
- 供应商接入：按真实账户或本机部署的真实实例实测，照文档写会错（§1「适配器」、坑 9）。

## 文档

- 完成一条 OPT / EXT 后，在该条末尾写「修复记录」：改法、取舍、**未做的部分及理由**。
- 跨条目的决策、用户拍板的事记进 `docs/decisions.md`（D-n），当场记。
- 工作单元结束时覆盖「进行中」，在 `docs/log.md` 追加记录，更新待办和当前状态。
- 新发现的文档过时点记在 project-notes 的「已知的文档过时点」。
- 文档语言：中文，全角标点。README 中英两份同步改。
- 改完中文文件扫一遍乱码（坑 7）：`grep -rn $'\xef\xbf\xbd' Sources Tests docs README*.md AGENTS.md`。

## 发版

只在用户明确要求时进行，每一步对外操作都要用户同意。

1. 改 `Info.plist` 两个版本键 → 跑测试 → 退出开发版、`./build.sh`。
2. `ditto -c -k --keepParent build/CodaPace.app build/CodaPace-arm64.zip`（附件名固定，
   README 的安装命令靠它）。
3. `gh release create vX.Y build/CodaPace-arm64.zip --target main --notes-file …`，说明照以往的
   中英双语格式，末尾附 SHA-256。
4. 用 `curl` 核对 `releases/latest` 的 tag，下载 zip 核对哈希。
5. 验证更新提醒：用 PlistBuddy 只把 `build/` 那份的版本改低，`codesign --force --sign -` 后
   打开，验完重新 `./build.sh`。仓库的 `Info.plist` 不动。

GitHub 仓库的 About（描述、标签）不在仓库里。支持的服务或定位变了要一起改，改前先给用户看。

## 隐私

- `private-notes.md` 不入库，放真实主机、用户名、个人配置。不要把它的内容抄进入库文件、
  提交信息或 PR，用 `<host>`、`<user>` 这类占位符。
- 参考资料、待整理的笔记、临时产出放在仓库外维护者的 `../materials/`（`refs/`、`inbox/`、
  `scratch/`），其他机器上可能不存在。临时文件和生成物不写进仓库，写到 `../materials/scratch/`。
- 本机实验室（中转站软件实测）放在 `/tmp/codapace-lab/`，只监听 `127.0.0.1`，包管理器缓存
  也指进去（坑 9）。替用户确认任何合规承诺前先问。
- 提交和推送只在用户要求时进行。
