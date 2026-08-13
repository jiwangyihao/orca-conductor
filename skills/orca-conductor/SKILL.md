---
name: orca-conductor
description: 把当前会话变成 Orca 多 Agent 调度会话（coordinator）的作业规范：按执行拓扑划分串行 Phase 与 Step、用 checkpoint/rewind 压缩调度上下文并交接状态、编写详尽的 Worker Brief 与强制 Read-back Gate、通过 git 基线与共享目录把上下文推给隔离 worktree 中的 worker、用三证据法观测与恢复意外中断的 worker、独立复跑验收产出、按 Phase 回收 worker 与自建 worktree。适用于"调度会话/coordinator/派发多个 Agent/并行 worker/多 worktree 协作/worker 卡住了不响应/要不要重开 Agent/任务指示写得太简略/验收 worker 产出/回收 worktree"等场景。CLI 参数细节以 Orca 自带的 orchestration skill 为准，本 skill 只管调度纪律。
author: zhangyihao.jwyh
---

# Orca Conductor

调度会话的产出不是代码，而是**被验收过的 worker 成果 + 一份可追溯的调度记录**。

调度会话失败的方式很少，而且高度重复：任务指示太简略导致 worker 重新探索并重走已否决的路；上下文没真正推到 worker 的 worktree；因为"跑得久"就重开 Agent，把已有进度全丢掉；上下文被轮询垃圾填满后忘掉 dispatch id；回收攒到最后已经分不清哪个 worktree 是谁的。本 skill 就是针对这五件事的纪律。

**何时用**：需要把一个任务拆给多个 Agent 并行推进、需要监督/等待/验收 worker、需要协调有依赖关系的多阶段工作。
**何时不用**：一次性的完整交接（把活儿整体交给另一个 Agent 就不管了）、纯粹的终端控制或 worktree 管理——那些用 Orca 的 `orca-cli` skill。单个 Agent 能做完的事不要引入调度。

## 前置

- **CLI 用法以 Orca 自带 skill 为准**：先加载 `orchestration` skill（`orca skills get orchestration`）。task/worker/inbox/回收命令的参数、返回结构、错误语义都在那里，本 skill 不复述。
- **harness 固定 OMP**：所有 worker 用 `--agent omp`，不使用其他 harness。
- **自我保护**：你自己也在一个隔离 worktree 里，删掉它会直接终结你的进程。开工第一件事：

```bash
orca worktree current --json     # 记下自己的 path 与 id，标注 PROTECTED — NEVER REMOVE
```

## 不变式

违反任一条，后面所有努力都可能白费。

1. **先落盘，再派发**：Worker Brief 写完并 commit，取到基线 SHA，才允许 `task-create`。
2. **spec 只做指针**：长上下文放文件，`--spec` 15–30 行，指向 brief 绝对路径。
3. **Read-back Gate 强制**：worker 必须先回写"已读文件 + 实际 `git log -1` + brief 的 sha256 + 分步计划"，收到你的 `reply` 前不得改任何业务文件。
4. **谱系不等于基线**：`new-child` 只决定 Orca 谱系；git 基线必须用 `--base-branch <commit SHA>` 显式指定。
5. **时间不是证据**：禁止仅因运行时长 stop/restart worker。升级必须有新增证据。
6. **补发优先于重开**：`send --to dispatch:<id>` 能解决的问题，不要用重开解决。
7. **每个 Step 一次 checkpoint→rewind**，report 必须承载 id 与下一步。
8. **只回收自己 owned 清单里的资源**，当前 worktree 永不删。
9. **Todo 与 Phase 拓扑同源**：todo 的 Phase 分组必须能和当前 checkpoint 的 Phase 编号、活跃 worktree 分组逐一对上；对不上就是 todo 已经落后。

## 会话骨架

Phase 之间串行，Phase 内部并行。切 Phase 的依据是"下一批工作是否需要上一批的产物"，不是工作量大小。每个 Phase 显式写下入口基线 SHA、可客观判定的出口条件、结束时的回收动作。

Phase 内部按 Step 推进，每个 Step 对应一次 checkpoint→rewind：

