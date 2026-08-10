# Worker Brief 契约

调度失败最常见的根因不是并发、不是 worktree、不是 CLI 用错，而是**任务指示太短**。一条只有"目标 + 几条约束"的 spec 会让 worker 从零重新探索仓库、重新发明已经被否决的做法、按自己的品味定义"完成"。返工成本远高于写 brief 的成本。

本文件规定：brief 写什么、放哪里、worker 怎么确认读到了。

## 目录

- [两层结构：落盘 brief + 指针 spec](#两层结构落盘-brief--指针-spec)
- [必填章节（12 项）](#必填章节12-项)
- [Read-back Gate](#read-back-gate)
- [指针 spec 模板](#指针-spec-模板)
- [正反例对照](#正反例对照)

## 两层结构：落盘 brief + 指针 spec

| | 落盘 brief 文件 | task spec |
|---|---|---|
| 体量 | 100–400 行，想写多长写多长 | 15–30 行 |
| 内容 | 全部上下文、命令、证据、禁止项 | 目标一句话 + brief 绝对路径 + gate 要求 + 禁止项 top3 + 汇报契约 |
| 为什么 | 终端注入的文本会被折行、截断、难以复读；文件可以反复 `read`、可以 diff、可以在中断后重新加载 | spec 会进 orchestration 数据库并被注入终端，短才不会失真 |
| 落点 | 见 [context-plumbing.md](context-plumbing.md) | `task-create --spec` |

不要把 brief 正文塞进 `--spec`。也不要只给 spec 不给 brief——worker 中断重启后，spec 已经滚出它的上下文，brief 文件是它唯一能自助恢复的锚点。

`--task-title` 写 ≤60 字符的短标签（如 `route/rolldown candidate 复现`），不要把 brief 的一级标题整段灌进去；它会出现在 `task-list` 和 UI 的 worker 行里，长标题让对账变得不可读。

## 必填章节（12 项）

缺任何一项，就是在赌 worker 能猜对。每项都给"写什么 / 为什么"。

### 0. 任务身份与工作区

写：仓库名、worker 的 worktree 绝对路径、分支名、基线 commit SHA 及其语义（"这是已验收的共享祖先"）、当前 HEAD SHA、node_modules 等重型依赖是否已就绪。

为什么：worker 第一件事一定是 `git log` 定位自己在哪。你不给，它就自己猜，猜错就基于错误基线开工。

### 1. 目标与完成定义（DoD）

写：一句目标 + 一个可客观判定的清单。DoD 的每一项必须是"命令输出/文件存在/状态可见"，不能是"实现得比较完善"。

```markdown
## 完成定义
- [ ] `pnpm -w run build:sdk` 退出码 0，且 `dist/index.mjs` 存在
- [ ] `actionManagerPool` 首错在构建日志中消失（附日志路径）
- [ ] 产出 `evidence/receipt.json`，其 `acceptedFoundationCommit` 字段等于 78ec96a
```

### 2. 仓库知识路由

写：从哪个入口读起——`AGENTS.md` → `docs/INDEX.md` → 具体设计文档 → 关键目录职责。给绝对或仓库相对路径，按阅读顺序排列。

为什么：worker 的探索预算被 grep 全仓吃掉，就没有预算做正事。给路由是把你已经付过的探索成本转移给它。

### 3. 权威结论（已确认，禁止重新调查）

写：你或上一轮 worker 已经**确证**的事实，逐条标注证据来源（文件:行 / 命令输出）。

为什么：worker 默认不信任二手结论，会自己重跑一遍。显式标注"已确认，不要重新验证"可以省掉整轮探索；但只有你真的确证过才能这样标。

### 4. 失败历史与已否决方案

写：每条一行三段——**做法 → 现象/为什么不行 → 结论（禁止再试 / 仅在 X 条件下可试）**。

为什么：这是最省钱的一节。没有它，worker 会带着"聪明的新想法"重走你已经踩过的坑，而且它的报告会看起来很有道理。

### 5. 边界与所有权

写：允许修改的路径白名单、禁止修改的路径、禁止的仓库操作（`push` / `force-push` / `rebase` / 改动 lockfile / 动共享模块）。

为什么：并行 worker 之间的写冲突几乎全部来自"没说不能改"。白名单比黑名单可靠，两者都写最可靠。

### 6. 执行阶段（含 Gate）

写：Phase 0 是 read-back（见下节），Phase 1..N 是实现，每个 Phase 结尾写"产出什么文件 + 如何自证"。

### 7. 必须复跑的命令

写：可直接复制粘贴的命令，逐条附**期望输出/判据**和大致耗时。区分"每阶段都要跑"和"只在最后跑"。

为什么：不给命令，worker 会自创验证方式，然后用自创标准宣布成功。附判据是让它无法自我放水。对已知会超时的重型命令（`rm -rf node_modules`、全量安装）明确写"放后台 / 长超时，不要卡在关键路径"。

### 8. 证据与持久化契约

写：进度台账路径（见 [progress-ledger-template.md](../assets/progress-ledger-template.md)）、证据目录、commit 规范（信息语言、是否允许多个 commit、禁止 push）。明确要求：**先落盘再往下做**，且每完成一个可验证单元就更新台账。

为什么：worker 中断是常态。落盘的进度决定了你是"补发一条指令让它接着做"还是"从零重开"。这一节直接决定中断的代价。

同时写清"避免长脚本"：把多步操作写成台账里的步骤 + 单条可复跑命令，不要一次性 `bash -c` 跑几百行；长脚本一旦中途死掉，既没有中间产物也没有日志，无法判断做到哪一步。

### 9. 交付清单

写：文件级清单（路径 + 一句话说明它证明了什么）。

### 10. 验收顺序

写：你（coordinator）将按什么顺序验收，并要求 worker 在报告前**自己先按同样顺序跑一遍**。

为什么：验收顺序公开，worker 才能自查；不公开，它只会优化它以为你会看的部分。

### 11. 汇报契约

写：`worker_done` 的 subject/body 要求（body 必须包含"做了什么 / 发现了什么 / 还剩什么"）、`--outcome` 必须显式 succeeded/failed、`--files-modified` 要列全、`--report-path` 指向台账；阻塞时用 `ask` 而不是自行决策；是否需要 heartbeat 以及 `phase` 字段怎么填。

## Read-back Gate

Phase 0 只做一件事：worker 读完指定上下文，然后回写

1. 已读文件清单（路径 + 每个文件的一句话要点）
2. 它理解的基线（`git log -1 --oneline` 实际输出 + brief 文件的 `sha256sum`）
3. 分步执行计划（每步产出什么、怎么自证）
4. 它发现的矛盾或缺失信息

回写方式用 `orca orchestration ask`（阻塞等你回复），或写入台账后发 `status`。**收到 coordinator 的 `reply` 确认前，不允许改任何业务文件。**

为什么值得多花一轮：gate 只花几分钟，暴露的是"它读没读懂基线"这个唯一真正致命的问题。跳过 gate 省下的时间，会在 40 分钟后以整轮返工的形式还回来。

Gate 的验收要点：基线 SHA 对不对、有没有把已否决方案写进计划、计划步骤是否可自证。任一不对，`reply` 里直接给纠正，让它重新回写，仍然不许开工。

## 指针 spec 模板

```text
# 目标
<一句话，含关键 SHA / 路径>

# 必读（顺序不可换）
1. <brief 绝对路径>          ← 全部上下文、命令、证据、禁止项都在这里
2. <仓库 AGENTS.md 路径>
（读完执行 sha256sum <brief 绝对路径> 并在回写中附上）

# Phase 0（强制 Gate）
只做读取与回写：已读文件清单 + `git log -1 --oneline` 实际输出 + brief 的 sha256 + 分步计划 + 发现的矛盾。
用 `orca orchestration ask` 回写，收到 reply 确认前禁止修改任何业务文件。

# 硬禁止（完整清单见 brief 第 5 节）
- 禁止 push / force-push / rebase
- 禁止修改 <路径 A>、<路径 B>
- 禁止重试 brief 第 4 节列出的已否决方案

# 持久化
进度台账：<台账绝对路径>，每完成一个可验证单元立即更新；先落盘再继续。
不要一次性执行大段脚本。

# 汇报
完成或失败都发一次 worker_done，显式 --outcome，--report-path 指向台账，
--files-modified 列全；阻塞用 ask，不要自行改变边界。

# 建议使用的 skill
<skill 名 + 一句话为什么用它>
```

## 正反例对照

反例（真实事故，导致整个 task 作废重建）：

```text
# 目标
基于精确 accepted 共享祖先 78ec96a 和本地 route commit 074217f，产出 Rolldown 真实 candidate+consumer。使用 code skill。
# 基线
现有 worktree <path>，HEAD 074217f，必须证明 78ec96a 为祖先。
# 执行
1 candidate ref 指 HEAD；真实 node_modules copy；完整 shared verifier。
2 完整 Rolldown candidate，actionManagerPool 首错必须消失。
# 所有权
route/rolldown evidence，禁止改 shared、业务、bundle。
```

问题：术语（accepted / narrowing / shared verifier）没有定义也没给出处；两轮失败历史缺失，worker 会重试已否决做法；没有可复跑命令和判据；没有证据路径和持久化要求；没有验收顺序；没有 read-back gate。它看起来"很紧凑"，实际上把所有歧义都留给了 worker。

正例：把上面这段拆成 brief 的第 0/1/3/4/5/7/8/10 节写满，spec 只留指针 + gate + 禁止项 + 汇报契约。可直接套用 [worker-brief-template.md](../assets/worker-brief-template.md)。
