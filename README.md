# orca-conductor

An Agent Skill for running a **multi-agent orchestration session** on top of [Orca](https://onorca.dev)'s `orca orchestration` CLI — the coordinator side, not the worker side.

一个用于 **Agent 调度会话（coordinator）** 的 Skill。它不教你 Orca CLI 的参数（那是 Orca 自带 `orchestration` skill 的事），它管的是调度纪律：任务指示怎么写才不会让 worker 白干、上下文怎么真正推进隔离 worktree、worker 卡住时怎么判断、什么时候绝对不该重开 Agent、产出怎么验、worktree 怎么回收而不会把自己删掉。

## Why

调度会话的失败方式很少，而且高度重复：

| 失败模式 | 本 skill 的对策 |
|---|---|
| spec 只有"目标 + 几条约束"，worker 从零重新探索、重走已否决的路 | 12 节必填 **Worker Brief** + 强制 **Read-back Gate** |
| worker 起在别的 worktree，看不到你未提交的改动 | 先 commit 取基线 SHA，`--base-branch <SHA>`；**Orca 谱系 ≠ git 基线** |
| 因为"跑得久"就重开 Agent，丢掉全部已有进度 | **三证据法** + 六级升级阶梯，补发优先于重开 |
| 上下文被轮询垃圾填满，忘掉 dispatch id | 每个 Step 一次 **checkpoint → rewind**，report 强制承载 id 与下一步 |
| 回收攒到最后，分不清哪个 worktree 是谁的 | **owned 清单**作为唯一删除授权 + 自我保护 + 只读巡检脚本 |

## Install

Claude Code / plugin marketplace：

```bash
/plugin marketplace add jiwangyihao/orca-conductor
```

或者直接把 `skills/orca-conductor/` 复制到你的 agent 的 skills 目录（`~/.claude/skills/`、`user_skills/` 等）。

## Layout

```
skills/orca-conductor/
├── SKILL.md                          # 总纲：不变式、Phase/Step 骨架、S1–S7 手册、反模式
├── references/
│   ├── worker-brief.md               # 任务指示契约：12 节必填 + Read-back Gate + 正反例
│   ├── context-plumbing.md           # 三条上下文通道；谱系 vs git 基线；跨机限制
│   ├── phase-step-protocol.md        # Step 转移表、checkpoint/rewind 语义、report 模板
│   ├── recovery-playbook.md          # 四类中断现场决策表、升级阶梯、补发模板
│   └── acceptance-and-reclaim.md     # 独立复跑验收、owned 清单、回收语义与自我保护
├── assets/
│   ├── worker-brief-template.md      # 复制填写，交给 worker
│   ├── progress-ledger-template.md   # worker 进度台账格式
│   └── session-kickoff-prompt.md     # 把任意会话切换成调度会话的提示词
└── scripts/
    └── orca_sweep.sh                 # 只读巡检：自身保护标记 + task 终态 + 资源对账
```

## Core rules (TL;DR)

1. 先落盘再派发；`--spec` 只做指向 brief 的指针（15–30 行）。
2. Read-back Gate 强制：worker 先回写"已读文件 + 实际 `git log -1` + brief 的 sha256 + 分步计划"，收到 `reply` 前不得改任何业务文件。
3. `new-child` 只决定 Orca 谱系，git 基线必须 `--base-branch <commit SHA>`（用 SHA，分支名会漂移）。
4. 时间不是证据：禁止仅因运行时长 stop/restart worker；升级需要新增证据。
5. 补发（`send --to dispatch:<id>`）优先于重开——重开等于丢掉 worker 已建立的全部上下文。
6. 每个 Step 一次 checkpoint→rewind；rewind 会丢弃 Step 内上下文，report 必须带 id、基线 SHA、下一步。
7. 只回收自己 owned 清单里的资源；**当前 worktree 永不删**（删了会终结 coordinator 自己）。

## Notes

- Worker harness 固定 OMP（`--agent omp`）。
- CLI 参数、返回结构、错误语义以 `orca skills get orchestration` 为准，本 skill 不复述。
- Skill 正文为中文。

## License

Mozilla Public License 2.0