```
S1 规划 ──▶ S2 派发 ──▶ S3 等待观测 ──┬──▶ S5 单体验收 ──▶ S6 回收 ──┬──▶ 下一 Phase 的 S1
                          ▲          │                    ▲        └──▶ S7 全量验收
                          └── S4 故障处理 ◀────────────────┘
```

细则、转移表、checkpoint 语义与 report 模板见 [phase-step-protocol.md](references/phase-step-protocol.md)。

三条最容易被忽略的纪律：

- **结束 Step 的理由不只有"做完了"**。"我需要进入一个专门步骤处理突发事项"同样合法且推荐——正好用 rewind 把一堆轮询输出压成一句结论再进 S4。
- **rewind 会丢弃 Step 内的中间上下文**。task id、dispatch id、基线 SHA、brief 与台账路径、owned 清单，必须写进 report 或落盘到 `conductor-state.md`。丢了 dispatch id，就再也无法向那个 worker 补发指令。
- **看到 checkpoint 报告 = 你已经 rewind 过了**。rewind 通常不留独立调用记录，报告本身就是记录；不要怀疑，也不要重复调用（会报错）。
- **`checkpoint` 创建失败就是"上一个 Step 没收尾"的答案**。不要靠记忆判断自己 rewind 过没有——直接开 checkpoint，失败即证据：说明还有一个活跃 checkpoint。此时**立刻补 rewind**（按模板把上一个 Step 的 report 写完），成功后再开新 checkpoint，然后才继续干活。绝不能忽略这次失败、带着过期 checkpoint 继续推进：那样两个 Step 的上下文会混在一起，最后一次 rewind 无法准确概述任何一个，而且 yield 会被拦住。反向的两种报错也各有定论——报"没有活跃 checkpoint"说明可以直接开新的；报"已经 rewound"说明就从保留的 report 继续，不要重试。

## Todo 是 Phase 拓扑的镜像

Todo 列表的唯一作用是让人一眼看出"现在在哪个 Phase、这个 Phase 还剩什么"。它不是历史台账，历史留在 `conductor-state.md` 和 rewind report 里。

**只排到看得清的地方**：当前 Phase 展开到 Step 级，下一个 Phase 给粗粒度条目，更远的 Phase 只留一行占位。下游 Phase 的形状取决于上游产出，一次性把 Phase 1–XIII 排成 80 条，等于把一份必然作废的计划写进上下文；之后每次真实拓扑变化都要在 80 条里做外科手术，最终必然放弃维护。

**调度会话里 todo 落后的主因不是懒，是需求变了**。上游结论被推翻、验收标准被修正、某个 Phase 被合并或整体废弃——此时旧条目已经失去意义，而它们看上去仍然"只是没做完"。所以以下任一情况发生时立刻重规划，不要等人来问"todo 是不是落后了"：

- 收到纠正 / 需求变更，导致某个 Phase 部分或全部作废
- 你已经在做的 Phase 编号超过了 todo 里 in_progress 的 Phase
- Phase 出口条件被改写，或 Phase 被跳过 / 合并 / 拆分
- 每次 rewind 时顺手核对一次（report 里就该声明"todo 需不需要重建"）

**重规划动作**：

1. 真正做完的旧条目标 completed。
2. 被废弃或被取代的条目**直接从 todo 里删除**——不要留着装 pending（假滞后），更不要标成 completed（污染审计）。
3. 按当前真实拓扑重建剩余条目，Phase 编号与 checkpoint、worktree 分组同源。
4. 废弃了什么、为什么废弃，写进 `conductor-state.md`。

大规模变更时**整表重置**（一次 `write_todos` 覆盖），不要逐条打补丁；带着几十条历史残留去修，改不干净还会误导后续判断。

## Step 手册

每个 Step 都是：开 `checkpoint` → 做事 → `rewind` 交接。

### S1 规划

拆解执行拓扑 → 定 Phase 边界与出口条件 → 为本 Phase 每个 worker 写 Worker Brief → commit → 取基线 SHA。

Brief 是本 skill 的重心，因为最贵的失败是"worker 很努力、方向全错"。必填 12 节、Read-back Gate 的写法、正反例对照见 [worker-brief.md](references/worker-brief.md)，直接套 [worker-brief-template.md](assets/worker-brief-template.md)。

