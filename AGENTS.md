# AGENTS.md

**先读 `docs/handoff.zh-CN.md`，那是完整的交接说明。** 本文件只是入口，内容不在这里维护。

在读完之前，有四条足以造成不可逆损失的红线：

1. **工作区有 25 个文件的改动未提交**（另有 5 个未跟踪文件）。`git stash` / `git checkout .` / `git reset --hard` 会抹掉过去两周的全部工作。不要执行。
2. **构建必须用 macOS 26 SDK**，不是默认的最新那个。直接跑 `./build.sh`，它已经处理好了；别改里面的 SDK 探测逻辑。
3. **本机没有 Xcode，也没有 XCTest。** `swift test` 跑不了。测试命令是 `swift run CoreTests`（应为 321 通过 0 失败），新增用例须在 `Tests/CoreTests/TestRegistry.swift` 登记。
4. **沿用现有风格，不要重构。** 中文注释、文件头的「为什么」说明、注释里的 backlog 编号引用，都要保留。

改过 `Sources/App/` 之后，`swift run CoreTests` 覆盖不到 UI 层，必须另跑一次全量类型检查 —— 命令在 handoff 的「命令」一节。

沟通用中文。用户是建筑师，不写代码；提交与推送由用户定夺。
