# CodaPace 待优化清单

审查日期：2026-09-18  
审查基线：`bfcf5e5`  
状态：原审查列出 OPT-001…011，已全部修复（见进度总览）。OPT-013 起是第二轮审查（2026-09-30，基线 `61f6821`）录入的，见文末。

**OPT-012 是后来追加的**（2026-09-21），不属于那次审查 —— 它是修完 OPT-008 / OPT-009 之后，由一张实机截图暴露出来的新缺口。格式沿用原有条目。

优先级：P1 为高优先级，建议优先修复；P2 为中优先级，建议纳入后续迭代。

## 进度总览

- [x] OPT-001 · P1 · 切换账户时，旧请求污染新账户历史 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-002 · P2 · 15 分钟保底采样无法正常触发 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-003 · P2 · 采样和 token 累加缺少事务保护 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-004 · P2 · 无效响应被当作真实零用量 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-005 · P2 · 通知未成功提交便记录为已发送 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-006 · P2 · 通知去重缺少账户维度 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-007 · P2 · 日重置学习结果跨账户共享 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-008 · P2 · 当前额度上限改写历史百分比 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-009 · P2 · 图表刷新依赖不完整 —— 已修复，见该条目末尾的「修复记录」
- [x] OPT-010 · P2 · 过期窗口仍给出正常速度判断 —— 已随 EXT-004 修复，见该条目末尾
- [x] OPT-011 · P2 · 夏令时附近的历史周期反推错误 —— 已随 EXT-004 修复，见该条目末尾
- [x] OPT-012 · P2 · 部分采样画不出时，曲线不说明缺了什么 —— 已修复（2026-09-21 追加，非原审查范围），见该条目末尾的「修复记录」
- [x] OPT-013 · P2 · 浮点容差断言把 NaN 判为通过（第二轮审查，下同）—— 已修复
- [x] OPT-014 · P2 · 请求计数按 Int32 读写 SQLite —— 已修复
- [x] OPT-015 · P1 · sub2api / claude-code-hub 把缺失用量当成完整数据 —— 已修复（方案 A）
- [x] OPT-016 · P2 · 未验证的陌生站点可直接保存；HTTP 200 的无关 JSON 被当成验证成功 —— 已修复
- [x] OPT-017 · P2 · 「测试连接」在保存前就把 claude-code-hub 会话写进钥匙串 —— 已修复
- [x] OPT-018 · P2 · 钥匙串读取失败被当成「缺少密钥」 —— 已修复
- [x] OPT-019 · P3 · 不勾「存档」保存，能花钱的 key 成为界面上删不掉的孤儿 —— 已修复
- [x] OPT-020 · P3 · 设置窗口关掉后草稿残留；测试在飞时改输入不能重测 —— 已修复
- [ ] OPT-021 · P2 · A → B → A 快速切换时，旧 A 请求覆盖新 A 状态
- [ ] OPT-022 · P3 · 通知等待授权期间切换账户或关闭通知，仍会发出旧通知
- [ ] OPT-023 · P2 · 日历规则在夏令时跳时后终点漂移；亚秒级提前进入下一周期
- [ ] OPT-024 · P2 · 缺桶后恢复，漏判计数器下降
- [ ] OPT-025 · P3 · 学到的日重置时刻丢掉分钟，小幅冲正也被当成重置
- [ ] OPT-026 · P3 · 限流窗口走退路时告警去重键每次都变
- [ ] OPT-027 · P3 · 回退到 v3 再升级，给 v4 采样注入「幽灵桶」
- [ ] OPT-028 · P3 · 界面零散缺陷（24h 轴、lastError、Picker 空白、金额单位）
- [x] OPT-029 · P3 · 历史保留从未生效 —— 已修复（90 天，用户 2026-09-30 定）
- [ ] OPT-030 · P3 · 文档与文案过时

## OPT-001：切换账户时，旧请求污染新账户历史

