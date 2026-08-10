# Phase / Step 协议与 Checkpoint 纪律

调度会话会跑很久，中间会积累大量一次性的探索输出（JSON 回执、终端片段、git 输出）。没有结构，上下文会在第二个 Phase 就被这些垃圾填满，然后你开始遗忘 dispatch id、遗忘基线 SHA、把已经处理过的失败再处理一遍。

Phase/Step + checkpoint/rewind 就是用来把"过程"压成"结论"的。

## 目录

- [Phase：串行的骨架](#phase串行的骨架)
- [Step：七种步骤与转移](#step七种步骤与转移)
- [Checkpoint / Rewind 语义](#checkpoint--rewind-语义)
- [Rewind report 模板](#rewind-report-模板)
- [节奏与预算](#节奏与预算)
- [一个 turn 里不要串联关键调用](#一个-turn-里不要串联关键调用)

## Phase：串行的骨架

Phase 之间**串行**，Phase 内部尽量**并行**。切 Phase 的依据是"下一批工作是否需要上一批的产物作为输入"，不是工作量大小。

每个 Phase 有三件事必须显式写下来：

1. **入口基线**：本 Phase 所有 worker 共享的 commit SHA（见 [context-plumbing.md](context-plumbing.md)）。
2. **出口条件**：一组可客观判定的条目。全部满足才允许进入下一 Phase；部分满足就进，等于把问题带进下游放大。
3. **回收动作**：本 Phase 结束时清理本 Phase 产生的 worker 与 worktree（见 [acceptance-and-reclaim.md](acceptance-and-reclaim.md)）。

依赖链不要超过 3–4 层。更深的链条意味着任何一环失败都要重跑整条，此时应该考虑把中间产物固化成 commit，把长链切成多个 Phase。

## Step：七种步骤与转移

Step 是 Phase 内部的最小调度单元，每个 Step 对应一次 checkpoint → rewind。

| Step | 做什么 | 正常出口 | 异常出口 |
|---|---|---|---|
| S1 规划 | 拆解拓扑、定 Phase 边界、写 brief、提交基线 | → S2 | 信息不足 → 向用户提问 |
| S2 派发 | `task-create` + `worker-start`，读回执确认 ready | → S3 | 回执非 ready → S4 |
| S3 等待观测 | rolling `check --wait`，处理 question / heartbeat / status | 收到 worker_done → S5 | 判定异常 → S4 |
| S4 故障处理 | 现场取证、决定补发 / 停止 / 重开 | 现场恢复 → S3 | 放弃该 worker → S6 |
| S5 单体验收 | 独立复跑验收命令，接受或拒收单个 worker 产出 | 全部 worker 已结算 → S6 | 拒收 → S4 |
| S6 回收 | 结算 worker 终端、回收自建 worktree、对账 | Phase 未完 → S2；Phase 完 → S7 或下一 Phase 的 S1 | 回收结果不明 → S4 |
| S7 全量验收 | 跨 worker 集成验收、交付清单核对、产出结论 | 任务结束 | 集成不通过 → 新 Phase 的 S1 |

关键认知：**结束一个 Step 的理由不只有"做完了"**。"我发现需要专门处理一件事" 同样是合法且推荐的出口——这正是 rewind 的价值所在：把等待期间积累的一堆无用轮询输出压成一句"worker A 疑似未真正启动"，然后带着干净的上下文进入 S4。

## Checkpoint / Rewind 语义

（OMP harness 的 `checkpoint` / `rewind` 工具行为，硬约束，不是风格建议）

- 同一时刻**只能有一个活跃 checkpoint**，不可嵌套。在活跃期间再开会直接报错。
- 开了 checkpoint 就**必须在 yield 之前 rewind**，否则会被拦住。
- `rewind` 需要非空的 `report`；成功后**该 checkpoint 内的中间消息从活跃上下文中移除**，只保留你的 report。
- 一次 rewind 是终态，重复调用报错。若报错说已经 rewound，就从保留的 report 继续，不要重试。
- 子 agent 里没有这两个工具。

由此推出两条纪律：

**（一）状态承载**。rewind 会丢弃步骤内的一切细节，所以任何"下一步还要用"的事实必须出现在 report 里，或已经落盘到 `conductor-state.md`。典型的：task id、dispatch id、agent terminal handle、基线 SHA、brief 路径、台账路径、已 release / 待 release 的 dispatch 列表。**丢了 dispatch id，你就再也无法向那个 worker 补发指令。**

**（二）报告即证据**。当你在上下文里看到一份 checkpoint 报告，说明你**已经**执行过 rewind——rewind 通常不留独立的调用记录，报告本身就是它的记录。不要因为"没看到 rewind 的调用痕迹"而怀疑自己没 rewind，更不要再补一次（会报错）。

## Rewind report 模板

固定字段，缺一不可。写完 report 就等于交接给"下一个自己"。

```markdown
[Phase <n> / <Step 编号 Step 名>] 结果：<完成 | 中断转专项 | 部分完成>

## 事实
- 基线 SHA：<sha>
- 本步涉及 task/dispatch：<task_id → dispatch_id → worktree 路径 → worker 状态>
- 关键产物路径：<brief / 台账 / 证据>

## 结论
- <2–5 条，只写会影响后续决策的结论>

## 未决与风险
- <未决问题；每条附"由哪个 Step 处理">

## 下一步
进入 <Step 编号 Step 名>，因为 <一句话理由>。
第一个动作是 <具体命令或动作>。
```

"下一步"必须写死，尤其当你是**因为要处理突发专项而提前结束**这个 Step 的时候——否则 rewind 之后你只剩一份结论，会重新开始猜该干什么。

## 节奏与预算

- 观测窗口取 10–15 分钟一轮（`check --wait --timeout-ms`），连续多轮无任何新信号才升级到 S4。真实编码任务 15–60 分钟很正常。
- **超时或 `{count:0}` 不是失败信号**，只是一个观测点。不要因为"跑得久"就 stop / restart —— 重开的唯一后果是 worker 从零重新探索上下文，总耗时更长，而且你会丢掉它已经落盘的进度。
- heartbeat、终端有输出、TUI 在动 → 说明活着，不说明做完了。
- 判定"需要升级"要有**新增证据**，不能只有时间：见 [recovery-playbook.md](recovery-playbook.md) 的三证据法。
- 每个 Phase 至少做一次 S6 回收；不要攒到最后一次性清理，那时你已经分不清哪个 worktree 是谁的了。

## 一个 turn 里不要串联关键调用

OMP 在有排队的用户消息或系统建议（advisory）时，会**跳过**该批次里尚未执行的工具调用，并返回 `Skipped due to pending system advisory`。如果你把 `worker-show && worker-read && write brief` 串在一个 turn 里，很可能只有第一个跑了，剩下的全被跳过——而跳过不是失败，容易被误读成"已经做了"。

所以：

- 关键的取证、落盘、派发动作分开发出，一次一个，看到结果再继续。
- 看到 `Skipped due to pending ...` 时，先处理那条 advisory 或用户消息，然后**重新发起**被跳过的调用；绝不把跳过的结果算作已完成或已验证。
- 需要并行的是 **worker**，不是你的工具调用。
