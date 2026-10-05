# 决策记录

做出决策时当场追加，编号递增，旧条目不改编号。推翻旧决策时在旧条目标题后加
“（已被 D-n 替代）”。格式与记录范围见 `~/agent-system/RULE.md` 第 2 节。
文中 §n 指 [project-notes.md](project-notes.md) 的章节，坑 n 见 [pitfalls.md](pitfalls.md)。

<!-- 模板（复制后去掉行首 4 个空格）：
    ### D-1 标题（YYYY-MM-DD，用户决定 | agent 选择）

    - 背景：
    - 选项：A …… / B ……
    - 选择：
    - 理由：
    - 影响：
-->

### D-1 采用 agent-system 的 code profile 文档结构（2026-10-03，用户决定）

- 背景：项目笔记原是单个 `docs/project-notes.zh-CN.md`（515 行），规则、现状、交接、历史和
  踩过的坑混在一起；没有 `AGENTS.md`，agent-system 的 SessionStart hook 不把本项目当作
  agent 项目处理。另有两份 backlog 逐条记录 OPT / EXT 的缘由，代码注释按 OPT / EXT 编号和
  「不变量 n」引用它们。
- 选项：A 保持现状 / B 用 `~/agent-system/bin/new-project .` 补成标准结构，拆分原笔记
- 选择：B，并且：
  - 原笔记 `git mv` 为 `docs/project-notes.md` 后再运行 new-project，使其保留该文件。
  - `AGENTS.md` 用中文（用户决定），与代码注释、backlog 同语言；不变量 1–6 移入
    `AGENTS.md`，保留原编号，代码注释无需改动；来由留在 project-notes §1。
  - 两份 backlog 不动，继续作为逐条修复记录，OPT / EXT 编号照常递增。新的跨条目决策和用户
    拍板的事记为 D-n；之前的决策不回填，仍在 backlog 的修复记录里。
  - 不变量 5 的文档部分改为「一件事只记一处」，decisions / pitfalls / log 是规定的分工，
    不算平行文件。
  - 容器文件夹里的 `codapace bak/`（2026-09-29 外部审查报告等）移到
    `../materials/refs/codapace-bak/`（用户决定）。
- 理由：用户要求（agent-system 待办，其 D-15）。按读取频率分文件，新会话能直接接上。
- 影响：新增 `AGENTS.md`、`CLAUDE.md`（符号链接）、`docs/decisions.md`、`docs/pitfalls.md`
  （坑 1–11 整理自原笔记）、`docs/log.md`（回填 2026-09 的阶段与验证记录）、
  `private-notes.md`（不入库）；`.gitignore` 加 `private-notes.md`；装上 pre-commit hook；
  `Sources/App/UpdateChecker.swift` 一行注释里的「项目须知」改为 project-notes。

### D-2 删除没有代码读取的能力声明（2026-10-05，用户决定）

- 背景：`ProviderCapabilities` 八项里只有两项有代码读：`cumulativeTokens`（token 空态文案）、
  `usageHistory`（连接报告的 `historyIsLocalOnly`）。`dailyResetTime` 的最后一个读者在 EXT-011
  （2026-09-28）改为看实际数据后消失；`costAmounts`、`cumulativeRequests`、`windowResetTimes`、
  `weeklyResetSchedule`、`monthlyAggregate` 只剩适配器里的声明和测试。
- 选项：A 保留 / B 删除
- 选择：B，删除这六项；保留的两项位值不变。
- 理由：没人读的声明会和代码脱节（tu-zi 的测试注释还写着「界面按 costAmounts 决定要不要加
  币种」，实际看的是额度的 `unit`）；不变量 5 不留没人用的路径。这些事实另有出处：单位在
  `unit`，周期是否推算在 `isInferred` / `provenance`，日重置要不要观测在 `learnableDailyBucketID`。
- 影响：`Provider.swift` 和四个适配器的声明与注释；相关测试改写，tu-zi 删 2 例。以后新增能力
  声明，要和读取它的代码一起加。

### D-3 保留 `cumulativeTokens` 与 `usageHistory` 两项能力声明（2026-10-06，用户决定）

- 背景：/simplify 的高度审查提出：没有适配器把 `usageHistory` 设为真，连接报告的「历史只能本地
  积累」提示实际对每家都出现；`cumulativeTokens` 可以改看快照里的 token 数是否为空。两条都做，
  `ProviderCapabilities` 可以整个删掉。
- 选项：A 两项都删，提示无条件给出、空态改看快照 / B 都保留
- 选择：B
- 理由：`cumulativeTokens` 说的是「这家报不报 token」，单次快照为空可能只是这次缺（sub2api 缺
  `usage.total` 时），改看快照会把「这次缺」说成「这家不报」（不变量 3）。`usageHistory` 删了
  行为不变，收益小，先不动。
- 影响：无代码改动。

### D-4 删除 `HistoryGaps.segments`（2026-10-06，用户决定）

- 背景：`segments` 从第一个提交起就没有正式代码调用；图上的空档一直由 `QuotaSeriesBuilder`
  （`breakReasons` 断线、`gaps` 给阴影区间）处理，只剩 `HistoryGapTests` 3 例在调它。
- 选项：A 删掉 `segments` 和只为它服务的 `split`，保留 `threshold` / B 保留
- 选择：A
- 理由：不变量 5 不留平行实现；3 例测试守的规则在 `QuotaSeriesTests` 里都有对应用例。
- 影响：`HistoryModels.swift` 的 `HistoryGaps` 只剩 `threshold`；删 3 例测试。