- **优先级：** P1
- **位置：** [UsageService.swift:83](../Sources/App/UsageService.swift#L83)、[HistoryRecorder.swift:86](../Sources/App/HistoryRecorder.swift#L86)
- **证据：** 已通过模拟网络、内存配置及存储边界复现，调用实际刷新和记录逻辑。

**问题与影响：** 刷新过程中多次读取可变的全局配置。账户 A 的请求尚未完成时切换到 B，后续月消费请求和历史写入会使用 B 的配置。复现中，最终快照包含 A 的额度和 B 的月消费，A 的日消费 `42` 被写入 B 的历史。配置保存触发的新刷新还可能被 `isLoading` 拦截。

**建议：** 在刷新开始时固定服务地址和账户标识，并传递到所有请求、快照、历史记录及通知流程。配置变化时取消或丢弃旧刷新结果，清理旧账户展示状态，并确保新账户得到一次刷新。

**验收标准：** 在第一个请求或第二个请求等待期间切换账户，旧响应均不能覆盖新账户状态、写入新账户历史或触发其通知；新账户刷新能正常完成。

**修复记录（已完成）**

新增 `Sources/Core/Account.swift`，把两件事提取成纯逻辑以便单测：

- `AccountIdentity` —— 不可变的账户身份值（`baseURL` + `apiId`）。刷新开头取一次就定住，一路传给两个请求、快照构建、历史写入。身份比较连 `baseURL` 一起比（发往另一台中继就是另一次请求）；但历史分区键 `storageKey` 只由 `apiId` 决定（中继换网址不该把历史割成两半）。
- `RefreshGate` —— 把原来那个不区分账户的布尔 `isLoading` 换成「在飞的是**哪个**账户」。同账户不重入；账户不同必须放行，这正是原先新账户首刷被拦掉的原因。`finish` 按账户核对，旧刷新收尾不会抹掉新账户的在飞标记。

调用侧改动：

- `UsageService.refresh()` 开头 `let account = Config.account`，两个 `await` 之间不再回头读全局配置；两个请求返回后、写入任何状态之前用 `guard Config.account == account` 校验身份，不是当前账户就整份丢掉（不显示、不入库、不发通知）。`catch` 分支同样校验，避免旧账户的失败在新账户头上显示成 Offline。
- 新增 `UsageService.applyAccount(_:)`，把切换账户的收尾集中起来：落盘、清空旧账户的 `snapshot`/`errorText`、清空通知去重账本、通知 `HistoryRecorder` 换库，再重启定时器并立刻刷一次。在飞的旧刷新无需取消——它回来时过不了身份校验，而且已不占门。
- `API.userStats` / `API.monthlyUsage` 改为**必须显式传** `AccountIdentity`，删掉了原先读 `Config` 的无参重载：那对重载让调用方误以为「一次刷新用一个账户」，实际是每个请求各读一次当时的配置。
- `HistoryRecorder.record(_:account:)` 的分区键来自传入的身份而非 `Config`；新增 `accountDidChange()` 立即丢弃旧账户的 token 基线（两个账户的累计值无可比性，做差没有意义）。读取路径（图表）仍用当前账户，这是对的。
- `Config.apply(_:)` 一次写入两个字段，避免留下「A 的网址 + B 的 apiId」这种中间态；`Config.parse` 直接返回 `AccountIdentity?`。

覆盖测试：`Tests/CoreTests/AccountTests.swift`，15 例（总数 119 → 134 全通过），其中三例直接钉住本条 bug——换账户在飞时必须放行、旧账户 `finish` 不得清掉新账户标记、A→B→A 切回后仍能刷新。

**未包含（另有条目）**：通知去重键本身仍不含账户维度（OPT-006），此处只是在切换账户时清空账本作为缓解；日重置学习结果仍跨账户共享（OPT-007）。

## OPT-002：15 分钟保底采样无法正常触发

- **优先级：** P2
- **位置：** [HistoryRecorder.swift:46](../Sources/App/HistoryRecorder.swift#L46)、[HistoryRecorder.swift:59](../Sources/App/HistoryRecorder.swift#L59)
- **证据：** 已使用实际记录逻辑和内存存储复现。

**问题与影响：** `previous` 在每次刷新结束时都会更新，而保底采样也使用这个基线。连续无变化时，比较间隔始终只是刷新间隔，无法达到 15 分钟。每分钟刷新一次、持续一小时的复现中，仅保存 1 条采样，预期应有 5 条。图表因此可能把正常空闲误判成数据缺失。

**建议：** 分开维护“上次成功刷新”和“上次成功落盘”的基线，分别用于 token 增量、重置学习和保底采样判断。

**验收标准：** 连续一小时每分钟刷新相同数据，在第 0、15、30、45、60 分钟各保存一条采样；期间数值变化仍能立即保存，token 增量不重复累计。

**修复记录（已完成）**

根因确认：`previous` 在每次刷新结束时无条件推进，而保底锚点也拿它做比较，于是「离上一条记录多久了」量到的恒等于刷新间隔（默认 60 秒），永远够不到 15 分钟。空档阈值是 30 分钟，所以一段**正常空闲**会被当成 app 没运行、在图上画成阴影断档——而锚点存在的意义恰恰是区分这两件事。

在 `Sources/Core/HistoryModels.swift` 新增 `SamplingLedger`，把两条基线拆开（放进 Core 是为了能照验收标准直接写测试）：

- **落盘基线 `lastStored`** —— 只在采样真的写进库之后才推进。`shouldStore` 用它：「值变了吗」「满 15 分钟了吗」问的都是*库里那条*，与中间跳过的刷新无关。
- **观测基线 `lastObserved`** —— 每次刷新都推进。token 增量与日重置学习用它。

两条不能互换，尤其是 token 增量**必须**用观测基线：累计值做差时，基线要在每次消费掉一段增量后立刻前移；停在旧位置的话，`r1→r2` 消费过的那段会在下一次 `r1→r3` 里被重复累加一遍。日重置学习同理——相邻观测越密，推算出的重置小时越准。

`shouldStore` 仍然委托给原有的 `SamplingPolicy.shouldRecord`，规则本身只有一处表述，该函数原有 4 例测试不变。

`HistoryRecorder` 把单个 `previous` 换成 `ledger`，并把 `advance(to:stored:)` 放在流程最后——上面任何一步抛错都不推进基线，这次的增量下次重算（`insert` 是 `INSERT OR REPLACE`，重跑幂等）。`accountDidChange()` 与 `ensureStore(for:)` 换账户时一并丢弃两条基线。

覆盖测试：`Tests/CoreTests/HistoryTests.swift` 新增 `SamplingLedgerTests` 9 例（总数 134 → 143 全通过）。其中 `replayRefreshes` 辅助函数走的是记录侧的真实顺序（判断落盘 → 累加 token → 推进基线）：

- `testIdleHourLeavesFiveAnchors` —— 验收标准本身：0/15/30/45/60 各一条。
- `testTokenDeltaIsNeitherLostNorDoubleCountedAcrossUnstoredRefreshes` —— 20 分钟内累计值每分钟 +100，累加总量恰为首尾之差 2000，既不漏也不重。
- `testChangedValueIsStoredImmediately` / `testAnchorClockRestartsFromTheLastStoredSample` —— 值变了立刻落盘，且落盘后锚点从该条重新计时（第 3 分钟写过，下一条在第 18 而非第 15 分钟）。
- `testContinuouslyChangingValuesAreStoredEveryRefresh` —— 持续变化时每次刷新都落盘，与修复前一致，确认无回归。

## OPT-003：采样和 token 累加缺少事务保护

- **优先级：** P2
- **位置：** [HistoryRecorder.swift:47](../Sources/App/HistoryRecorder.swift#L47)、[HistoryStore.swift:90](../Sources/Core/HistoryStore.swift#L90)
- **证据：** 静态代码分析；尚未进行数据库故障或进程中断注入。

**问题与影响：** 记录流程先插入采样，再累加每日 token 桶，两步独立提交。如果在两步之间退出，或第二步失败后重启，新采样会成为恢复基线，尚未累加的增量将无法补回。

**建议：** 用同一 SQLite 事务提交采样和对应增量；事务成功后再推进内存基线。失败时回滚两项写入，并允许后续刷新恢复。

**验收标准：** 在采样插入后、日桶更新前注入失败，数据库不留下部分提交；重启恢复后，token 和请求增量既不丢失，也不重复累计。

**修复记录（已完成）**

为什么这个半成品状态**无法自愈**：内存基线一旦前移，那段用量就不在任何一次差值的区间里了。所以只要采样行留下、增量没累加，重启后它成为恢复基线，那段 token 就永久丢失——不是"下次补上"，是再也补不回来。

`HistoryStore` 新增 `transaction(_:)`：

- `BEGIN IMMEDIATE` 而非默认的 `DEFERRED` —— 这里必然要写，一开始就拿写锁，把「提交时才发现拿不到锁」提前暴露成开始时失败。
- `COMMIT` 自身失败也走回滚分支，不让连接挂在事务里；`defer` 清标志，保证任何路径都能复位。
- 显式挡掉嵌套（SQLite 不支持），给一句看得懂的错误而不是底层报文。

新增 `Sources/Core/HistoryWriter.swift`，把「判断落盘 → 原子写入 → 推进基线」这段编排从 App 层搬进 Core。搬动的理由不是整洁，而是验收标准要求测「重启恢复」——编排留在 `HistoryRecorder`（`@MainActor`、依赖 `Config`）里就测不到。顺序本身即正确性，三条都不能挪：

1. 先算判断（`shouldStore` / `TokenDelta.between`）再写库，判据不受本次写入影响；
2. 采样行与当天 token 增量在**同一事务**内；
3. 事务提交成功之后才 `ledger.advance` —— 抛错时 `self.ledger` 一个字没动，于是这次的增量会在下一次刷新的差值里重新算进去。

附带两点：两样都没有要写时不开事务（空闲时每分钟一次，没必要为此去拿写锁）；`learnDailyReset` 移到写入成功之后——写失败时这次观测等于没发生，不该拿它改写「日重置在几点」这个学出来的结论。

`HistoryRecorder` 相应瘦身，只剩 App 层才有的事：按账户建库、把 `Snapshot` 拍成 `Sample`、把学到的重置时刻写进偏好、兜住错误；文件头注释已同步。

覆盖测试（总数 143 → 151 全通过）：

- `HistoryStoreTests` 新增 4 例：一起提交、部分写入回滚、回滚后连接仍可用、嵌套被拒。
- 新增 `HistoryWriterTests` 4 例。故障注入用的是**真实存储故障**而非替身：从另一个连接 `DROP TABLE token_days`，于是事务里第一步（采样行）写得进、第二步（日桶）必然失败，正是验收标准点名的注入位置。
  - `testFailureBetweenTheTwoWritesLeavesNoPartialCommit` —— 回滚后库里只剩第一条。
  - `testDeltaSurvivesAFailedRefreshAcrossRestart` —— 重开连接（`migrate` 建回 `token_days`）+ 新 `HistoryWriter` 从库补基线，`1000 → 1500` 恰好累加 500，失败那段的 300 既不丢也不重。
- 另外把 OPT-002 的 `replayRefreshes` 从「测试里复制一份编排」改成驱动真实的 `HistoryWriter` + 真实库，断言读库里的实际内容。消除了测试与产线编排漂移的风险，那 9 例也因此变成端到端。

**反向验证**：临时去掉事务后，两例注入测试如期失败——`sampleCount` 2≠1（残留部分提交）、恢复后 200≠500（正好丢掉那 300）。确认测试真能抓住这个 bug，而非恰好通过。

## OPT-004：无效响应被当作真实零用量

- **优先级：** P2
- **位置：** [Models.swift:125](../Sources/Core/Models.swift#L125)、[HistoryRecorder.swift:51](../Sources/App/HistoryRecorder.swift#L51)
- **证据：** 已验证无效字段被解码为零；后续历史污染由调用链分析确认。

**问题与影响：** `limits` 类型错误、token 字段为非数字字符串时，响应仍会被接受，额度和累计值退回零。下一次正常累计值恢复后，可能被当作新增用量；日额度的虚假下降还可能触发错误的重置学习。

**建议：** 对关键字段区分真实零值、缺失值和无效值。必要字段无效时拒绝更新快照，或保留明确的未知状态；未知数据不得参与历史增量和重置学习。保留对明确可选字段的兼容能力。

**验收标准：** 覆盖缺失、`null`、类型错误，以及“正常响应 → 无效响应 → 正常响应”的序列；无效响应不得制造零采样、累计值突增或错误的重置学习结果。

**修复记录（已完成）**

根因是解码层把**三件事**压成了同一个结果：真实的 0、字段缺失、字段无效——`(try? decode(...)) ?? 0` 一视同仁。新策略把它们拆开：

| 情况 | 处理 | 理由 |
|---|---|---|
| 键存在、类型正确 | 用它 | |
| 键缺失 / 值为 `null` | 容忍解成 0，但标记用量不完整 | 换部署、对方加减字段不该让整份响应失败；用 `null` 表示可选字段为空也很常见 |
| 键存在但类型不对 | **拒绝整份响应** | 这不是「没有」，是数据坏了，没有任何默认值是站得住的 |

刻意不把 `null` 判成无效：为此把整份响应判死太激进，而它造成的危害（被当成真实 0）已由「标记不完整」这条挡住了。同样刻意不做「数字字符串 → 数字」的强制转换：实测响应用的是 JSON 数字，为假想情况加一条转换路径属于凭空发挥；真遇到了，错误信息会点名字段，可排查。

`Sources/Core/Models.swift`：新增 `InvalidFieldError(field:)`，解码辅助改为 `number/integer/text/flag/object/nested`，缺失返回 nil、类型错误抛错。内层的错误原样上抛，所以报出来的是**最里层**那个坏字段而不是笼统的 `usage`。`ResponseDecoder.unwrap` 单独捕获它，配合新增的 L10n 键 `errInvalidFieldFormat`（三语）给出带字段名的提示——对着一个自建中转站，不点名根本没法排查。

沿链路新增完整性标记：`Limits.hasAllCurrentCosts`（四个当前用量）、`UsageBlock.hasAllTotals`（两个累计值，`cost` 不进历史故不计）、汇总为 `UserStats.hasCompleteUsage` → `Snapshot.hasCompleteUsage`。整块缺失（`limits` / `usage` 没给）与块内单字段缺失同等对待。

`HistoryWriter` 新增 `record(_ snapshot:to:)`：用量不完整就整条跳过并返回 `nil`。同时把「快照 → 采样」的映射收进 Core（`Sample.init(_ snapshot:)`），于是整条「快照 → 历史」链路都可测——否则验收标准要求的那个序列只能靠在测试里复制一遍判定逻辑。`HistoryRecorder` 相应只剩 `guard let outcome = try writer.record(...) else { return }`，拿不到 outcome 也就不会去喂日重置学习。

不入库也就不推进基线，所以下一次完整响应的差值会自然跨过这段空缺；真跨得太久（超 30 分钟）则按既有规则当断档丢弃——两头都不会凭空多出用量。

覆盖测试（总数 151 → 166 全通过）：

- `FieldValidityTests` 11 例：类型错误的四种位置（数字字段、`limits` 整块、`usage` 整块、嵌套内层）均被拒且点名正确字段；`unwrap` 的错误信息含字段名；缺失/`null`/整块缺失均标记不完整；**可选字段缺失不得被误判成不完整**；实测响应结构仍判为完整（别把真实部署挡在门外）。
- `IncompleteResponseTests` 4 例：验收标准点名的「正常 → 无效 → 正常」序列，逐条对应三项危害——无零采样（`[42, 45]` 而非 `[42, 0, 45]`）、无用量突增（累加 200 而非 1200）、无错误重置学习（恢复那次拿到的上一条仍是 42）。最后一例还附了反证：那次假下降**确实**会被 `DailyResetLearner` 学成重置，所以跳过它是必须的而非保险起见。
- 原有 5 例解码测试（含 `testNullValuesFallBackToZero`、`testMissingUsageBlockDoesNotFail`）**全部保留通过**，确认向后兼容。

**反向验证**：临时去掉完整性闸门后，四例序列测试如期失败，数字与预测一致——`[42.0, 0.0, 45.0] ≠ [42.0, 45.0]`、`1200.0 ≠ 200.0`、`previous` 被污染成 `0.0` 而非 `42.0`。

## OPT-005：通知未成功提交便记录为已发送

- **优先级：** P2
- **位置：** [Notifier.swift:42](../Sources/App/Notifier.swift#L42)、[Notifier.swift:93](../Sources/App/Notifier.swift#L93)
- **证据：** 静态代码分析；未执行系统通知实际投递验证。

**问题与影响：** 权限申请尚未完成便开始投递，且不论权限是否允许、提交是否失败，都立即保存去重键。失败通知因此在当前周期内无法重试。

**建议：** 等待并检查授权结果；仅在系统成功接受通知请求后保存去重记录。区分提交中、提交成功和失败状态，防止异步等待期间重复提交，并让失败具备重试机会。

**验收标准：** 首次授权、拒绝权限、提交失败后恢复等路径均有覆盖；拒绝或失败不留下成功去重记录，同周期成功提交后不重复通知。

**修复记录（与 OPT-006 合并完成）**

两个缺陷都确认了：`requestAuthorizationIfNeeded()` 是 fire-and-forget（不 await、不看 `granted`），而 `keys.append(alert.dedupeKey)` 在 `deliver()` 之后**无条件**执行——权限被拒或系统拒收，照样记成「已发过」，于是这一整个周期内再也不会重试。

去重逻辑整体上移到 Core 的 `AlertLedger`（见 OPT-006），状态机分三步：

| 步骤 | 语义 |
|---|---|
| `beginDelivery` | 占位。投递要等权限和系统回执，期间下一次刷新会算出同一条告警 |
| `confirm` | 系统**确实收下**了——到这一步才记进账本 |
| `abandon` | 被拒 / 提交失败——**不留记录**，同周期内下次刷新还能重试 |

在途状态 `delivering` **刻意不持久化**：进程没了，途中的提交也就没了；持久化它会让那条告警永远卡在「在途」再也发不出去。已加测试钉住。

权限改为每次读**真实状态**（`notificationSettings().authorizationStatus`）而非缓存布尔量——用户可能在系统设置里改过，缓存就再也看不见了；`.notDetermined` 时才 `await requestAuthorization()`。顺带删掉了 `didRequestAuthorization`，`.notDetermined` 本来就只会出现一次。

投递跨过 `await` 之后要先验账户身份（`update(namespace:)` 返回 false 即整批丢掉）——和刷新、测试连接同一个道理。

覆盖测试：`AlertLedgerDeliveryTests` 9 例。**反向验证**：把 `abandon` 改成记账，两例如期失败（`["lowQuota|total|1788796800"] ≠ []`，且重试被挡）。

## OPT-006：通知去重缺少账户维度

- **优先级：** P2
- **位置：** [AlertPolicy.swift:35](../Sources/Core/AlertPolicy.swift#L35)、[Notifier.swift:21](../Sources/App/Notifier.swift#L21)
- **证据：** 已确认去重键不含账户信息；跨账户过滤行为由调用链分析确认。

**问题与影响：** 去重键只有告警类型、额度类型和周期起点，已发送记录又全局共享。A 在某周期收到低额度通知后，切到相同周期的 B，B 的对应告警会被过滤。

**建议：** 在去重命名空间中加入服务地址和账户标识，或按账户分别存储去重记录，并明确旧记录的迁移策略。

**验收标准：** 同周期、同类型的告警在两个账户中各自允许首次发送；切回原账户后，该账户已成功发送的告警仍然去重。

**修复记录（与 OPT-005 合并完成）**

`AccountIdentity` 新增 `notificationNamespace` —— 本项目的**第三种键口径**，取完整身份（供应商 + 服务地址 + 账户标识）：

| 用途 | 键 | 组成 | 为什么 |
|---|---|---|---|
| 历史 | `storageKey` | 仅 apiId | 中继换网址还是同一份用量 |
| 配置 | `preferenceKey` | baseURL + apiId | 「日重置在几点」是那个部署的配置 |
| **通知** | `notificationNamespace` | providerID + baseURL + apiId | 见下 |

通知这一处能用最严格的口径，是因为它**没有迁移成本**：历史换键会孤立掉用户攒下的曲线，偏好换键会丢掉学到的重置时刻，而去重账本最坏只是多发一条通知。方向也对——宁可重复提醒，不可漏报。旧的全局账本同理直接丢弃（`discardLegacyGlobalLedger`），不做迁移。

`AlertPolicy.newAlerts` **已删除**：去重从此只有账本一条路径，不留两处平行实现供日后漂移。原有 4 例去重测试迁到账本上，断言意图不变。

顺带撤掉 OPT-001 里留的那个缓解：`applyAccount` 不再清空通知账本，改为 `accountDidChange()` 只丢掉内存里那本。命名空间本身就隔离了，而且**切回旧账户时它已发过的告警仍该去重**——这正是「切换即清空」做不到的，也是本条验收标准的后半句。

覆盖测试：`AlertLedgerAccountScopeTests` 5 例。

**反向验证中发现我自己一个弱测试**，值得记下来：最初那两例用了两个独立的 `AlertLedger` 实例，各有各的数组——去掉命名空间它们照样互不干扰，所以**反向验证全部通过了**，等于没验到。真实现场是两个账户**共用一份存储**。补了 `testRecordsFromAnotherAccountDoNotSilenceThisOne`：把 A 的记录原样喂给 B 的账本，此时缺陷版本如期失败。

## OPT-007：日重置学习结果跨账户共享

- **优先级：** P2
- **位置：** [Config.swift:82](../Sources/App/Config.swift#L82)、[HistoryRecorder.swift:71](../Sources/App/HistoryRecorder.swift#L71)
- **证据：** 静态代码分析。

**问题与影响：** 日重置小时保存在全局偏好中。切换账户后，A 的学习结果直接用于 B；学习逻辑发现已有值便退出，错误规则可能长期影响倒计时、速度判断及推算标记。系统时区变化也可能使保存的本地小时失效。

**建议：** 按服务地址、账户和相关时区保存学习结果，并设置配置变化、时区变化和观测矛盾时的失效或重新学习机制。

**验收标准：** 不同重置时间的账户互不污染；切换账户或时区后使用正确规则，未知规则保留推算标记，后续可靠观测可更新规则。

**修复记录（已完成）**

这条有**三个**独立缺陷，容易只看到第一个：全局共享、学到一次就封存、以及本地小时脱离时区后失效。

`Sources/Core/ResetSchedule.swift` 新增 `LearnedDailyReset`：把小时数、**学到它时的时区**和那次观测的误差范围一起存。时区必须是结论的一部分——从上海搬到纽约后，「0 点重置」不再指向同一个瞬间，可它看上去依然像个确定值，于是倒计时和 pace 一起错，界面却不再标注「推算」。配套 `applies(in:)` 判断结论是否仍然成立。

新增 `DailyResetLearner.reconcile(stored:observation:timeZone:)`，返回 nil 表示不必写盘：

- 没有结论 → 采纳
- 时区变了 → 采纳新的（旧结论前提已不成立）
- 小时数相同 → 不动（否则每天重置一次就重复写一遍同样的值）
- 小时数不同 → **采纳新的**。计数器归零是没有歧义的事件：它现在发生在 14 点，重置时刻现在就是 14 点。中转站改配置、用户换套餐都会这样，固守旧值等于拿上个月的证据否决眼前的观测

`AccountIdentity` 新增 `preferenceKey`，这是本条的**第三个刻意区分的键口径**：

| 键 | 组成 | 理由 |
|---|---|---|
| 刷新身份（`==`） | baseURL + apiId | 发往别处的请求，旧响应不能算数 |
| `storageKey`（历史分区） | 仅 apiId | 中继换网址还是同一份用量，曲线不该被割成两半 |
| `preferenceKey`（偏好分区） | baseURL + apiId | 「日重置在几点」是**那个部署的配置**，换地址不能假定照旧 |

`AccountKey` 增加多段派生 `derive(_ parts:)`，用 `\n` 连接以避免「`a`+`bc` 与 `ab`+`c` 撞键」；单段结果与原 `derive(apiId:)` **完全一致**——它是历史表的分区键，一变就等于把所有老用户的历史丢掉（已加测试钉住）。

`Config` 把全局 `observedDailyResetHour` 换成按 `preferenceKey` 分区的记录，读取时若时区已变则视作没学过（界面如实标回「推算」，下次观测到重置再学）。`schedule` 改为 `schedule(for: account)`，`UsageService.refresh()` 用开头定住的那个身份取——顺带补掉了一处 OPT-001 同类的「刷新中途回头读全局配置」。`HistoryRecorder.learnDailyReset` 去掉 `== nil` 的早退，改为每次观测都走 `reconcile`。

旧的全局键**刻意不迁移**，由 `discardLegacyGlobalResetHour()` 在启动时清掉：那个值不知道是从哪个账户学来的，把它安到某个账户头上等于把同一个 bug 再犯一遍。丢掉后各账户自己重学，期间界面如实标注「推算」。

覆盖测试（总数 166 → 178 全通过）：`LearnedDailyResetTests` 6 例（时区前提、首次采纳、同值不写盘、矛盾观测更新规则、时区变更作废、未知规则保留推算标记）+ `AccountKeyScopeTests` 6 例（三种键口径的区分、不泄露原文、单段派生与旧键一致、拼接无歧义）。

**反向验证**：把 `preferenceKey` 退化成只看 apiId（即「漏掉服务地址」这个最可能犯的错），`testPreferenceKeyDistinguishesTheEndpoint` 如期失败。

**未包含**：`ResetSchedule.timeZone` 仍默认取本机时区。服务端重置所依据的时区不一定等于本机——这属于 EXT-004「服务端时区不默认等于本机时区」的范围，本条只保证「时区变了不再拿旧结论假装确定」。

## OPT-008：当前额度上限改写历史百分比

- **优先级：** P2
- **位置：** [ChartSeries.swift:62](../Sources/Core/ChartSeries.swift#L62)、[HistoryModels.swift:16](../Sources/Core/HistoryModels.swift#L16)
- **证据：** 静态代码分析。

**问题与影响：** 历史采样只保存消费金额，图表统一除以当前额度上限。过去使用 `50/100`、剩余 50% 的采样，在额度升级到 200 后会显示剩余 75%，使历史状态被追溯改写。

**建议：** 保存采样时的额度上限，按各采样自己的上限计算百分比；也可改为展示金额历史。旧数据缺少上限时应明确处理，避免把当前上限当作历史事实。

**验收标准：** 调高、调低或取消额度上限后，已有历史点的含义不被静默改变；数据库迁移和旧数据展示行为有明确验证。

**修复记录（已完成）**

历史里存的应该是「当时花了多少、**当时的上限是多少**」这个事实。事后拿现在的上限去除历史金额，等于把过去按今天重写一遍：50/100（剩 50%）在上限调到 200 之后显示成剩 75%，那一刻的紧张程度凭空消失；调低则反过来，凭空制造紧张。

新增 `QuotaLimits` 并挂到 `Sample.limits`，类型是 **Optional**，这个可选性是本条的关键：

| 值 | 含义 | 画图行为 |
|---|---|---|
| `QuotaLimits(daily: 70, …)` | 当时上限 70 | 正常算百分比 |
| `QuotaLimits(daily: 0, …)` | 当时**不限额** | 不画 —— 没有上限就没有剩余百分比 |
| `nil` | **不知道**（升级前的老记录没记过） | 不画 —— 而不是拿当前上限顶上 |

后两者必须分开：一个是「当时没有上限」，一个是「我们不知道当时的上限」。压成同一个值就又回到了编造历史。

`QuotaSeriesBuilder.build` 去掉了 `limit:` 参数，改为每个点用**自己那条采样**的上限；算不出百分比的点直接跳过（`compactMap`），并且跳过不影响段号分配（已加测试）。`Sample.differs` 刻意仍只比用量——上限变了不代表有新消费，不该因此多落一条采样。

**迁移机制**（本轮一并建起来，EXT-005 / EXT-009 会直接用）：`HistoryStore` 引入 `PRAGMA user_version`，`schemaVersion = 2`，v1 → v2 用 `ALTER TABLE ADD COLUMN` 补四列。老行留 NULL，**刻意不回填当前上限**——那等于把今天的配额说成当时的事实。`addColumnIfMissing` 先查 `PRAGMA table_info` 再加，所以迁移幂等。

读取侧：四列任一为 NULL 就整组判为未知——半组上限拼不出一条完整的历史事实。

覆盖测试：`HistoricalLimitTests` 7 例 + `SchemaMigrationTests` 4 例（总数 262 → 273 全通过）。其中 `testUpgradingFromV1LeavesOldRowsUnknown` 用原始 sqlite3 造了一个**真正的 v1 库**（只有旧八列、`user_version = 0`）再打开，验证老数据还在、老行上限为 nil、新行照常带上限。

**反向验证**：①改回「统一除以当前上限」→ 5 例失败，其中 `期望 0.75 ≈ 0.5` 正是本条描述的症状；②让 NULL 读成 0 → 2 例失败，老行被误判成「不限额」。

过程中发现并修掉了测试自身的一个问题：断言用强制下标 `points[0]`，数组为空时会让整个进程崩溃而不是报失败——这个精简测试框架没有进程隔离。已全部改为 `points.first?`，反向验证才能拿到干净的失败清单。

**未包含**：`samples` 表仍是四个固定额度列。改成高表（`bucket_id`）要等 EXT-001 的额度桶 taxonomy 真正落地——`QuotaKind` 现在还是固定四项，现在改高表一点动态性也买不到，却要重构整片已充分测试的历史代码。迁移机制已就位，那时走第二次迁移很便宜。

## OPT-009：图表刷新依赖不完整

- **优先级：** P2
- **位置：** [HistoryWindow.swift:68](../Sources/App/HistoryWindow.swift#L68)、[PopoverView.swift:200](../Sources/App/PopoverView.swift#L200)
- **证据：** 静态视图依赖分析；未进行 GUI 交互验证。

**问题与影响：** 独立历史窗口仅在出现、额度类型变化和时间范围变化时重新加载，不随新快照刷新。面板切换额度来源时，标题立即变化，曲线却要等下一次网络刷新，可能出现标题与数据不一致。

**建议：** 将账户、快照、所选额度及影响绘图的配置纳入刷新依赖，统一图表数据与标题的更新时机。

**验收标准：** 保持历史窗口打开时，新采样及时出现；切换账户或额度来源后，标题、曲线、上限和汇总同步更新，无须等待下一次定时请求或手动重开窗口。

**修复记录（已完成）**

实际缺口是**三处**而非文档写的两处，且分布在两个视图上：

| 视图 | 已有依赖 | 缺 |
|---|---|---|
| `HistoryView`（独立窗口） | `onAppear` / `kind` / `days` | 新快照、账户 |
| `PopoverView`（面板） | `onAppear` / `snapshot?.fetchedAt` | **额度来源**、账户 |

第三处正是条目正文点名的那个症状——「面板切换额度来源时标题立即变化，曲线却要等下一次网络刷新」。它不在 `HistoryWindow`，而在 `PopoverView`：`reloadHistory` 读的是 `service.menuBarGauge`，而标题是在 body 里现算的，于是那段时间里标题说的是一条额度、曲线画的是另一条。

**账户这一维需要一个独立信号。** `UsageService` 新增 `@Published private(set) var accountGeneration`，在 `applyAccount` 里账户确实变了才 +1，且**放在 `HistoryRecorder.accountDidChange()` 之后**——先换库再通知界面，否则那次重读拿到的还是旧库。

两个刻意的取舍：

- **是计数器，不是账户的副本。** 存一份 `AccountIdentity` 在 service 上会和 `Config.account` 这个唯一事实并列，迟早漂移（不变量 5）。计数器不是任何东西的副本，只表达「换过一次」这一件事。
- **不能省略成「看快照变化」。** 这是本条最容易漏的一点：两个账户都离线时 `snapshot` 前后都是 nil，`applyAccount` 里那几个 `= nil` 赋值不产生任何可观察的变化，窗口会一直画着上一个账户的曲线。所以两条 `onChange` 都必须在。

**顺带修掉一个超出本条范围的缺陷（用户确认后一并做）：`HistoryView` 拿当前上限决定历史画不画。**

原先是 `if limit <= 0 { 显示「没设上限」}`，其中 `limit` 取自**当前**快照。这跟 OPT-008 确立的口径已经对不上：历史点各用各当时的上限，「现在不限额」不等于「历史点画不出来」。用户今天把额度改成不限额，昨天那段本来完全画得出的曲线会整段消失，被一句「没设上限」盖掉——正是 OPT-008 要根除的那类「拿今天改写过去」。

判据改为由**点本身**决定。但空点数组有两种原因，而它自己区分不出来：

| 情况 | 用户该去查什么 |
|---|---|
| 这段时间根本没有采样 | app 那阵子在不在跑 |
| 有采样，但一条都算不出百分比（当时不限额 / 升级前的老记录没记过上限） | 额度配置 |

只看点数组就只能二选一地说，必然有一半场合在撒谎。所以 `HistoryModel` 增加第二个信号 `quotaSamplesInRange`（范围内的采样条数，不管画不画得出），两个信号合起来才能说对。面板缩略图同理，新增 `chartNoPercentage` 一句短文案。

文案跟着判据一起改：`historyNoLimitMessage` 原文说的是「这条额度没有设上限」——那是在描述**当前配置**。判据换成采样之后不改文案就会把两件事说反（现在设了上限，不代表当时也设了）。三语同步重写。

另清掉一个死参数：`HistoryModel.reload` 的 `limit:` 自 OPT-008 把上限从 `QuotaSeriesBuilder.build` 拿掉后，函数体里就再没用过，两个调用点还在算它传它。已删除，并在文档注释里写明「刻意不收当前上限」，免得以后又被加回来。

覆盖测试：`HistoricalLimitTests` 新增 `testAnEmptyCurveDoesNotRevealWhyItIsEmpty`（总数 320 → 321 全通过），把「单看点数组分不出三种空」这个事实钉住——它是 `quotaSamplesInRange` 存在的全部理由，没有它，后人很容易把这个"多余"的信号删掉。

**反向验证**：临时让未知上限用兜底值顶上（即 OPT-008 那个缺陷的形状）→ 7 例失败，含新增这例。还原后 321 全绿。

**验证缺口（要紧）**：本条的主体是 SwiftUI 的视图依赖，这个测试框架碰不到，**三处 `onChange` 的实际触发行为未经运行验证**——只有全量 typecheck 与 `./build.sh` 通过（产物 arm64 / minos 13.0 / ad-hoc 签名）。要真正确认验收标准，需要配一个真实中转站账户，开着历史窗口等一次定时刷新、切一次额度来源、切一次账户各看一遍。能进 Core 的那部分（空曲线的三种成因）已单测覆盖。

## OPT-010：过期窗口仍给出正常速度判断

- **优先级：** P2
- **位置：** [Quota.swift:155](../Sources/Core/Quota.swift#L155)
- **证据：** 已通过核心逻辑调用复现。

**问题与影响：** 窗口结束后，剩余时间归零，旧额度仍参与速度计算，得到 `onPace`。复现中，已用 70% 的旧采样在窗口结束后仍显示正常速度。断网跨过重置时间时，这会给出缺少当前周期数据支持的判断。

**建议：** 对不包含当前时刻的窗口返回不可判断状态；旧快照可以继续展示，但应明确其过期属性，等待新周期采样后恢复速度判断。

**验收标准：** 覆盖窗口开始前、窗口内、结束边界和结束后的判断；断网跨周期时不显示未经新数据支持的正常状态，刷新成功后恢复。

**修复记录（随 EXT-004 一并完成）**

`Gauge.pace` 增加 `window.contains(now)` 守卫（右端开区间：走到 `end` 就已属于下一个周期）。新增 `TimeWindow.contains(_:)` 取代被删掉的 `cycleStart`。

关键在于这句「正常」**没有任何当期数据支撑**：窗口走完后剩余时间归零，于是任何还有余额的旧数据都会算成 onPace——那纯粹是过期窗口的算术副产品。旧快照可以继续显示数字，但不该配一个它撑不起的判断。

`status(now:)` 不受影响：「剩余不足」是纯额度判断，过期窗口下仍然成立，只有「超速」会随 pace 一起变成不可判断。

另有一处配套决定：限流窗口的 `windowInterval` **刻意不外推**。`ResetSchedule.windowRule` 能按固定时长往回推（历史图要用），但当前窗口仍只认服务端说的那一段——否则过期时会外推出一个包含此刻的新周期，把上一个周期的用量安到新周期头上，比原 bug 更糟。

覆盖测试：`ExpiredWindowPaceTests` 5 例（窗口内、已过期、恰在终点、开始之前、以及 status 仍报 critical）。**反向验证**：去掉守卫后三例如期失败，已用 70% 的过期采样确实算成 `onPace(delta: 0.3)`。

## OPT-011：夏令时附近的历史周期反推错误

- **优先级：** P2
- **位置：** [Quota.swift:48](../Sources/Core/Quota.swift#L48)、[HistoryCharts.swift:61](../Sources/App/HistoryCharts.swift#L61)
- **证据：** 已使用固定日期及 `America/New_York` 时区复现。

**问题与影响：** 历史周期通过重复减去当前窗口的秒数长度反推，假定所有周期等长。纽约 2026 年春季夏令时切换日的窗口长 23 小时，反推前一天的起点得到 01:00，而非 00:00，导致重置连接线起点错误或被有效性检查丢弃。

**建议：** 对日、周周期使用对应时区的日历规则计算历史边界；仅对确实固定时长的窗口使用秒数运算。

**验收标准：** 覆盖春季和秋季夏令时切换、普通日期，以及日和周周期；历史边界符合当地日历规则，固定时长窗口保持正确。

**修复记录（随 EXT-004 一并完成）**

根因是**只有一种算法**：`TimeWindow.cycleStart` 拿当前窗口的秒数长度反复往回减，假定所有周期等长。该算法对限流窗口这类按绝对秒计的周期是对的，错在它被无差别用在「每天当地 0 点」上。

修法即 EXT-004 的核心区分：`calendarDaily` / `calendarWeekly` 用日历运算，`fixedDuration` 才用秒数运算。`TimeWindow.cycleStart` **已删除**——留着它就是留一个会被再次误用的坑；原有 5 例测试改写到 `ResetPolicy.fixedDuration` 上，断言意图原样保留。

历史图的重置虚线改由 `Gauge.rule` 按各自算法反推（`HistoryModel.reload` 的参数从 `window:` 改为 `rule:`）；规则算不出周期时就不画，而不是画一条错的。

覆盖测试：`DaylightSavingTests` 5 例。其中最能说明问题的是 `testCalendarAndFixedDurationDivergeAfterTheTransition`——注意错位出现在切换日的**次日**：3/8 那段仍从当地 0 点开始（+86400 秒还落在切换生效之前），但那天只有 23 小时，于是下一段固定时长漂到当地 1 点，而「每天 0 点」照旧是 0 点。另有春/秋两季的 23 小时与 25 小时断言。

**反向验证**：把日历加法换回秒数加法，两例时长断言如期失败（82800 / 90000 ≠ 86400）。

## OPT-012：部分采样画不出时，曲线不说明缺了什么

- **优先级：** P2
- **追加日期：** 2026-09-21（非原审查范围）
- **位置：** [HistoryWindow.swift:131](../Sources/App/HistoryWindow.swift#L131)、[HistoryCharts.swift:53](../Sources/App/HistoryCharts.swift#L53)
- **证据：** 用户实机截图 —— 30 天范围内 1,025 条采样，曲线却只有最右端一小段，其余大片空白，界面对此一字未提。

**问题与影响：** OPT-009 建立了 `quotaSamplesInRange` 这个第二信号，用来区分「这段时间根本没有采样」和「有采样但一条都算不出百分比」。但那套判断**只在 `quotaPoints` 完全为空时才生效**：

```
if !quotaPoints.isEmpty        → 画曲线（什么都不说）
else if 范围内有采样            → 「这段时间的采样都算不出剩余百分比…」
else                           → 「这段时间还没有采样」
```

于是第三种情况落在了判断之外：**范围内一部分采样画得出、一部分画不出**。只要有一个点画得出，曲线就照画，那 N 条画不出的采样既不在曲线上、也不在任何一句文案里，完全消失。

这正是 OPT-008 升级后老用户必然会遇到的形态：升级前的采样没记过当时的上限（`limits == nil`），升级后的记了。在新采样填满窗口之前，30 天视图里必然是「少量画得出 + 大量画不出」。用户看到的是一张几乎空白的图，而 app 的解释是沉默 —— 他会去排查一个并不存在的问题（app 是不是没在跑、是不是漏采了），而真实原因只是那些采样不带上限。

这条与 OPT-008 的「用户可见影响」是同一件事的两半：那里决定了**不拿今天的上限改写过去**（正确），这里欠的是**把这个代价如实说出来**。沉默不算撒谎，但它让用户自己编了一个错误的解释。

**建议：** 让「画不出的采样有多少」成为一个显式信号，而不是靠 `总数 − 点数` 由读者心算。曲线画得出时，在图下如实说明另有多少条采样无法绘制。

成因**不要替用户挑一个**：`limits == nil`（不知道当时的上限）与 `limits.value == 0`（当时确实不限额）是两回事，现有的 `historyNoLimitMessage` 已经确立了口径 —— 把两种可能都说出来，不断言是哪一种。新文案沿用同一口径，不要另造一套说法，更不要因为「多数情况是老记录」就只写老记录。

**验收标准：** 混合情况（部分画得出、部分画不出）下，界面明确给出画不出的条数；全部画不出与完全没有采样两种情况的现有文案不受影响，也不重复出现；画不出的条数与实际跳过的采样数一致；三种语言同步。

**修复记录（已完成）**

`HistoryModel` 增加 `quotaSamplesWithoutPercentage`，取值即 `采样数 − 点数`。

差额本身是个减法，但**必须落成一个有名字的信号**，理由和 OPT-009 当初给 `quotaSamplesInRange` 起名时一样：算式写在视图里，下一个人看不出它在回答什么问题，很容易当成冗余顺手删掉。两个信号现在各管一段——前者回答「空曲线为什么空」，后者回答「非空曲线画全了没有」。

历史窗口在曲线下多一行，**仅当曲线画得出来且差额大于 0 时出现**，与原有的两条空曲线文案互斥，不会重复。

文案 `historyNoPercentageCountFormat` 三语同步。**刻意不挑成因**：采样画不出有两种原因——当时不限额、或升级前的老记录没记过上限——照 `historyNoLimitMessage` 已确立的口径把两种可能都摆出来。你这一轮多半全是老记录，但「多半」不是「全部」，按多数写死就是在断言我们并不知道的事，正是本项目一路在修的那类 bug。

覆盖测试：`ChartSeriesTests` 新增 `testAPartialCurveDoesNotRevealWhatItSkipped`（总数 321 → 322 全通过）。它和 OPT-009 那例是一对：那例说曲线为空时看不出为什么空，这例说曲线**非空时看不出它跳过了什么**——首点直接是第 7 条采样，看不出前面还有 6 条；段号也指望不上，它同时被重置和空档推进，本就不是「跳过了几条」的计数。这是新信号存在的全部理由。

三语完整性与占位符数量由既有的 `LocalizationTests` 自动覆盖（`testEveryKeyIsTranslatedInEveryLanguage` / `testNoTranslationIsEmpty` / `testPlaceholderCountsMatchAcrossLanguages`），新键无需另写用例。

**反向验证**：把未知上限改成拿默认值顶上（即 OPT-008 那个缺陷的形状）→ 8 例失败，新增这例在列；还原后 322 全绿。

**未包含（刻意）**：

- **面板里的缩略图不加这一行。** 46pt 高，塞进去会把曲线挤没；且缩略图只看 24 小时，撞上混合情形的概率远低于 30 天视图。缩略图仍保留原有的 `chartNoPercentage`（全空时）。
- **不为「有采样但画不出」的区间单独上一种底色。** 图上已经有空档阴影、重置虚线、推算边界三种画法，再加一种要新造视觉语言，而一行字已经说清。注意这些区间**不是空档**——那段时间确实采到了，只是画不出来，用空档阴影去表示它反而是错的。
- **不回填历史上限。** 那是 OPT-008 明令禁止的，本条只负责把它的代价如实说出来。

**验证缺口**：这一行的实际渲染（换行、与坐标轴的间距）未经运行验证，只有全量 typecheck 与 `./build.sh` 通过。纯文字、无坐标与配色，风险低，但要确认外观仍需实机一眼。

## 验证记录与边界

- `swift run CoreTests`：119 个测试通过，0 个失败。
- 完整应用使用本机 macOS 26.5 SDK 编译成功，目标仍为 `arm64-apple-macos13.0`。
- 当前默认 SDK 下编译遇到缺失 `SwiftUIMacros` 的工具链问题；未将其归为上述源码缺陷。
- `bash -n build.sh` 和 `plutil -lint Info.plist` 均通过。
- 针对性复现使用临时程序及模拟边界，未连接真实中转站，未修改用户配置或历史数据库。
- 尚未验证真实服务兼容性、系统通知实际投递和 GUI 交互；源码中采用的“服务端重置时区与本机一致”假设仍需确认。
- 现有测试主要覆盖 Core 层。建议优先增加刷新、账户切换、持久化事务及通知异步流程的集成测试。

## 建议处理顺序

1. 先处理 OPT-001 至 OPT-004，修复账户归属和历史数据完整性问题。
2. 处理 OPT-005 至 OPT-007，补齐通知生命周期与账户状态隔离。
3. 处理 OPT-008 至 OPT-011，修复历史展示、刷新依赖和时间边界。

完成单项后，补充对应验证结果，再勾选进度总览中的任务。

---

## 第二轮审查（2026-09-29 / 30）

审查基线：`61f6821`（v2.2）。来源：外部全项目审查报告（10 项，均已对照当前代码逐条确认），加上本轮 App 层 / Core 层两路独立复查的新增项。格式沿用上面的条目。

处理分批（按依赖排序）：① 测试可信与存储边界 → ② 历史数据正确性 → ③ 凭据与设置流程 → ④ 跨 `await` 身份 → ⑤ 日历、图表、告警边界 → ⑥ 界面与文档。

## OPT-013：浮点容差断言把 NaN 判为通过

- **优先级：** P2
- **位置：** [TestSupport.swift:102](../Tests/CoreTests/TestSupport.swift#L102)
- **证据：** 审查中编译原测试框架实测：`XCTAssertEqual(.nan, 0.5, accuracy:)` 与 `XCTAssertEqual(0.5, .nan, accuracy:)` 失败数均为 0。

**问题与影响：** 断言写成 `guard abs(x - y) > accuracy else { return }`，NaN 参与的比较恒为 false，于是直接判通过。全套 78 处容差断言（额度比例、日期窗口、图表）都失去对 NaN 回归的防护，`QuotaTests` 里防除零那例正是要抓 NaN 的。

**建议：** 按正向条件判成功（`x == y` 或 `abs(x - y) <= accuracy`），NaN 显式失败；为框架自身补有限数 / NaN / 无穷大的语义用例。

**验收标准：** NaN 任一侧都报失败；相等的无穷大通过；现有 458 例仍全绿（若有转红，说明原本就被放过，逐条查清）。

**修复记录（已完成，2026-09-30）**

`TestSupport.swift` 的容差断言改成按成功条件判：`x == y || abs(x - y) <= accuracy` 才返回，其余一律报失败。`x == y` 那一支是给同号无穷大的 —— 它俩相减是 NaN，只靠容差会误判成不等。

新增 `TestSupportTests.swift`，4 例测框架自身（容差内、容差外、NaN 任一侧和两侧、无穷大）。做法是照常调用断言，事后数它往失败列表里记了几条再摘掉，免得「期望它失败」被运行器当成用例本身失败。

**原有 458 例在新断言下无一转红** —— 目前没有 NaN 被放过，这条修的是往后的防护。总数 458 → 462。

**反向验证**：把断言改回旧写法 → `testAccuracyAssertionRejectsNaN` 变红；还原后全绿。

## OPT-014：请求计数按 Int32 读写 SQLite

- **优先级：** P2（低触发）
- **位置：** [HistoryStore.swift:320](../Sources/Core/HistoryStore.swift#L320)，同类 380、401、424、511、521、592 行
- **证据：** 审查中向临时库写 `requests = 2^31`，进程 fatal trap（不可被 catch）；两次聚合 `2^31−1 + 1` 读回 `-2147483648`。

**问题与影响：** 模型与解码都是 64 位 `Int`，落库前强转 `Int32`。上游返回一个大数（或错误的大数）就能让整个 app 退出。

**建议：** 统一 `sqlite3_bind_int64` / `sqlite3_column_int64`。

**验收标准：** 2^31 的插入、日桶聚合、未归属聚合、重启后基线恢复都得到原值。

**修复记录（已完成，2026-09-30）**

`HistoryStore` 里请求数的三处写入改 `sqlite3_bind_int64`，四处读取改 `sqlite3_column_int64`（`sampleCount` 顺带一起改了）。`user_version` 那处本来就是 32 位的 pragma，不动。无需迁移：SQLite 的 INTEGER 列本来就按 64 位存，旧数据读出来不变。

新增 `HistoryStoreTests.testRequestCountsBeyond32BitsRoundTrip`：2^31 的插入读回、两次日桶聚合到 2^31、未归属聚合、重开库后的 `lastSample`。总数 → 463。

**反向验证**：换回旧文件 → 进程在这条用例上 `Fatal error: Not enough bits to represent the passed value` 直接退出，正是审查描述的那种不可捕获的崩溃；还原后全绿。

## OPT-015：sub2api / claude-code-hub 把缺失用量当成完整数据

- **优先级：** P1
- **位置：** [Sub2APIProvider.swift:186](../Sources/Core/Sub2APIProvider.swift#L186)、[ClaudeCodeHubProvider.swift:274](../Sources/Core/ClaudeCodeHubProvider.swift#L274)、[HistoryWriter.swift:129](../Sources/Core/HistoryWriter.swift#L129)
- **证据：** 审查中以真实解码 → `buildSnapshot` → `HistoryWriter` → 临时库复现：累计 `1000/100 → 缺失 → 1200/120`，当天记入 `1200 / 120`，正确应为 `200 / 20`。

**问题与影响：** OPT-004 在新适配器里的回归，违反不变量 3。

1. sub2api 只要有一条额度就 `hasCompleteUsage = true`；`usage.total` 缺失或为 null 时，`Sample.init` 把 nil 累计值退成 0 入库并推进基线，下一次恢复的累计值整段被记成增量，**永久**抬高当天用量。
2. 两家都把「有上限、缺已用值」的额度解成 `used = 0`，显示为满额剩余并入库。

**建议（方案 A，用户 2026-09-30 选定）：** 响应里本该有的累计值缺了，整份快照判为不完整、不入历史（和 Relay 的完整性闸门同一做法）；有上限而缺已用值的额度同样判为不完整。代价是那一次的额度曲线也少一个点 —— 可接受。方案 B（额度照常入库、累计基线单独判有效）需要把 `Sample` 的两列改成可选，暂不做。

**验收标准：** 「正常 → 缺字段 / null → 恢复」序列当天只记真实增量；缺已用值的额度不以 0 入库。

**修复记录（已完成，2026-09-30，方案 A）**

两家的做法都向中转站的 `UserStats.hasCompleteUsage` 看齐：**可以显示，不能入库**。

- **DTO 里的已用值一律改成可选**（sub2api 的 `Amount.used` / `RateWindow.used` / `Subscription.*Used`，CCH 的 `Layer.current*`）。缺了就是 nil，不在解码层补 0。按 0 显示是映射那一层的决定，并且会被记下来。
- **sub2api**：`hasCompleteUsage` = 有额度，且每条有上限的额度都报了已用，且 `usage.total` 的 `total_tokens` 和 `requests` 都在。
- **CCH**：`hasCompleteUsage` = 有额度，且每条有上限的额度都报了已用。这家本来就不报累计 token / 请求数（能力声明里没有），不算缺。上限为 null 的那一档本来就不出桶，它的已用缺不缺不影响完整性。
- 快照不完整时，测试连接照旧会出现「响应缺少部分用量字段，这次的数字不会计入历史」这条提示（`ConnectionReport.Finding.incompleteUsage`，现成的）。

新增测试 6 例（总数 → 469）：
- sub2api：`1000 → 缺 → 1200` 序列经真实的 `HistoryWriter` 和临时库，当天记 200 / 20；null 累计值判为不完整；有上限、缺已用值（key 限额和订阅日额度各一例）判为不完整，且面板上显示 0；字段齐全的真实形状仍完整（防止靠「一律判不完整」蒙混过关）。
- CCH：有上限、缺已用值判为不完整；不限的那一档缺已用值不影响完整性。

**反向验证**：两个适配器换回旧文件 → 4 例变红，序列那例精确复现审查的 `1200 / 120`；还原后全绿。

**未做（刻意）**：
- **方案 B**（额度照常入库、累计基线单独判有效）。要把 `Sample` 的两列改成可选，是和阶段 2 同量级的改动，用户选了 A。代价：累计值偶尔缺一次时，那一次的额度曲线也少一个点。
- **待实测确认的一点**：测试样本里「没用过的 key」那份响应（`quotaLimitedUnused`）没有 `usage` 块。如果真实的 sub2api 对某种形态**始终**不返回 `usage.total`，那个账户按现在的判定会一条历史都不落。样本注释说形状照抄实测，但那份明显是节选。下次开实验室时核对：新 key、用过的 key、订阅 key 三种形态是否都带 `usage.total`。

## OPT-016：未验证的陌生站点可直接保存；HTTP 200 的无关 JSON 被当成验证成功

- **优先级：** P2
- **位置：** [SettingsWindow.swift:133](../Sources/App/SettingsWindow.swift#L133)、[Provider.swift:302](../Sources/Core/Provider.swift#L302)、[ClaudeCodeHubProvider.swift:342](../Sources/Core/ClaudeCodeHubProvider.swift#L342)、[Sub2APIProvider.swift:298](../Sources/Core/Sub2APIProvider.swift#L298)
- **证据：** 审查中 `parse(site:key:)` 对陌生站返回 `claude-code-hub, siteMatchIsGuess = true`，`resolvedForSaving(report: nil)` 放行；向 CCH `verify` 注入 `200 {"error":{"message":"not found"}}` 得到成功报告。

**问题与影响：** 两条要一起修 —— 只修后者，用户仍能不点测试直接保存。

1. 陌生网址默认解析成排在前面的 CCH，身份由 key 哈希直接算出，所以无需测试即可保存。若真实服务是 sub2api，此后每次刷新都按 CCH 请求，永远失败。
2. 两家 DTO 的所有协议字段都可缺失，任意 JSON 对象都解码成默认值；测试流程在第一家「成功」后就停，不再试下一家。

**建议：** 「身份已知」和「协议已确认」分开：`siteMatchIsGuess` 的连接必须持有匹配当前输入的成功验证才能保存。两家解码要求最低限度的协议特征字段，缺则按「不是这个协议」报错。

**验收标准：** 陌生站点未测试 / 测试失败时保存按钮不可用；无关 JSON 与空对象被拒，且测试会继续尝试下一家。

**修复记录（已完成，2026-09-30）**

- **保存门**：`ProviderRegistry.resolvedForSaving` 对 `siteMatchIsGuess` 的适配器多一道门：必须带着**同一家**的成功报告才放行。设置窗口本来就在输入改变时清掉报告和已验证连接，所以「同一家」加上「输入没变」就等于「这个连接验过」。专门认得的站点（中转站统计页）不受影响，照旧解析出来就能存。
- **保存按钮灰着的理由分开说**：新增 `setupMustTestGuess`（「未识别的站点要先测试连接，确认它跑的是哪种软件才能保存」），原来那句「这家的账户标识在响应里」只对 tu-zi 成立。
- **协议特征**：新增 `ProtocolMismatchError`，报给用户的是 `errNotThisProtocolFormat`（「响应不是 X 的格式」）。
  - CCH 要求 `userIsEnabled` 和 `keyIsEnabled` 都在。每份响应都有，而且「能不能用」就靠它俩判断；从前缺了会被解成「账户停用」。
  - sub2api 要求有效标记（`isValid` 或 `status`），并且至少有一种额度块（`quota` / `rate_limits` / `subscription` / `balance`）。实测的四种形状都满足。
  - 测试流程本来就是「抛错就试下一家」，不用改。

新增 4 例（总数 → 475）：陌生站点未验证 / 验了别家时不能存、验了同一家能存；中转站网址仍免验证；sub2api 拒无关 JSON、空对象和只有 `isValid` 的对象，且四种真实形状都认；CCH `verify` 对每个请求都回 `200 {"error":…}` 或 `{}` 时报错。

**反向验证**：去掉保存门、去掉两处协议特征 → 3 例变红；还原后全绿。

**验证缺口**：保存按钮和提示行的实际表现没有实机点过，只过了全量 typecheck。

## OPT-017：「测试连接」在保存前就把 claude-code-hub 会话写进钥匙串

- **优先级：** P2
- **位置：** [ClaudeCodeHubProvider.swift:148](../Sources/Core/ClaudeCodeHubProvider.swift#L148)、[Config.swift:292](../Sources/App/Config.swift#L292)
- **证据：** 静态调用链（未操作真实钥匙串）。

**问题与影响：** 设置页用正式适配器验证，而启动时全局会话存储已换成钥匙串实现。登录换到令牌后立刻落盘，发生在额度请求和解码之前。取消、改输入、验证失败都会留下一份可代表用户身份 7 天的凭据；没存档的账户在界面上删不掉。与 README「测试连接什么都不保存」直接冲突。

**建议：** 测试用独立的内存会话存储；保存成功后把会话移交给正式存储，否则丢弃。已保存账户的复用策略不变。

**验收标准：** 测试成功但不保存、登录成功但额度失败，两种情况钥匙串里都没有会话；测试后保存，会话被接管，刷新不必重新登录。

**修复记录（已完成，2026-09-30）**

- 适配器协议新增 `sessionScoped(to:)`：返回一个会话只进给定存储的同一适配器。默认实现返回自己，CCH 覆写成带注入存储的新实例。通用层对谁都这么调，不必认识哪家要会话（不变量 6）。
- 设置窗口持有一份 `InMemorySessionTokenStore`（`probeSessions`），测试一律走 `sessionScoped(to: probeSessions)`。输入一变就换一份新的，旧的随之丢掉。
- 保存时，`applyAccount` **成功之后**才把这份会话移交给 `SessionTokens.store`（App 里是钥匙串）。钥匙串写密钥失败时不留会话。移交后第一次刷新直接复用，不会多登录一次。

新增 2 例（总数 → 477）：限定存储的 `verify` 把会话只写进临时存储，全局存储里没有；不用会话的适配器 `sessionScoped` 原样返回自己。

**反向验证**：CCH 的 `sessionScoped` 改成返回 `self` → 第一例变红；还原后全绿。

**未做**：没加 App 层的集成测试（设置窗口没有测试入口）。「取消不保存 → 钥匙串无残留」由「测试只写临时存储」这一条保证，没有真实钥匙串验证。

## OPT-018：钥匙串读取失败被当成「缺少密钥」

- **优先级：** P2
- **位置：** [Config.swift:245](../Sources/App/Config.swift#L245)、[Config.swift:289](../Sources/App/Config.swift#L289)
- **证据：** 静态核对（本轮 App 层复查）。

**问题与影响：** 两处都是 `try?`。重建后读旧条目会弹授权框（见项目须知「钥匙串可用」）；用户拒绝、只允许一次或钥匙串锁定时，面板提示「缺少密钥，请重新填写」—— 方向是错的，而且每轮刷新都会再弹一次。

**建议：** 区分「条目不存在」与其他错误，后者如实报出钥匙串的原因。钥匙串错误文案（目前写死中文，[KeychainStore.swift:32](../Sources/App/KeychainStore.swift#L32)）一并改走 L10n。

**验收标准：** 条目不存在时仍是「缺少密钥」；其他错误显示钥匙串原因，三语。

**修复记录（已完成，2026-09-30）**

- `Config.connection(for:)` 改成 `throws`，读密钥不再 `try?`。条目不存在时 `KeychainStore.get` 本来就返回 nil，仍由适配器报「缺少密钥」；其余失败原样抛出，刷新流程的 `catch` 把钥匙串给的原因显示在面板上。
- `KeychainError` 的三段文案改走 L10n（`errKeychainFormat` / `errKeychainUnknownReason` / `errKeychainMalformed`），语言取 `Config.language`（非 MainActor 也能读）。

**未做**：
- **被拒之后仍会在下个刷新周期再弹授权框。** 要彻底消掉得记住「这个账户被拒过」并暂停自动重读，要多一份状态和一个恢复入口。现在至少说对了原因，用户知道该去点「始终允许」。重复弹框若实机里仍烦人，再做。
- 会话令牌的读取（`KeychainSessionTokenStore.token`）仍是 `try?`：读不到时退回用 key 重新登录，功能不受影响，只是多登录一次。
- 没有自动化测试：`Config` 和钥匙串都在 App 层。全量 typecheck 通过。

## OPT-019：不勾「存档」保存，能花钱的 key 成为界面上删不掉的孤儿

- **优先级：** P3
- **位置：** [SettingsWindow.swift:478](../Sources/App/SettingsWindow.swift#L478)、[Config.swift:181](../Sources/App/Config.swift#L181)
- **问题与影响：** `apply` 总是把密钥写进钥匙串，而删除入口只在存档列表里。换到别的账户后，旧账户的 key（和 CCH 会话）再也够不着。
- **建议：** 切走一个**不在存档里**的带密钥账户时，清掉它的密钥和会话。
- **验收标准：** 未存档账户被切走后钥匙串里不留它的条目；存档账户不受影响。

**修复记录（已完成，2026-09-30，用户选「切走即清」）**

`UsageService.accountDidSwitch` 改成接收切换前的账户。账户确实变了、旧账户已配置、又不在存档里，就 `Config.removeCredential(for:)`（密钥 + 会话一起删，不带密钥的那家直接算成功）。`applyAccount` 和 `selectAccount` 共用这一段（不变量 5）。删失败不拦切换 —— 最坏也就是回到修之前的样子。

注意时序：`save()` 是先 `applyAccount`、后存档**新**账户，被判断的是旧账户，不受影响。

**已知代价**：EXT-010 之前就配好、一直没进过存档的账户，一旦被切走，key 就删了，要用得重新粘。这符合「不存档就是一次性配置」的口径。

**验证缺口**：App 层，没有自动化测试；全量 typecheck 通过。

## OPT-020：设置窗口关掉后草稿残留；测试在飞时改输入不能重测

- **优先级：** P3
- **位置：** [SettingsWindow.swift:20](../Sources/App/SettingsWindow.swift#L20)、[SettingsWindow.swift:199](../Sources/App/SettingsWindow.swift#L199)
- **问题与影响：** 窗口只 `orderOut`，`@State` 留着：没保存就关窗，再打开时明文 key 和旧测试结果还在，与注释「每次打开都是空的」不符；存档行改了名没回车，再打开看起来像已改。测试按钮在 `probe.isBusy` 时一直灰着，而旧测试最长可能要几十秒。
- **建议：** 每次打开重建视图；测试按钮只在「在飞的正是当前这段输入」时禁用。

**修复记录（已完成，2026-09-30）**

- `SettingsWindow.show()`：窗口已存在但不可见时，换一个新的 `NSHostingController(rootView: SettingsView())`。开着的时候再点一次不重建，免得冲掉正在填的内容。
- 测试按钮改成 `.disabled(resolved == nil || probe.token == probeKey)`。旧测试回来时过不了提交前的 `probeKey == probed` 校验，它的 `finish` 也按 token 核对，不会清掉新测试的在飞标记（`InFlightGate` 的约定）。

**验证缺口**：纯界面改动，没有自动化验收，只过了全量 typecheck。需要实机确认：关窗再开是空的；存档行改名不回车、关窗再开显示原名；陌生网址测试中改 key 能立刻重测。

## OPT-021：A → B → A 快速切换时，旧 A 请求覆盖新 A 状态

- **优先级：** P2
- **位置：** [UsageService.swift:188](../Sources/App/UsageService.swift#L188)、[InFlightGate.swift:38](../Sources/Core/InFlightGate.swift#L38)
- **证据：** 审查中直接运行 gate 复现：A / B / A 三次都准入，旧 A 收尾后门被清空。

**问题与影响：** 提交只比账户，旧 A 的结果（成功或失败）照样提交，可能以旧快照覆盖新快照、写入过时采样；旧 A 的 `finish` 还会清掉新 A 的在飞标记。

**建议：** 每次刷新一个唯一编号，提交与收尾都按编号核对。

**验收标准：** A1 / B / A2 且两次 A 乱序结束，只有 A2 提交；A1 收尾不释放 A2 的门。

## OPT-022：通知等待授权期间切换账户或关闭通知，仍会发出旧通知

- **优先级：** P3（已授权时 `notificationSettings()` 几乎立即返回，实际窗口主要是首次弹授权框那一次）
- **位置：** [Notifier.swift:69](../Sources/App/Notifier.swift#L69)
- **建议：** 每次 `add` 前重验账本命名空间和通知开关；不通过就放弃并释放占位。通知 identifier 目前不含账户（[Notifier.swift:146](../Sources/App/Notifier.swift#L146)），两个账户同周期的通知会互相替换 —— 顺手改成带命名空间的键。

## OPT-023：日历规则在夏令时跳时后终点漂移；亚秒级提前进入下一周期

- **优先级：** P2
- **位置：** [ResetPolicy.swift:187](../Sources/Core/ResetPolicy.swift#L187)
- **证据：** 审查中 CCH 固定 `02:30`、`America/New_York` 复现：3/8 周期算成 `03:00 → 3/9 03:00`，而 3/9 02:30 已是新周期，重叠 30 分钟。`23:59:59.5` 查每日零点规则返回次日周期，`contains(now) == false`。

**建议：** 终点也按同一条日历规则向前找下一次匹配，而不是「起点 + 一天」；起点算出来晚于 moment 时再往回退一次。

**验收标准：** 相邻周期 `old.end == next.start`（含跳时日）；任何 moment 都落在自己返回的周期内。

## OPT-024：缺桶后恢复，漏判计数器下降，实线跨过重置

- **优先级：** P2
- **位置：** [ChartSeries.swift:215](../Sources/Core/ChartSeries.swift#L215)
- **问题与影响：** 重置判断只看紧邻的前一条；中间一条没有该桶，恢复时 `80 → 缺 → 5` 的下降证据被丢掉，画成从 20% 到 95% 的连续实线。
- **建议：** 按桶记住上一条有该桶的读数，恢复后低于它就断开。**不**把缺失本身当重置（OPT-012 的既定口径不变）。

## OPT-025：学到的日重置时刻丢掉分钟，小幅冲正也被当成重置

- **优先级：** P3
- **位置：** [ResetSchedule.swift:167](../Sources/Core/ResetSchedule.swift#L167)
- **问题与影响：** `observe` 只取小时，而规则被标成「已观测」。半小时时区（Asia/Kolkata）下 UTC 0 点重置被学成 05:00，比实际早 30 分钟，那半小时显示吃紧 / 超速，其间的低额度告警还会占掉当天的去重键。另外任何下降（`3.20 → 3.19`）都算重置。
- **建议：** 观测与学到的结论都带分钟；下降判据要求降到接近 0 或降幅占前值的大比例。

## OPT-026：中转站限流窗口走「剩余秒数」退路时，告警去重键每次都变

- **优先级：** P3
- **位置：** [ResetSchedule.swift:64](../Sources/Core/ResetSchedule.swift#L64)、[AlertPolicy.swift:53](../Sources/Core/AlertPolicy.swift#L53)
- **证据：** 本轮 Core 复查实测 5 次刷新得到 4 个不同的键。实测响应都带起止时间戳，只有退路受影响。
- **建议：** 退路算出的起点对齐到分钟。

## OPT-027：回退到 v3 再升级，给 v4 采样注入「幽灵桶」

- **优先级：** P3
- **位置：** [HistoryStore.swift:216](../Sources/Core/HistoryStore.swift#L216)
- **问题与影响：** v3 打开库时无条件写回 `user_version = 3`；再升级时把全部 samples 重新展开，给已有 `quota_samples` 的采样多出 `total / weeklyOpus / window` 三行 `used = 0`，非中转站账户的额度选择器里冒出假额度，中转站账户画出假重置。
- **建议：** 展开时跳过已有 `quota_samples` 行的采样；迁移放进事务。

## OPT-028：界面零散缺陷

- **优先级：** P3
- 历史窗口选「24 小时」时 X 轴只标月/日（[HistoryCharts.swift:160](../Sources/App/HistoryCharts.swift#L160)、`:247`）。
- `HistoryRecorder.lastError` / `Notifier.lastError` 只写不读：库打不开时界面只说「还没有采样」。
- 「菜单栏显示」Picker 选中值可能没有对应选项（默认 `fixed("daily")` 在 sub2api / CCH 下不存在），下拉显示空白。
- 面板金额写死 `Fmt.money2`（[PopoverView.swift:76](../Sources/App/PopoverView.swift#L76)），没按额度的单位排版；目前四家都是 USD，属潜伏缺陷。

## OPT-029：历史保留从未生效（待用户决定保留期）

- **优先级：** P3
- **位置：** [HistoryStore.swift:530](../Sources/Core/HistoryStore.swift#L530)
- **问题与影响：** `pruneSamples` 只有测试在调，App 没接。采样与额度行无限增长（估算一年约 50 万 / 200 万行）。
- **待决：** 永久保留，还是 90 天 / 1 年？定了再接。

**修复记录（已完成，2026-09-30，保留 90 天）**

Core 新增 `HistoryRetention`（在 `HistoryWriter.swift`）：到期才清，一天最多一次，清掉 90 天前的 `samples` 和 `quota_samples`。**按天的 token 桶和未归属增量不清**：一天一行，它们是柱状图的全部来源。

`HistoryRecorder` 在每次写入成功**之后**调用它。此时库里最新的就是刚写的那条，清理碰不到写入器的基线。换账户时 `reset()`，新分区下一次写入就清一次。各账户只在被使用时清自己的分区，从没切回去的账户不会被清。

新增 2 例（总数 → 471）：只清 90 天前的采样、日桶保留；一天内不重复清、`reset` 后立刻可清。

**反向验证**：去掉 `pruneIfDue` 里的删除 → 第一例变红；还原后全绿。

**未做**：清理后不 `VACUUM`。SQLite 会复用释放的页，文件不会再长；已经长大的文件不缩小。

## OPT-030：文档与文案过时

- **优先级：** P3
- 双语 README 隐私 FAQ 只列 tu-zi key，缺 sub2api / CCH key 与 CCH 会话；设置截图、面板截图是旧版。
- 首次配置引导（`Localization.swift:339`）仍教填中转站用量 URL；安全提示「不会上传」表述过强。
- tu-zi / CCH 根本不报累计 token，历史空态却说「两次刷新后出现」。
- `project-notes` 对 XCTest 的描述不对（默认 `continueAfterFailure = true`，前一条失败不会中止）；两份 backlog 开头 / 末尾的旧总结与现状矛盾；「最后一个未验证标记」表述过强。
- README 的 pace 负值说明省略了「按当前平均速度」这个前提。
