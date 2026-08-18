# 验收与回收

worker 说"完成了"只是一个信号，不是一个结论。回收 worktree 是必要的卫生，但删错一个就可能删掉唯一的证据，删到自己身上会直接终结调度会话。

## 目录

- [单体验收](#单体验收)
- [拒收](#拒收)
- [全量验收](#全量验收)
- [回收：自持清单原则](#回收自持清单原则)
- [回收动作与语义](#回收动作与语义)
- [自我保护](#自我保护)
- [Phase 收尾清单](#phase-收尾清单)

## 单体验收

收到 `worker_done` 后，按 brief 第 10 节公开过的**同一个顺序**独立复跑。三查：

1. **文件查**：交付清单里的每个路径是否真实存在、非空、内容与描述相符。
2. **命令查**：brief 第 7 节的必跑命令由你重新执行一遍，比对判据。worker 报告里的输出片段不作为证据——它可能跑的是别的命令、别的目录、别的参数。
3. **记录查**：`git -C <worktree> log --oneline` 与 `git -C <worktree> status --short`。确认改动落在允许的路径白名单内，确认没有 push、没有动 lockfile、没有越界改共享模块。

`worker_done` 的 `--files-modified` 与实际 `git status` 不一致，是最强的危险信号：说明它对自己做了什么都没有准确认知，报告的其余部分都要打折。

只有验收通过才 `task-update --status completed`；`--result` 里写进"被验收的证据路径"，而不是复述它的说法。

## 拒收

拒收不是惩罚，是防止污染下游。

1. `task-update --status failed --result '{"reason":"<具体到哪一条 DoD 没过 / 哪条禁止项被违反>"}'`。理由要能被三个月后的人看懂。
2. 判断根因：是 worker 执行问题，还是你的 brief 缺项？后者见 [recovery-playbook.md](recovery-playbook.md#当根因是你的指示)。
3. 决定是补发继续（现场可用、方向可纠）还是重开（现场已污染）。
4. 产出已被下游 worker 依赖时，先冻结依赖它的派发，再处理，否则错误会被放大到整个 Phase。

## 全量验收

所有 worker 结算完，Phase 出口条件逐条核对之后，再做一次跨 worker 的验收——它检查的是**单体验收看不到的东西**：

- **合并回协调工作区**：worker 的成果都躺在各自的隔离 worktree 里，把它们收拢到你的工作区（merge / cherry-pick）**本来就是 coordinator 的份内工作**，属于并行的自然必要开销，不是意外成本。若多个 worker 改了同一批文件，合并冲突是预期内的：按 S1 定下的合并策略（顺序、以谁为基准、冲突时按哪条 DoD 判优）处理，改完再跑一次各自的验收判据——**解冲突本身就可能改坏语义**。
- **集成**：把各 worker 的产物放在一起复跑端到端命令。单个通过、合起来不通过，是并行调度最典型的失败。
- **一致性**：多个 worker 是否基于同一个基线 SHA？契约文件（IDL、类型、schema）是否被各自改出了分歧？
- **清单核对**：任务级交付清单逐项对照，缺失项显式列出，不要静默省略。
- **结论落盘**：把最终结论、证据路径、未决风险写成文件（`~/.orca-conductor/<run_id>/` 下），再在会话里汇报。会话上下文会被 rewind，文件不会。

## 回收：自持清单原则

Orca 不会替你判断"这个 worktree 是不是你创建的"。`worker-list` 里能看到 `resource.ownershipState`，但 `external` / `retainedReason: legacy_ambiguous` 这类状态意味着**归属无法证明**。

所以：**你自己维护 owned 清单**。每次派发成功后立刻把 `task_id / dispatch_id / worktree 选择器 / 创建时间` 追加到 `conductor-state.md`（见 [context-plumbing.md](context-plumbing.md)）。这份清单是你后面唯一的删除授权依据。

清单之外的 worktree，一律不删。归属不明、用户接管过、`ownershipState=external` 的资源，保留并在汇报里列出来让用户自己决定——误删别人的工作区是不可逆的，而多留一个 worktree 的代价只是占点磁盘。

## 回收动作与语义

| 动作 | 命令 | 语义要点 |
|---|---|---|
| 结算终端 | `worker-release --dispatch <id>` | 只对**已结算**（succeeded / failed）的 worker 生效；只关掉该 worker 的 coordinator 自有 agent 终端，不动 setup 终端、配置 tab、被用户接管的终端。释放前会保留可检查的输出归档，**release 之后 `worker-read` 仍然能读到输出**。幂等：重复调用返回 `already_released`。只有 `release_unknown` 以退出码 1 表示失败，`retained` / `release_pending` / `already_released` 都是 0 |
| 保留现场 | `worker-retain --dispatch <id>` | 需要留着终端调试时用；它是一条持久的例外记录，之后显式 `worker-release` 才会清除。不做任何进程或文件系统动作 |
| 删除 worktree | `worktree rm --worktree <selector> [--force]` | 从 Orca 和 git 里都删掉。仓库 `orca.yaml` 定义的归档 hook 默认**跳过**，需要归档就加 `--run-hooks` |
| 全局巡检 | `worktree ps` / `worker-list` | 跨 worktree 的紧凑总览，用于对账 |

因为 release 之后输出仍可读，**先 release 终端、再决定是否删 worktree** 是安全的顺序：终端占用是持续成本，worktree 是证据。

`worktree rm` 之前必须三查：

1. 该 worktree 上**没有活的 worker**（`worker-list` 里对应 dispatch 已结算并已 release）。
2. 产物已经**转移或已被验收**——commit 已经被合并/cherry-pick 到你要保留的分支，或者证据已经复制到 `~/.orca-conductor/<run_id>/evidence/`。删 worktree 会同时删掉未提交的改动。
3. 它在你的 owned 清单里，且**不是当前 worktree**。

## 自我保护

你自己也在一个隔离 worktree 里。**删掉它会直接结束你自己的进程**，调度会话当场终止，未落盘的状态全部丢失。

派发之前先取一次自身身份并记进 `conductor-state.md`：

```bash
orca worktree current --json      # 拿到自己的 path/id 选择器
```

把这个选择器标成 `PROTECTED — NEVER REMOVE`。每次执行 `worktree rm` 前，把目标选择器与它逐字比对（路径和 id 两种形式都比）。同理，不要 release 自己所在的 coordinator 终端。

[orca_sweep.sh](../scripts/orca_sweep.sh) 会在输出顶部打印当前 worktree 并标注保护标记，用它做每个 Phase 的回收对账，可以少一次手抖。

## Phase 收尾清单

每个 Phase 结束跑一遍，不要攒到最后——攒到最后你已经分不清哪个 worktree 是哪个 Phase 的了：

- [ ] 本 Phase 所有 task 都有终态（completed / failed），没有悬空 `pending` / `running`
- [ ] 所有已结算 worker 都 `worker-release` 过；需要留的显式 `worker-retain` 并写明理由
- [ ] 证据已复制到 `~/.orca-conductor/<run_id>/evidence/`
- [ ] owned 清单里本 Phase 的 worktree 已按三查删除，或标注保留理由
- [ ] 归属不明 / external / 用户接管的资源：列进汇报，不动
- [ ] `conductor-state.md` 更新：下一 Phase 的入口基线 SHA、剩余 owned 资源
- [ ] 当前 worktree 仍标记为 PROTECTED