写 brief 时必须回答的问题：它从哪读起？哪些结论已经确认不必重查？哪些做法已被否决？能改哪些路径？必须复跑哪些命令、判据是什么？证据写到哪？我会按什么顺序验收？**应该用哪个 skill、为什么？**

同时要求 worker 持续把进展写进台账（[progress-ledger-template.md](assets/progress-ledger-template.md)），每完成一个可验证单元就更新，**先落盘再继续**；并明确不要一次性执行大段脚本——中途死掉既没有中间产物，也看不出停在哪一步。这一条直接决定中断的代价。

*rewind 出口*：Phase 计划 + 基线 SHA + 各 brief 路径 → 进入 S2。规划完立刻把 todo 刷成与本 Phase 拓扑同源的样子（当前 Phase 到 Step 级，远处 Phase 只留占位）。

### S2 派发

worker 起在另一个 worktree，看不到你未提交的改动，也不会自动继承你的分支。落盘顺序与通道选择见 [context-plumbing.md](references/context-plumbing.md)。

```bash
git rev-parse HEAD                      # 共享基线，记进 report
orca orchestration task-create --spec "<指针 spec>" --task-title "<≤60 字符短标签>" --json
orca orchestration worker-start --task <task_id> --worktree new-child --name <name> \
  --base-branch <基线 SHA> --agent omp --setup run --json
```

- `--task-title` 用短标签，不要把 brief 的一级标题整段灌进去——它会出现在 `task-list` 和 worker 行里，长标题让对账不可读。
- 用 SHA 而不是分支名：你还会继续在这个分支上提交，分支名会漂移。
- 回执 `ready` 才算派出去。非零退出先看 `stage` / `effects` / `residualResources`，不要盲目重试。
- 并行时**先把所有 worker 都起完再进入等待**，否则第一个等待窗口会挡住其余派发。
- 每次派发成功，立刻把 `task_id / dispatch_id / worktree 选择器` 追加进 owned 清单。

*rewind 出口*：task→dispatch→worktree 映射表（这是后面一切操作的钥匙）→ 进入 S3。

### S3 等待观测

rolling `check --wait`，10–15 分钟一窗口，处理 question / heartbeat / status。

- **超时或 `{count:0}` 不是失败**，只是这一窗口没有新消息。真实编码任务 15–60 分钟很正常。
- 收到 `question` 就认真回 `reply`——worker 卡在这里是在等你，等待时间全是浪费。
- 判定"需要升级"必须有新增证据，用三证据法（见 S4）。**禁止只凭时长重开。**

*rewind 出口*：收到 worker_done → S5；判定异常 → S4，report 里写清"疑似哪种现场、下一步先取哪个证据"。

### S4 故障处理

中断是常态。先取证再决策，三证据法：

| 证据 | 命令 | 看什么 |
|---|---|---|
| A 调度状态 | `worker-show --dispatch <id> --json` | workerState / terminalState / releaseState |
| B 输出流 | `worker-read --dispatch <id> --limit 50 --json` | `source` 是 transcript 还是 terminal、有无 `fallbackReason`；**间隔 3–5 分钟采两次看是否推进** |
| C 文件系统 | 台账 mtime、`git -C <wt> status --short`、`git -C <wt> log --oneline -3` | 有没有真实产物、进度到第几步 |

一次快照永远区分不出"静默苦干"和"卡死"，两次快照几乎总能。四类现场（从未启动 / 静默苦干 / 已完成未汇报 / 死亡或不明）对应的动作、升级阶梯、补发模板、重开前置条件，见 [recovery-playbook.md](references/recovery-playbook.md)。

最重要的一条：**升级阶梯的第 2 级（`send --to dispatch:` 补发）能解决绝大多数问题，却最常被跳过。** 重开的代价是丢掉 worker 已建立的全部上下文——它会重新 grep 一遍仓库、重新读一遍设计文档，总耗时通常慢好几倍。

如果根因是你的指示不详尽（它发明了自己的验收标准、重试了已否决方案、反复问基线是哪个 commit），**不要重开**——重开会让新 agent 犯同样的错，因为指示没变。先补齐 brief 落盘，再补发纠偏（先叫停 → 给路径 → 要求回写确认）。

*rewind 出口*：现场恢复 → S3；放弃该 worker → S6。report 必须保留 dispatch id 和已执行的干预动作。

