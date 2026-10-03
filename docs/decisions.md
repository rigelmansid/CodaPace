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
