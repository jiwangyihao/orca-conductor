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

**（三）goal 必须是 Step 的身份证**。`checkpoint` 的 `goal` 不是给人看的注释，而是这个 checkpoint 唯一的可辨识标签——撞上冲突报错时，它是你判断"活跃的这个 checkpoint 属于谁"的唯一依据。所以 goal 一律写成 `P<n>/S<m> <Step 名>：<关键 id>` 的形式，例如 `P3/S3 等待观测：task-7f2a`。写成"继续调查"、"看看情况"这类无主语描述，等于自愿放弃后面的归属判定能力。

**（四）撞上"已有活跃 checkpoint"先做归属判定，不要条件反射 rewind**。跑得久了你会记不清上一个 Step 到底 rewind 过没有。不要凭记忆猜——`checkpoint` 是廉价幂等的状态探针，直接开，让报错说话。但**报错只说明"有一个活跃 checkpoint"，没说明它是谁的**：工具返回的就是干巴巴一句 `Checkpoint already active.`，不含 goal。而"刚开完 checkpoint 又重试了一次"（同一 turn 里重复发调用、被排队消息打断后重发、自己忘了刚开过）是同样常见的场景，这时活跃的正是本 Step 自己的 checkpoint，盲目 rewind 反而会把刚开始的工作切掉。

判定方法：在上下文里向上找**最近一条 `Checkpoint created.` 且其后没有 rewind 报告**的记录，读它的 `Goal:` 行。

| 活跃 checkpoint 的 goal | 含义 | 必须做什么 |
|---|---|---|
| 正是本 Step 要开的那个 | 你已经在正确的 checkpoint 里了，只是重复调用 | **什么都不用补**：不 rewind、不重开，忽略这次报错，直接继续本 Step 的工作 |
| 属于上一个 Step / 上一个 Phase | 那个 Step 没收尾 | **立刻 `rewind`**，按模板补写上一个 Step 的 report（状态承载字段一个都不能少），成功后再开本 Step 的新 checkpoint |
| 上下文里找不到 `Checkpoint created.`（被压缩/截断） | 归属不明 | 按"属于上一个 Step"处理：先 `rewind` 写一份诚实的残缺 report，再重开。多切一次报告边界的代价，远小于两个 Step 混在一起 |

另两种报错方向单一，没有歧义：

| 报错 | 含义 | 必须做什么 |
|---|---|---|
| `rewind` 报"没有活跃 checkpoint" | 当前是干净状态 | 直接开新 checkpoint 进入下一个 Step |
| `rewind` 报"该 checkpoint 已 rewound" | 已经收过尾了 | 从保留的 report 继续，不要重试 |

最危险的处理方式是把冲突报错当噪音、忽略它继续推进。后果是复合的：两个 Step 的中间上下文混在一起，之后那一次 rewind 无论怎么写都无法准确概述任何一个 Step；报告边界与 Phase 拓扑脱钩；而且只要 checkpoint 还活跃，你 yield 时就会被 `<system-warning>` 拦住，最终还是得在信息已经糊掉的状态下补写 report。

补写 report 时如果确实回忆不全，就写你能确认的部分，并显式标注"本 Step 的中间过程已丢失，以下为可确认事实"，同时补一次现场取证（`worker-list` / `orca_sweep.sh` / `conductor-state.md`）把 id 和资源清单捞回来——诚实的残缺报告比编造的完整报告有用得多。

**（五）todo 变更只在"rewind 之后、下一个 checkpoint 之前"这个窗口里生效**。rewind 不只裁剪消息，它会把 todo 状态**从 checkpoint 之前的分支重新装载**——也就是回滚到你开这个 checkpoint 那一刻的样子。后果很直接：**checkpoint 活跃期间做的任何 todo 变更都是临时的，rewind 之后一律消失**，包括你刚标的 completed、刚删的作废条目、刚重建的整张表。

所以标准时序是：