### S5 单体验收

不信 prose，按 brief 第 10 节公开过的**同一顺序**独立复跑。三查：文件存在、命令判据、git 记录与路径白名单。`--files-modified` 与实际 `git status` 不一致是最强的危险信号。详见 [acceptance-and-reclaim.md](references/acceptance-and-reclaim.md)。

*rewind 出口*：全部 worker 已结算 → S6；拒收 → S4。

### S6 回收

每个 Phase 结束对账一次，不要攒到最后。

```bash
bash scripts/orca_sweep.sh            # 只读巡检：自身保护标记 + task 终态 + worker/资源对账 + 建议动作
```

Orca 不会替你判断 worktree 是谁创建的（`ownershipState=external`、`retainedReason=legacy_ambiguous` 意味着归属无法证明），所以**以你自己的 owned 清单作为唯一删除授权**；清单之外一律不删，列给用户决定。顺序是先 `worker-release` 结算终端（release 之后输出仍可读），再决定是否 `worktree rm`；`worktree rm` 前三查见 [acceptance-and-reclaim.md](references/acceptance-and-reclaim.md)。

*rewind 出口*：Phase 未完 → S2；Phase 完 → 下一 Phase 的 S1 或 S7。report 带上剩余 owned 资源与下一 Phase 入口基线。

### S7 全量验收

集成复跑（单体都过、合起来不过是并行调度最典型的失败）、基线与契约一致性、交付清单逐项核对、结论落盘成文件后再在会话里汇报——会话上下文会被 rewind，文件不会。

## 工具调用节奏

OMP 在有排队的用户消息或系统建议时，会**跳过**该批次里尚未执行的工具调用并返回 `Skipped due to pending system advisory`。跳过不是失败，容易被误读成"已经做了"。

所以关键的取证、落盘、派发动作一次发一条，看到结果再继续；看到 `Skipped due to pending ...` 就先处理那条消息，然后**重新发起**被跳过的调用。需要并行的是 worker，不是你的工具调用。

## 反模式

出现即自我纠正：

- spec 只写目标和几条约束就派发
- 不 commit 就派发，或只给 `new-child` 不给 `--base-branch`
- 因为"跑了很久"重开 worker
- 一个 turn 里串联一长串关键 orca 调用
- rewind report 里没带 dispatch id / 基线 SHA / 下一步声明
- 攒到最后才回收，或删了归属不明的 worktree
- 让 worker 一次性跑几百行脚本
- 拿 worker 报告里的输出片段当验收证据
- 一次性把全部 Phase 排成几十条 todo，然后再也不动它
- 需求变更废弃了旧 Phase，却把对应 todo 留成 pending 或标成 completed
- 等用户问"todo 是不是落后了"才重规划
- `checkpoint` 创建失败后不补 rewind，直接继续在过期 checkpoint 下工作
- 状态不明时用 `worker-stop` 并宣称"已停止"（该用 `worker-abandon`）

## 文件索引

| 文件 | 什么时候读 |
|---|---|
| [worker-brief.md](references/worker-brief.md) | 写任务指示前（S1）——12 节必填项、Read-back Gate、正反例 |
| [context-plumbing.md](references/context-plumbing.md) | 派发前（S2）——三条通道、谱系 vs 基线、共享目录、跨机限制 |
| [phase-step-protocol.md](references/phase-step-protocol.md) | 规划与每次 rewind 时——转移表、checkpoint 语义、report 模板、节奏预算 |
| [recovery-playbook.md](references/recovery-playbook.md) | worker 异常时（S4）——四类现场决策表、升级阶梯、补发模板 |
| [acceptance-and-reclaim.md](references/acceptance-and-reclaim.md) | 验收与回收时（S5–S7）——三查、owned 清单原则、回收语义与自我保护 |
| [worker-brief-template.md](assets/worker-brief-template.md) | 复制填写，交给 worker |
| [progress-ledger-template.md](assets/progress-ledger-template.md) | 复制给 worker 作为进度台账格式 |
| [session-kickoff-prompt.md](assets/session-kickoff-prompt.md) | 需要把另一个会话切换成调度会话时，粘贴它 |
| [orca_sweep.sh](scripts/orca_sweep.sh) | 每个 Phase 收尾（S6）——只读对账 |
