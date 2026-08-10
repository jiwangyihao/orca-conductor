# 中断与故障恢复 Playbook

worker 意外中断是**常态**，不是异常。它可能卡在启动画面、可能在静默苦干、可能已经干完但没汇报、也可能真的死了。这四种现场的正确动作完全不同，而它们在"没有新消息"这一点上长得一模一样。

所以：先取证，再决策。禁止只凭"跑了很久"就重开。

## 目录

- [三证据法](#三证据法)
- [四类现场与决策表](#四类现场与决策表)
- [升级阶梯](#升级阶梯)
- [补发指令模板](#补发指令模板)
- [重开的前置条件](#重开的前置条件)
- [当根因是你的指示](#当根因是你的指示)
- [取证时的坑](#取证时的坑)

## 三证据法

判定一个 worker 的现场，需要三类互相独立的证据。任何一类单独看都会骗你。

| 证据 | 命令 | 看什么 |
|---|---|---|
| A 调度状态 | `worker-show --dispatch <id> --json` | `workerState` / `dispatchStatus` / `terminalState`；`resource.releaseState` |
| B 输出流 | `worker-read --dispatch <id> --limit 50 --json` | `source` 是 `transcript` 还是 `terminal`；有无 `fallbackReason`（如 `session_not_reported`）；**间隔 3–5 分钟采两次，看 cursor / 内容是否推进** |
| C 文件系统 | 台账文件 mtime；`git -C <worktree> status --short`；`git -C <worktree> log --oneline -3` | 有没有真实产物；进度写到第几步 |

单条证据的误导性：A 显示 `running` 只说明进程活着，不说明 agent 在干活；B 有输出可能只是 TUI 在重绘；C 没变化可能是它正在读代码还没到写的阶段。**三条一起看**，结论才稳。

为什么要"采两次"：静默苦干和卡死的唯一区别就是**推进**。一次快照永远区分不出来，两次快照几乎总能区分出来。

## 四类现场与决策表

| 现场 | 证据组合 | 动作 |
|---|---|---|
| **从未真正启动** | B 的 `source=terminal` + `fallbackReason=session_not_reported`（说明 hook 从未上报过 transcript），且 C 无任何改动、无台账文件 | 先 `send` 一条唤醒 + 明确"立刻读 brief 并回写"。仍无反应 → `worker-stop` → `worker-start --retry-of <dispatch>`，复用干净 worktree。这是真实发生过的故障：OMP 终端停在欢迎屏，18 分钟零产出，连显式唤醒都没反应 |
| **静默苦干** | B 两次采样有推进，或 C 的台账 / git 有推进 | **什么都不做**，回到等待观测。可以顺手 `send` 一条"每完成一步就更新台账"的提醒，但不要打断它 |
| **已完成未汇报** | C 显示 DoD 基本达成（有 commit、有产物），但没收到 `worker_done` | `send` 追问，要求按汇报契约发 `worker_done`。若终端已不可用，直接自己独立验收，然后 `task-update` 结算并在 `result` 里写明"worker 未汇报，coordinator 独立验收" |
| **死亡或状态不明** | A 的 `terminalState` 已退出/不明，或命令返回 `outcome_unknown` | 用 `worker-abandon`（它**不声称进程已停止**，保留一切可能存活的资源），然后只依据 C 做判断。绝不在状态不明时声称"已停止" |

`worker-stop` 与 `worker-abandon` 的区别很重要：`stop` 会围栏并停止那个 agent 终端（不删 worktree、不动 setup 终端）；`abandon` 只围栏、不做任何进程或文件系统动作。**不确定进程是否还活着时用 `abandon`**，否则你会基于一个假的"已停止"继续操作，导致两个 agent 同时写同一个 worktree。

## 升级阶梯

按顺序升级，每一级都比下一级便宜得多。跳级是最常见的浪费。

1. **继续观测**（默认）：新一轮 `check --wait`。
2. **补发指令**：`send --to dispatch:<id>`。纠偏、追加约束、要求落盘、要求汇报，都在这一级解决。
3. **阻塞问答**：worker 用 `ask` 提问 → 你 `reply --id <msg_id>`。gate 确认也走这里。
4. **停止**：`worker-stop`（确定要终止）或 `worker-abandon`（不确定是否活着）。
5. **重开**：`worker-start --retry-of <原 dispatch>`，同时 `task-update --status failed --result '{"reason":"..."}'` 把旧 task 结算掉，理由写清楚（例如 `superseded: coordinator brief was underspecified`），方便事后审计。
6. **放弃该分支工作**：重新划 Phase，把这块工作换一种拆法。

第 2 级能解决绝大多数问题，却最常被跳过。**重开的代价是丢掉它已经建立的全部上下文**——它会重新 grep 一遍仓库、重新读一遍设计文档，总耗时通常比补发慢好几倍。

## 补发指令模板

```text
subject: [纠偏] 停止当前探索，先读 handoff 再按阶段执行

body:
1. 立刻停止当前正在做的事，不要提交、不要继续改文件。
2. 读 <brief 绝对路径>（已更新，sha256 = <sha>）。这里面有你缺的：共享基线、两轮失败历史、
   已否决方案、必须复跑的命令与判据、证据路径、验收顺序。
3. 读完用 ask 回写：已读文件清单 + `git log -1 --oneline` 实际输出 + brief 的 sha256 + 分步计划。
   收到我的 reply 之前不要修改任何业务文件。
4. 从现在开始，每完成一个可验证单元就更新 <台账绝对路径>；先落盘再继续。
5. 不要一次性跑大段脚本；重型命令（依赖安装、node_modules 清理）放后台并记录日志路径。
```

要点：补发要**先叫停**，再给路径，再要求回写确认。只发"你搞错了，请改成 X"会让它在错误上下文上继续叠加。

不要向旧的 terminal handle 和新 handle 双发同一条指令——handle 失效后要重新解析，然后**只**用新的那个。给受监督 worker 的指令一律用稳定地址 `dispatch:<id>`，不要用终端 handle。

## 重开的前置条件

三条全部满足才重开，否则回到第 2 级：

1. 有**新增证据**表明现场不可恢复（不是"时间长"，而是 B 无推进 + C 无产物，或终端确已死亡）。
2. 已经至少补发过一次明确指令，且给了它一个观测窗口的响应时间。
3. 已经决定**重开后的 brief 与上次不同在哪**。用同一份指示重开，只会得到同一个失败。

重开时的 worktree 抉择：worker 已经产生有价值改动 → 保留 worktree，让新 worker 在同一 worktree 接手并在 brief 里写明"接手现场，先 `git status` 盘点"；改动无价值或已污染 → 用干净 worktree（`--retry-of` 会走标准的资源处理路径，不要手动 `rm -rf` 别人的工作区）。

## 当根因是你的指示

最贵的一类故障：worker 很努力，方向全错，因为 spec 里只有目标和几条约束。

征兆：它在报告里发明了自己的验收标准；它重试了你早就否决的做法；它反复问"基线是哪个 commit"；它交付的产物路径和你预期完全不同。

处理顺序：

1. **先承认是指示问题**，不要重开 agent（重开只会让新 agent 犯同样的错，因为指示没变）。
2. 把完整 brief 补齐并落盘（这是补救的实体动作，见 [worker-brief.md](worker-brief.md)）。
3. 按情况选择：现场还可用 → 补发纠偏指令 + gate；现场已污染 → `worker-stop` / `worker-abandon` → `task-update --status failed --result '{"reason":"superseded: brief underspecified, replaced by <path>"}'` → 新建 task，spec 里**强制 read-back gate**。
4. 在 rewind report 里记一条"指示缺陷类型"，避免下个 Phase 又犯。

## 取证时的坑

- `worker-read` 的 cursor **绑定在具体 source 上**。若报 `source_changed`，重新从头读一次，不要拿旧 cursor 继续翻。
- `check` 返回 `{count:0}` 或超时都**不是**失败，只是"这一窗口没有新消息"。
- 取证命令要一条一条发。串在一个 turn 里，遇到排队消息会被整批跳过（见 [phase-step-protocol.md](phase-step-protocol.md)）。
- 重型清理命令（`rm -rf node_modules`、全量重装）会超时，不要放在取证的关键路径上；先判断现场，再决定是否值得花这个时间。
- 进入 S4 故障处理前先开 checkpoint，处理完用 rewind 把一堆 JSON 回执压成结论——故障处理是产生垃圾上下文最多的步骤。