```
rewind（report 里带上 Todo 同步意图）
   ↓  ← 唯一的 todo 持久化窗口：立刻核对并落地变更
checkpoint（下一个 Step 开始）
```

具体要求：

- **rewind 成功后的第一件事就是处理 todo**，不要先派发、不要先取证、更不要直接开下一个 checkpoint。此时对照一致性判据核对一遍（见下一节），把上一个 Step 的完成项、作废项、拓扑变化一次落地。开了新 checkpoint 再想起来改，等于白改。
- **checkpoint 期间需要改 todo 也可以改**，那对当前这段推理有用（不至于自己迷路）；但要清楚它活不过 rewind。**唯一能穿过 rewind 的载体是 report 的"Todo 同步"段落**——把"应该怎么改"写在那里，rewind 之后照着重做一遍。
- 因此 report 的"Todo 同步"不是事后汇报，而是**给下一个自己的待办指令**。写"已标完 P3 的三条"没有意义（那次操作已经被回滚了），要写"P3 三条标 completed；P4/P5 因需求变更删除；按 P6 拓扑重建"。
- rewind 后重做时不要凭记忆信任 checkpoint 期间的操作结果，**重新看一眼当前 todo 实际长什么样**再改——你以为改过的东西大概率已经回到原样。

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

## Todo 同步（rewind 后立刻执行的指令，不是已完成的汇报）
- <无需变更 | 待做：<哪些条目标 completed>；<哪些条目删除> 因为 <原因>；按 Phase <n> 拓扑重建剩余条目>

## 下一步
进入 <Step 编号 Step 名>，因为 <一句话理由>。
第一个动作是 <具体命令或动作>。
```

"下一步"必须写死，尤其当你是**因为要处理突发专项而提前结束**这个 Step 的时候——否则 rewind 之后你只剩一份结论，会重新开始猜该干什么。

注意"Todo 同步"和"下一步"的执行顺序：**先把 Todo 同步做完，再开下一个 checkpoint 去执行下一步**。todo 变更在 checkpoint 里做会被下一次 rewind 回滚。

## Phase 重规划与 Todo 重置

Phase 计划不是签了字的合同。调度过程中最常见的变化是：上游结论被推翻、验收标准被修正、用户补充了新的执行要求——结果是某些**已规划但尚未执行的 Phase 部分或整体作废**，你直接跳到了一个新的 Phase。

这种变化本身没问题，危险的是它留下的痕迹：那些作废的条目在 todo 里看起来只是"还没做"。于是 todo 显示你在 Phase 3，实际 checkpoint 和 worktree 已经在 Phase 6，两套 Phase 编号开始漂移，之后每一次汇报和判断都建立在错的地图上。

一致性判据（每次 rewind 后核对一次）：**todo 的 Phase 分组能否与"当前 checkpoint 的 Phase 编号 + 当前活跃 worktree 分组"逐一对上**。对不上就是 todo 已经落后，立即重置，不要等人来问。核对与重置都放在 rewind 之后、下一个 checkpoint 之前做——这是唯一能让变更留存的窗口。

重置流程：

1. 真正做完的旧条目标 completed。
2. 作废或被取代的条目**删除**。留成 pending 会制造假滞后；标成 completed 会污染审计——两者都比删掉更糟。
3. 按当前真实拓扑重建剩余条目：当前 Phase 展开到 Step 级，下一个 Phase 粗粒度，更远的只留占位。
4. 把"废弃了哪些 Phase / 为什么 / 被什么取代"写进 `conductor-state.md`。审计信息归档到文件，执行 todo 只反映现在。

变更范围大时**整表重置**（一次覆盖写入），不要在几十条历史残留上逐条打补丁——补不干净，而且残留条目会持续误导后续判断。

规划粒度上宁可保守：下游 Phase 的形状取决于上游产出，开局就把 Phase 1–XIII 排成几十条，等于把一份必然作废的计划写进上下文，还给自己制造了一份维护不起的负担。

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
