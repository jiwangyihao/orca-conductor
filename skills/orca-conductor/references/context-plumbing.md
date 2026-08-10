# 上下文管道：让 worker 拿到它需要的材料

worker 起在**另一个** worktree 里。它看不见你的会话、看不见你未提交的改动、也不会自动继承你的分支。上下文必须显式地推过去。

## 目录

- [三条通道](#三条通道)
- [Orca 谱系 ≠ Git 基线](#orca-谱系--git-基线)
- [派发前的落盘顺序](#派发前的落盘顺序)
- [共享目录约定](#共享目录约定)
- [跨机（--on）时的限制](#跨机--on-时的限制)
- [校验：确认它真的读到了](#校验确认它真的读到了)

## 三条通道

| 通道 | 适合放什么 | 生命周期 | 主要陷阱 |
|---|---|---|---|
| Git commit（推荐主通道） | brief、基线代码、契约文件、fixture、验收脚本 | 随分支永久存在，可 diff、可追溯 | 必须**先 commit 再派发**；worker 的 worktree 从某个 ref 创建，你后来的 commit 它看不到 |
| 共享绝对路径目录 | 进度台账、证据产物、体积大或不该进版本库的中间物 | 手动清理；`worktree rm` 不会删它 | 只在同一台机器有效；`/tmp` 可能被系统清理 |
| orchestration 邮件（`send --to dispatch:<id>`） | 纠正、追加约束、gate 的 reply、唤醒 | 进 worker 的 inbox，它下次 `check` 时收到 | 不是 prompt 注入，worker 不 check 就收不到；不要用它传长文档，传路径 |

判断规则：**内容 → git，状态 → 共享目录，指令 → 邮件。** 长文档永远走文件，邮件里只放路径和一句话意图。

## Orca 谱系 ≠ Git 基线

这是最常被搞错的一点，会直接导致 worker 在错误基线上开工：

- `--worktree new-child` / `new-top-level`、`--parent-worktree` 决定的是 **Orca 侧的父子谱系**（侧栏归组、上下文归属）。
- worker 检出的 **git 基线**由 `--base-branch <ref>` 决定；不传就用仓库默认基线（`origin/main` 一类），**不会**自动跟随你当前的特性分支。

所以"我在当前 worktree 提交了 brief，worker 是我的子 worktree，它应该能看到" 是错的——谱系是子级，基线可能仍是 `origin/main`。

正确做法：谱系和基线各自显式声明。

- 工作在概念上挂在当前任务下 → `new-child`（配合 `--parent-worktree active` 的显式写法在低层 `worktree create` 路径同理）。
- 需要建立在你的提交之上 → `--base-branch <你刚提交的 commit SHA>`。用 **SHA 而不是分支名**，因为你还会继续在这个分支上提交，分支名会漂移，SHA 不会。
- 独立、与当前工作无关的收尾任务 → `new-top-level`，基线用仓库默认基线，别从特性分支切。

## 派发前的落盘顺序

顺序不能换：

1. 写 brief 到共享目录（便于反复编辑，见下节）。
2. 把 brief（以及 worker 需要的基线代码、契约文件、验收脚本）**commit 到当前 worktree 的分支**。brief 同时进版本库的好处：worker 中断重启后 `git show` 就能拿回原文，不依赖任何外部路径。
3. `git rev-parse HEAD` 取 SHA，记下来——这是所有 worker 的共享基线，也是你 rewind report 里必须保留的字段。
4. `task-create --spec <指针 spec> --task-title <短标签>`。
5. `worker-start --task <id> --worktree new-child --name <name> --base-branch <SHA> --agent omp --setup run`。
6. 读派发回执：`ready` 才算派出去了；非零退出时看 `stage` / `effects` / `residualResources`，不要盲目重试。

派发多个并行 worker 时，第 2、3 步只做一次（共享基线唯一），第 4–6 步每个 worker 各做一次，并且**先把所有 worker 都起完再进入等待**，否则第一个 worker 的等待窗口会挡住其余派发。

## 共享目录约定

用 `$HOME` 下的固定目录按 run 分区，不要用裸 `/tmp`（可能被系统清理，且语义上像"可丢弃"）：

```
~/.orca-conductor/<run_id>/
├── brief-<task-slug>.md        # 每个 worker 一份
├── progress-<task-slug>.md     # 进度台账，worker 写、你读
├── evidence/<task-slug>/       # 日志、receipt、构建产物摘要
└── conductor-state.md          # 你自己的状态承载文件（见 phase-step-protocol.md）
```

为什么要有 `conductor-state.md`：`rewind` 会丢弃步骤内的中间上下文。task id、dispatch id、基线 SHA、各 worker 的 brief 路径这些"稍后还要用"的事实，必须落在 report 或这个文件里，否则下一步就找不回来了。

`worktree rm` 不会碰这个目录，所以回收 worktree 之后证据仍然在。任务全部结束、验收报告写完之后再整体清理。

## 跨机（--on）时的限制

`worker-start --on <saved-environment>` 把 worker 起在另一台连接的 Orca 服务器上。此时：

- 共享目录通道失效——绝对路径在对端不存在。brief、台账、证据**必须**走 git，或走 `send --to dispatch:` 的正文。
- `new-child` / `current` 这类相对选择器无效，必须用对端的精确 worktree 选择器或 `new-top-level` + 明确的 `--repo`。
- `--on` 只指定 worker 所在服务器；Run 和 Task 仍在本机，后续命令按 dispatch id 路由，**不要再重复 `--on`**。

## 校验：确认它真的读到了

不要假设 brief 被读了。在 Read-back Gate 里要求 worker 回写三个可核对的值：

- `sha256sum <brief 路径>` 的输出 → 证明读的是这一版，不是缓存里的旧版
- `git log -1 --oneline` 的实际输出 → 证明基线正确
- `git status --short` → 证明工作区干净（或者你已知的脏状态）

三个值任一不符，就在 `reply` 里纠正并要求重新回写。这一步比事后发现基线错了便宜两个数量级。
