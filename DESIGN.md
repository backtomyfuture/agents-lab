# 多 Agent 软件开发流水线设计（通用版 v3.4 FINAL，herdr-agent 模式）

> 本文与具体项目无关，可整体复用到其他仓库。项目相关的路径、ID、实测记录全部放在**附录**。最后更新：2026-10-15（UTC+8）。功能冻结：v3.4 之后只修正确性/文档。

## 0. 一页摘要
- **编排底座**：herdr（终端工作区管理器）。编排脚本必须跑在 herdr pane 内（`HERDR_ENV=1`）；每个任务一个 git worktree + 一个 herdr workspace；长会话 agent 经适配层 `ag_*` 调用 `herdr agent start/prompt --wait/read/get`，一次性步骤用 `pane run` + `wait-output`。只关闭本流水线创建的界面，ID 全部取自 JSON 返回值。
- **流水线**：S0 需求访谈 → S1 规格 → S2 测试先行 → S3 实现 → S4 确定性门禁 →（S4m 变异采样）→（S4.5 预审）→ S5 代码评审 ‖ S6 安全评审 → S7 文档 → S8 终审（含隐藏验收）→ 提交 → S9 复盘。
- **两档**：完整流水线（默认，可叠加 `PROFILE=core`）与 `LIGHT=1`（小任务，约 25 分钟：S1→S1.5/S1.8→S2→S3→S4→单一合并评审 S5→S8，见 3.6）。
- **原则**：角色分离、跨模型族验证、确定性门禁优先、有界修复环 + 升级（ESCALATE）而非空转、隐藏验收只给终审、按额度路由模型。

## 1. 依据（业界实践）
| # | 原则 | 依据（来源） |
|---|---|---|
| P1 | **先用最简单的可组合模式**：prompt chaining + gate、routing、parallelization、orchestrator-workers、evaluator-optimizer；只有确有收益才加复杂度 | Anthropic, *Building effective agents* — https://www.anthropic.com/engineering/building-effective-agents |
| P2 | **工作流（预定义代码路径）优于自由 agent**，适合定义明确的任务；每步之间加程序化 gate；设置最大迭代次数等停止条件 | 同上 |
| P3 | **evaluator-optimizer**：一个生成、一个评估并反馈循环；需要清晰评价标准 | 同上 |
| P4 | **编排者要把任务写清楚**：目标、输出格式、工具、边界；按复杂度分配投入；子 agent 结果落盘（artifact）避免"传话游戏" | Anthropic, *How we built our multi-agent research system* — https://www.anthropic.com/engineering/multi-agent-research-system |
| P5 | 多 agent 约 15× token；编码任务可并行部分较少 → **成本敏感**、只在真正独立处并行 | 同上 |
| P6 | **先探索→计划→实现→提交**；大功能先让 agent 访谈并写 SPEC，再在新会话中实现 | Claude Code best practices — https://www.anthropic.com/engineering/claude-code-best-practices |
| P7 | **必须给 agent 可运行的验证**（测试/构建/lint）；Writer/Reviewer 分离；**一个写测试、另一个写代码**；新上下文的对抗式评审；只把影响正确性/需求的发现作为阻塞，避免过度工程 | 同上 |
| P8 | **规格驱动（SDD）**：constitution → specify → plan → tasks → implement → converge；"缺少验证不算修好" | GitHub spec-kit — https://github.com/github/spec-kit (README) |
| P9 | **专用子 agent**：独立上下文、独立模型、受限工具（read-only 评审者、security sweeper 等） | Factory, Custom droids — https://docs.factory.ai/cli/configuration/custom-droids |
| P10 | **贵模型只做"第二意见"**：Amp 的 oracle 是更强推理模型，用于规划/评审/疑难调试，因成本不默认强制使用；同族不同训练目标的模型也能提供"不同声音" | Amp docs/news — https://ampcode.com/docs/tools , https://ampcode.com/news/oracle , https://ampcode.com/news/gpt-5.4-the-new-oracle |
| P11 | **SOP + 角色分工 + 结构化交付物**（PRD、接口设计、任务列表、QA）减少级联幻觉；可执行反馈循环最多 3 次重试 | MetaGPT — https://arxiv.org/abs/2308.00352 |
| P12 | **ACI 设计 + 护栏**：lint 护栏阻止错误编辑传播；"成功快、失败慢"——多次失败后恢复概率显著下降 → **有界修复循环** | SWE-agent — https://arxiv.org/abs/2405.15793 |
| P13 | herdr：从 herdr pane 内编排（HERDR_ENV=1），用 JSON 返回的 ID、`--no-focus`、`agent start/prompt --wait/read`、普通命令用 `pane run/wait-output`，不关闭非自己创建的界面 | herdr SKILL.md — https://raw.githubusercontent.com/herdrdev/herdr/master/skills/herdr/SKILL.md |
| P14 | **需求访谈先于规格**：逐轮提问、每题附推荐答案、可查的事实自己查（grill-me / grilling） | mattpocock/skills — https://github.com/mattpocock/skills |
| P15 | **好测试**：经公开接口测行为、不与实现耦合、无恒真断言 | 同上（tdd/tests.md） |

## 2. 设计原则
1. **角色分离**：规格 / 测试 / 实现 / 预审 / 代码评审 / 安全评审 / 文档 / 终审 / 复盘，各自独立上下文与落盘产物。
2. **Spec-first，且规格必须含 `## Limits & Input domain`**：数值范围与上限、资源上限（深度/长度/结果大小）、允许字符集、每种违规的错误类型+消息+退出码。没有这一节，S1 门禁失败（复用的旧规格也一样）。
3. **Test-first，测试由非实现者编写**，单独提交；实现者不得修改已提交测试（工作区哈希/差异检查）。
4. **跨模型族**：实现者一个族（Gemini），测试/文档/复盘另一族（Grok），评审/安全/终审再用其他族（OpenAI / Anthropic）。
5. **确定性门禁优先**：测试 + lint 必须全绿才进入 LLM 评审。
6. **有界修复环 + 升级**：实现修复 ≤2，评审 ≤2，终审 ≤1；出现"同类问题反复"或"规格外阻塞"即停止并 ESCALATE 给人。
7. **评审只读、单次、全量**：一次列出全部阻塞问题，按类别标注，只能以规格/验收条目为依据阻塞；其余为建议。
8. **一致性**：第 2 轮起评审拿到自己上一轮的结论和问题清单；无新证据不得翻转。
9. **信息隔离**：隐藏验收放在 worktree 与 runs/ 之外（权限 600），只拼进终审 prompt。
10. **额度感知路由**：贵/限额模型只用在杠杆最高处，并提供可一键切换的回退 profile。
11. **可观测 + 可恢复**：每阶段落盘；`stages.tsv`、`trace.md`、`herdr-ids.json`；支持 `RESUME=1` 按检查点续跑（见 3.5）。

## 3. 阶段与模型（默认映射）
| 阶段 | 角色 | 默认 agent / 模型 / effort | 备选 | 门禁 / 产物 | 循环 |
|---|---|---|---|---|---|
| S0 | 需求访谈 | **编排者**（grill-me/grilling 流程）+ 用户 | — | task.md、acceptance.md（含 Limits）、hidden.md | 直到用户确认 |
| S1 | 规格/架构/任务拆分 | Amp `-m high`（LIGHT：medium） | high→medium→`s1chain`（Droid 付费→core→grok，见 6.1）；每次 amp 调用由 `timeout -k 30 $S1_TIMEOUT`（默认 900s）包裹并计入 AMP 调用数 | 必含 Interface / Test plan / Limits & Input domain / **Interface Stubs**（标题大小写不敏感；缺任何一节=S1 失败） | 1 次调用（失败时 ≤2 次 amp） |
| S1.5 | 家族分配 | 编排者（`lab_tools.py resolve`） | — | 见 3.2；不可满足 → ESCALATE | — |
| S1.8 | 接口桩 | 编排者（`lab_tools.py gen_stubs`，确定性） | — | 按 Interface Stubs 生成 `raise NotImplementedError` 桩并单独提交（S2 的基线） | — |
| S2 | 测试先行 | **Grok** `grok-4.7` effort **medium（锁定）** | 由 resolver 换家族 | prompt 预装 spec/验收/公开签名/现有测试头部，禁止探索仓库、ruff 与 unittest 各最多 1 次；**只允许改测试**（其他全部回退 + `git clean`）；先 `ruff --isolated`，红灯只能是 AssertionError/NotImplementedError 且无收集错误（不要求全部失败）；单独 commit | 1 + 1 重提示 |
| S2.5 | 测试争议裁决 | 第三家族（judge/security/review 中首个合格者） | — | 见 3.3 | 最多 1 轮 |
| S3 | 实现 | agy `gemini-3.8-flash-high`（herdr agent） | **升级**：IMPL2 由 resolver 选（默认 Grok xhigh） | 不得改测试；可提 `TEST_DISPUTE` | 见 S4 |
| S4 | 确定性门禁 | 测试 + lint（如 `ruff --isolated`） | — | **必须全绿**才进入 S5/S6 | 修复 ≤2 |
| S4m | 测试强度（`MUTATION_N`>0） | 编排者（`lab_tools.py mutate`，确定性） | — | 在沙箱副本上对 S3 新增的生产代码行做 N 个变异（比较符/布尔/算术翻转），记录 score 和存活变异；存活变异交给 S5，**只能作为 SUGGESTION [tests]**，不得单独构成 BLOCKING；`MUTATION_GATE=fail` 时低于 `MUTATION_FLOOR` 即 ESCALATE（默认 warn） | — |
| S4.5 | 预审（可选 `PREREVIEW=1`） | Grok `grok-4.7` medium | — | 只改生产代码；破坏门禁或碰测试即回滚 | 1 |
| S5 | 代码评审（只读、单次） | Droid `gpt-6.1-sol` high | `REVIEW_AGENT=amp`（medium/high） | worktree 在 S5/S6 整个窗口内只读（引用计数 chmod，见 3.5）；JSON 结论块（优先）或最后一行 `VERDICT:`；BLOCKING 的 ref 必须是 spec/验收中真实存在的 id（否则降级为 SUGGESTION），repro 由编排者在 bwrap 只读/断网沙箱跑一次并附结果；关注异步调用、线程/协程共享状态、锁竞争 | ≤2 |
| S6 | 安全评审（只读、单次，与 S5 并行） | Droid `claude-sonnet-5-5` high | — | 同上 + 一致性约束 | 同上 |
| S7 | 文档/CHANGELOG | Grok `grok-4.7` medium | agy `gemini-3.8-flash-low` | 门禁仍绿；后置闸门回退一切非文档改动 | 1 |
| S8 | 终审（公开 + 隐藏验收） | Droid `claude-opus-5-5` high | `JUDGE_AGENT=amp` | 逐条 PASS/FAIL；worktree 只读；可选 `HIDDEN_TESTS`（S0 时由编排者编写、放在私有目录；编排者在沙箱快照中运行，只把摘要给裁判；失败时先由第三家族裁决者对照 spec 判断隐藏测试本身是否有效：INVALID → 在私有目录标记、不让任务失败；VALID 且裁判 APPROVE → ESCALATE）；BLOCKING 只引用公开 id；输出经遮蔽后才给实现者；修复后 S4→增量 S5/S6（见 3.4）→S8 | 1 + 1 修复 |
| 提交 | 编排者（确定性） | git | — | 终审 APPROVE + 门禁全绿；trailer 记录各阶段模型 | — |
| S9 | 复盘 | Grok `grok-4.7` high | droid / amp | worktree 只读；输出 `## Proposed AGENTS.md rules`，由 `rules_merge` 合并进 `rules/agents-rules.{json,md}`（不写仓库 AGENTS.md） | 非阻塞 |

**实现者升级规则**：S4 连续失败达 `IMPL_ESCALATE_AFTER`（默认 2）次，或任一轮评审/终审 REJECT → 在规划 pane 中启动第二个 herdr agent（IMPL2，由 resolver 决定，默认 Grok xhigh）接手后续修复（只升级一次，记录到 stages 与 commit trailer）。

### 3.1 临时回退 profile：`core`（Droid 付费额度用尽时）
只替换 Droid 阶段（Grok/agy/Amp 阶段不变），`PROFILE=core` 启用，去掉即恢复默认：
| 阶段 | 模型 | effort（CLI 宣称支持） |
|---|---|---|
| S5 代码评审 | `glm-5.3` | high（low/high/max） |
| S6 安全评审 | `qwen3.8-max` | xhigh（low/medium/xhigh） |
| S8 终审 | `kimi-k3` | high（off/low/high/max） |
| 若 S2/S7/S9 改回 droid | `glm-5.3` / `deepseek-v4.1-flash` | — |

注意：`droid exec -r` 只做通用枚举校验，不在模型支持列表里的值也可能被接受，以 `droid exec --help` 中各模型的列表为准。

### 3.2 家族多样性（`lab_tools.py resolve` / `s1chain`）
- 家族：gemini / xai / openai / anthropic / zhipu / qwen / moonshot / deepseek（Amp 视为 anthropic，属假设）。
- **硬约束**：S2 ≠ S3 家族；S1 ≠ S3；IMPL2 ≠ S3 且 ≠ S5/S6/S8 任一评审家族（评审不能评自己家族的修复）。
- **软约束**：S1 ≠ S2；IMPL2 ≠ S1/S2（违反时记日志）。候选按优先级排列：IMPL2 = 配置值 → Grok xhigh → Droid 付费 → core（kimi/glm/deepseek），取第一个满足硬约束者。
- core profile 下 S8=kimi-k3 → IMPL2 不能是 kimi，结果为 Grok xhigh（v3.1/t11 中曾选 kimi-k3，已修正）。
- 不可满足 → `S1.5-resolve IMPOSSIBLE` + ESCALATE；IMPL2 无候选 → 升级时转人工。

### 3.3 TEST_DISPUTE / S2.5
- 实现者输出 `TEST_DISPUTE: [file:line] (ref: id) 理由+复现`，不改测试。
- 第三家族裁判（≠ S2/S3/IMPL2）给出 `ADJUDICATION: UPHELD|REJECTED|UNCLEAR`：
  - UPHELD：S2 会话只修被争议测试 → 回退其他改动 → ruff → 提交 → 回 S3，**不计失败**。
  - REJECTED：理由回传实现者继续实现，**计 1 次 S3 失败**（参与升级计数）。
  - UNCLEAR / 无结论 / 第二次争议：ESCALATE。

### 3.4 卫生、只读与协议细节
- 回滚（S2 非测试回退、S4.5 回滚、S7 非文档回退）后在 worktree 内 `git clean -fd`（保留原有未跟踪文件）。
- 进程排空：herdr 报 idle 后找 pane shell 的遗留子进程，最多等 60s，记录后 kill。
- 格式纠正：REJECT 没有合法 BLOCKING 行（包括 ref 校验后全部被降级）→ 同会话重提示 1 次，不计轮次；仍没有 → 按 APPROVE + WARN 处理（3.5）。
- S8 遮蔽：n-gram（默认 6）集合 = 隐藏文本 − (spec ∪ 公开验收)；保留 `BLOCKING: [cat] (ref: id)` 前缀，只把泄露片段替换为 `[REDACTED_HIDDEN_DETAIL]`；原文只在私有目录。
- **S8 修复后的增量复审**（`review_round j<r>` + `incr_pack`）：S5/S6 只拿到预装进 prompt 的三样东西：(1) 上一轮 S8 的 BLOCKING 列表（实现者看到的遮蔽版，绝不含隐藏文本）；(2) 修复 diff（`git diff <PRE8>` + 新增未跟踪文件）；(3) 修复触及的测试文件全文（无则只列已提交测试名）。不再邀请看 `git diff $BASE`；明确禁止探索其他文件，只判断“列出的问题是否修好 + 修复 diff 是否引入新的 BLOCKING”。
- 超时：`GROK_STEP_TIMEOUT=1800s`；`CORE_SWAP_REVIEW=1` 对调 core 的 S5/S6 模型。

### 3.5 运行控制（v3.3 – v3.4）
- **预算（软上限，只在阶段边界检查）**：`stage()` 每写一行就检查任务墙钟 `TASK_TIMEOUT`（默认 **7200s**；t10 成功用时 6245s）与调用次数上限 `MAX_CALLS_TOTAL/AMP/DROID/GROK/AGY` = **32/3/12/14/8**。阶段**内部**的上限是单步超时 `STEP_TIMEOUT`（1200s）/ `GROK_STEP_TIMEOUT`（1800s）。超出 → `budget.txt` + ESCALATE，exit 5。**调用次数 ≠ token**：herdr 交互会话不暴露 token/费用。上限按 t10/t11 实际编排调用数（t10：amp 2 / grok 7 / droid 3 / agy 2 / 合计 14；t11：1/6/4/2/13）约 2 倍，再加最坏情况的循环余量。t12（首次 v3.3.x 真实运行）实际 amp 2 / grok 3 / droid 3 / agy 1 / 合计 9，远低于上限；上限保持不变，仍属暂定值。S1 的 amp 调用从 v3.4 起计入 `calls.tsv`（t12 之前漏计）。LIGHT 上限见 3.6。
- **度量**：每个阶段向 `runs/<t>/metrics.jsonl` 写一行（stage/agent/model/secs/result/调用次数/累计耗时/worktree 哈希/tokens=null），调用明细在 `calls.tsv`。
- **检查点续跑**：`checkpoints.tsv` 每行 = 阶段、结论、worktree 哈希。**哈希定义**：HEAD sha + worktree 中所有被跟踪或未被忽略的未跟踪文件的（路径, 内容 sha1）+ 已删除的跟踪文件名；与暂存区状态无关；排除 `__pycache__/`、`*.pyc`；runs/ 与私有目录在 worktree 之外，天然不参与。
  - 可续跑检查点（按顺序）：S4m → S4.5 → S5+S6 → S7 → S8 → 提交。S4m/S4.5 是可选的（`MUTATION_N=0`/`PREREVIEW=0` 时缺行则跳过，不中断链条）；S5 检查点只要求 S5 行，S6 行存在时也必须 APPROVE（`SINGLE_REVIEW=1` 时没有 S6 行）；S7 只在 `SKIP_DOCS=1` 时可缺（完整流水线中 S7 缺行=从 S7 续跑，不会被跳过）。
  - `RESUME=1`：从最后一个“结论通过且哈希仍匹配”的检查点之后继续；**哈希不匹配或没有检查点 → 从 S4 开始**：在现有 worktree 上重跑 S4 检查，红则进入 S3 修复环，然后正常继续。`RESUME_FROM=S4m|S4.5|S5|S7|S8|COMMIT` 可强制。
  - **不可续跑**：S1/S2（产物通过 `REUSE_SPEC` 与测试提交复用，不重新生成）、S3（实现就在 worktree 中，没有可跳过的“结果”）、S4（确定性且便宜，总是重跑）。
- **启动恢复**：每次启动 `lab_tools.py orphans` 报告“未完成且无存活进程”的 worktree（`orphans.txt`），**只报告不删除**；`PROTECTED_TASKS`（t1 t2 t6 t7）标记为 protected。
- **结论解析**：先取最后一个 ```json {verdict, blocking:[{ref,category,desc,repro}]}``` 块并校验（REJECT 必须有 blocking，APPROVE 不得有）；文本回退时 `VERDICT:` 必须是**最后一个非空行**。JSON 中的 blocking 会同步成文本 BLOCKING 行。**作用范围**：防止误解析，例如 agent 在中途引用了工具输出里的 VERDICT；**不防恶意伪造**，写文件的 agent 想写什么都可以。
- **ref 校验**：BLOCKING 的 ref 必须是 spec/验收里真实存在的 id（验收行首的 `A1/L2/...`、spec Requirements 编号 → `R<n>`），否则降级为 SUGGESTION 并记录日志。若 REJECT 降级后已没有有效 BLOCKING → 同一会话格式纠正重提示 1 次（不计轮次）；仍没有 → **按 APPROVE 处理**，降级的条目保留为建议，文件末尾写 `WARN`，并记入 `warn-approved.txt`。
- **repro 沙箱（bwrap，fail-closed）**：只读挂载 `/usr /bin /sbin /lib /lib64` 和 `/etc` 中少量文件；worktree **快照副本**只读挂载在 `/work`；`/tmp` 为可写 tmpfs；**不挂载 $HOME（因此看不到 `~/.agents-lab-private`）**；`--unshare-all` 断网；`--clearenv`；超时 30s。repro 结果**只作参考，从不改变 BLOCKING 状态**；bwrap 不可用、启动失败或因环境原因出错/超时 → 标注 “repro unverified”，条目保持 BLOCKING；没有 bwrap 时**绝不在沙箱外运行**。私有可执行隐藏测试用同一个沙箱。
- **S1 闸门**：Requirements / Interface / Test plan / Limits / Interface Stubs 必须存在，且每节去掉占位行后至少有 `SPEC_MIN_CHARS`（15）个非空白字符。占位行包括 `-`、TBD、TODO、N/A、none、…、待定、待补充、暂无、无。这是**启发式**规则，挡不住“写了但没意义”的内容。
- **只读评审**：S5/S6（并行，整个窗口）、S8、S9 期间 worktree `chmod -R a-w`。**引用计数 + flock**：最后一个只读阶段结束时才恢复写权限，trap 兜底。这只防同用户误写，agent 可以自己 chmod 回来，不是安全边界。
- **规则库**：S9 提议的规则由 `lab_tools.py rules_merge` 合并到 `rules/agents-rules.{json,md}`。
  - 规范化：小写 → 取 `[\w中日韩]+` 词元 → 去掉否定词（never / do not / don't / must not / avoid）和虚词（always / must / should / the / a / an）→ 用空格连接。
  - 去重：规范化后完全相同即视为重复。
  - 冲突：词集合 Jaccard ≥ 0.6 且否定极性不同。
  - **不自动删除**：连续 `RULE_EXPIRE_MERGES`（10）次未再提议的规则只标记 `STALE`，由人决定；md 文件显示前 30 条。
  - 不自动写入仓库 AGENTS.md。
- **herdr 适配层**：核心逻辑只调用 `ag_exists/ag_status/ag_start/ag_prompt/ag_wait/ag_ready/ag_read`（herdr 仍是底座）；agent 启动后用轮询 idle 代替固定 sleep。模型 id 只在 `pipeline.conf`（含 `LAB_*_MODELS`，`lab_tools.py` 从环境读取）。
- **S1 超时与返回码（v3.4）**：`S1_TIMEOUT`（默认 900s；t11 high 198s、t12 medium 约 40s）。失败原因写成可读形式：`TIMEOUT(900s,rc=124)`、`KILLED(rc=143)`、`0-EMPTY-OUTPUT(killed/hung?)`（amp 收到 SIGTERM 时以 0 退出，所以“rc=0 且 spec 为空”单独标出）。S1 通过时，前面失败尝试的耗时写进结果，例如 `PASS (incl. high TIMEOUT(900s,rc=124) after 905s)`，因此 S1 秒数不会再被误读为模型本身的耗时。
- **测试**：`tests/run.sh`（无 LLM、无 herdr；伪造 herdr 二进制），覆盖上述全部路径。

### 3.6 `LIGHT=1`（v3.4，小任务档）
- **启用**：`LIGHT=1` 在 `PROFILE` 之后、`pipeline.conf` 之前加载 `pipeline.conf.light`，因此可与 `PROFILE=core` 叠加；所有值都是 `${VAR:-默认}`，环境变量仍优先。
- **阶段**：S1（amp **medium**，回退 high → s1chain）→ S1.5/S1.8 → S2 → S3 → S4 → **S5 单一评审**（一个 Droid 评审者，prompt = 代码评审 + 安全评审合并，单一结论）→ S8 → 提交。跳过 S4m（`MUTATION_N=0`）、S4.5（`PREREVIEW=0`）、S6（`SINGLE_REVIEW=1`）、S7（`SKIP_DOCS=1`）、S9 与规则合并（`SKIP_RETRO=1`）。三个开关也可单独用于完整流水线。
- **门禁不变**：S1 闸门、S1.8 桩、S2 只改测试、S4 全绿、ref 校验 + repro、只读评审、S8 隐藏验收/隐藏测试与裁决、修复环、ESCALATE 都保留。S5 的 REJECT 等同于原来 S5 或 S6 的 REJECT；增量复审同样只用一个评审者。
- **预算**：`TASK_TIMEOUT=3600`，调用上限合计/AMP/DROID/GROK/AGY = **16/2/6/6/6**。
- **预期耗时**：按 t12 实测（S1 medium 约 40s、S2 627s、S3 281s、S5 228s、S8 242s，加启动开销）约 **25 分钟**；完整流水线去掉 S1 卡死后约 39 分钟。
- **适用**：改动小（单模块、≤约 300 行）、无新增攻击面（不新增网络/文件/eval/子进程）、规格清晰的任务。**不适用**：涉及安全边界、解析不可信输入的复杂语法、并发、或需要文档交付的任务 → 用完整流水线。
- **取舍**：少一个模型家族的独立安全视角（A3 消融未做，边际价值未知）；没有变异分数，测试强度只靠 S8 与隐藏测试；README/CHANGELOG 不更新；不积累规则。

## 4. 评审协议（t8 复盘后引入）
- **单次全量**：每条一行  
  `BLOCKING: [类别] (ref: 规格/验收编号) 描述 + 复现命令`  
  `SUGGESTION: [类别] 描述`  
  类别 ∈ correctness, input-domain, limits, error-handling, security, tests, docs, api, other。结论：优先用 JSON 块 `{"verdict","blocking":[...]}`，文本 `VERDICT: APPROVE|REJECT` 作为最后一行兜底（见 3.5）。ref 必须是真实存在的公开 id（见 3.5）。
- **只依据规格阻塞**：规格未定义的边界情况只能是 SUGGESTION。
- **修复提示**：对每个阻塞问题，识别其整类输入、整类重测、修根因、为整类补回归测试。
- **升级（ESCALATE）**：每轮有 REJECT 时，解析器检查：本轮阻塞类别与之前已修类别重复，或出现无 ref / ref:none 的阻塞 → 停止修复，FINAL=ESCALATE，写 `escalation.md`（原因 + 各轮问题表），跳过文档/终审/提交，保留 worktree 与 herdr 界面，S9 照常运行。
- **安全评审一致性**：第 r>1 轮把上一轮结论、阻塞清单、代码改动统计放进 prompt；无新证据（复现命令）不得 APPROVE→REJECT。
- **无结论重试**：评审/终审未给出 VERDICT（崩溃/权限）重跑一次，不计入修复轮次。

## 5. 编排者职责
1. **S0 需求访谈（grill-me）**：逐轮提问、每题附推荐答案、能查的事实自己查；产出 task、公开验收（编号 A1..、含 Limits & Input domain）、隐藏验收（只测公开规格可推导的细节，考查周全而不是猜心思），以及可选的可执行隐藏测试 `HIDDEN_TESTS`（由编排者在 S0 编写，放在 `~/.agents-lab-private/`，600 权限，任何 agent 都看不到）。
2. 选择 profile / 模型映射，核对额度（`amp usage` 等），决定是否 `PREREVIEW=1`。
3. 在 herdr 内启动（启动器新建 tab）、按 JSON ID 追踪界面、监控进度；需求变更时中止、归档（`runs/<task>-aborted`）、清理并以新 ID 重启；额度/故障时用 `RESUME=1` 按检查点续跑（3.5）。
4. 处理 ESCALATE：阅读 `escalation.md`，与用户决定修订规格、接受为已知限制或放宽轮次。
5. 抽查终审结论（可对隐藏验收亲自跑几条命令）。
6. 合并/推送前请用户审批；把 `rules/agents-rules.md` 中的规则（处理 CONFLICT/STALE 标记后）写进仓库 AGENTS.md 前同样征得同意。
7. 只清理本流水线创建的界面/分支（`cleanup.sh`），失败任务保留现场。

## 6. herdr 作为编排底座（`AGENT_MODE=herdr`，默认）
每个 LLM 角色是一个**长会话 herdr agent**，在任务 workspace 中各占一个 tab（名字 `<角色>-<task>`，如 `s5-review-t10`），记录在 `herdr-ids.json` 的 `sessions`。

| agent | kind | 启动参数（选模型/effort） |
|---|---|---|
| Droid | `droid` | `--settings runs/<task>/droid-settings-<会话>.json`，内容 `{"model","reasoningEffort","sessionDefaultSettings":{"autonomyLevel"}}`（已验证 TUI 显示 "GLM-5.3 (High) · Auto (Med)"） |
| Grok | `grok` | `-m grok-4.7 --effort low/medium/high/xhigh --always-approve` |
| agy | `agy` | `--model <id> --dangerously-skip-permissions`（按路径信任，退出时移除） |
| Amp | `amp` | `-m <mode>`；**默认仍走 headless**（`AMP_AGENT_MODE=headless`），见 6.2 |

**单步协议**：`herdr agent prompt <会话> "指令在 <prompt 文件>；完成后把完整答案（含 JSON 结论块与末行 VERDICT）写入 <输出文件>，然后回复 DONE" --wait`。
- **文件是唯一事实来源**；若 agent 未写文件 → 用 `agent read --source recent-unwrapped` 落盘兜底。
- `--wait` 超时而会话仍 `working` → 继续 `agent wait --until idle`，**绝不向忙碌会话再发 prompt**（t10 首版的 bug：S2 超时后补发 prompt 进入队列）。
- 会话 `blocked`（审批/提问 UI）→ 记录 `BLOCKED` 到 trace，保留现场。
- 评审/终审会话跨轮复用 → 自带上一轮上下文，配合一致性规则。
- 一次性命令（门禁 checks）仍用 `pane run` + `wait-output`。
- `AGENT_MODE=headless` 回退：所有阶段改回 `droid exec` / `grok -p --prompt-file` / `amp -x` / `agy -p`。

### 6.1 其他降级与升级
- **S1 规格回退**：Amp high→medium 都失败 → `lab_tools.py s1chain`：Droid 付费（`DROID_PAID_AVAILABLE=1` 时）→ Droid core（kimi-k3、glm-5.3）→ Grok（最后）；从不用 agy（与实现者同家族）。门禁不变。
- **agy 网络故障快速失败**：transcript 匹配网络错误 → 立即升级到 IMPL2 并重发同一任务。
- `BASE_REF=<分支>`：在已有分支上叠加新功能（worktree `--base`）。
- `RESUME=1`：按检查点续跑（复用规格、测试提交、herdr 面板与 agy 会话；见 3.5）。

### 6.2 已知坑
- Droid 刚启动时 herdr 报 idle 但首条 prompt 可能丢失 → 启动后轮询状态直到 idle（`ag_ready`，最多 30s，失败再 `agent wait --until idle`），并在"无输出文件且会话空闲"时补发一次"请写文件"。
- Amp 交互模式与 headless 一样会因 "Low Credit Balance" 被拒；herdr 把该对话框识别为 `done` 而非 `blocked`，因此 Amp 默认 headless，失败由 S1 回退处理。
- Grok high/xhigh 在大任务上思考时间长（t10 S2 32 分钟、约 13 万 token）；`STEP_TIMEOUT` 需 ≥ 30 分钟或 S2 改用 medium。
- herdr 的 `idle/done` 不保证后台子任务已结束（agy、Grok）。

## 7. 额度策略
- Amp（免费日额度）：只用于 S1（正常 1 次，回退时 ≤2 次，均计入 AMP 上限；t12 一次 S1 用掉 Free 约 29%，因为 high 会话挂起前已消耗额度）；余额不足时被服务端拒绝（即使 `amp usage` 显示仍有百分比，单次请求的预估成本超过剩余额度就会被拒）→ 自动走 `s1chain` 回退；`amp usage` 记录前后差；评审/终审的 Amp 选项默认关闭。
- Droid 付费模型：只用于 S5/S6/S8 这三个高杠杆只读角色；额度用尽 → `PROFILE=core`。
- Grok：承担测试、文档、复盘、预审和升级实现等高频角色。
- agy：主实现者（快、便宜）。
- 复用：`REUSE_SPEC=1` 跳过 S1，`RESUME=1` 按检查点续跑（见 3.5）。
- 预算护栏：任务墙钟 + 各 CLI 调用次数上限（见 3.5）；S4.5 默认关闭（`PREREVIEW=0`），只在实验时开启。

## 8. 已知限制（如实）
- **家族隔离是启发式，未量化**：没有证据表明“不同家族”能显著降低共同盲点；Amp=anthropic 是假设；S4.5/S7/S9 与 S2 同为 xai（Grok）。没有做过消融实验（见 8.1）。
- **没有真正的 agent 沙箱**：agy `--dangerously-skip-permissions`、grok `--always-approve`、Droid 评审 autonomy=medium。bwrap 可用（本机 `/usr/bin/bwrap`，非特权 user namespace 可用），但只用于编排者自己执行的代码（repro、隐藏测试；变异测试在临时副本中运行）。agent 进程由 herdr 在 pane 中启动并做 kind 检测，用 bwrap 包装可能破坏检测与登录态，未验证 → 未做。评审只读 = 引用计数 chmod（防误写，不防恶意）。repro/隐藏测试沙箱的挂载见 3.5（看不到 $HOME 与私有目录）。
- **无 token/费用数据**：herdr 交互模式下 CLI 不暴露；预算以调用次数 + 墙钟近似。
- **外部 CLI 会挂起**：t12 中 amp 的 websocket 断线后不再重连（附录 E）。S1 现有硬超时；其他阶段依赖 `STEP_TIMEOUT`/`GROK_STEP_TIMEOUT`。
- **变异测试**：采样（默认 5 个）、只覆盖新增行、较慢（t11 上 8 个变异约 215s）；默认只警告。没有 coverage.py（未安装，未安装依赖）。
- **单任务、串行**（除 S5/S6 并行）：个人单机原型，有意不做队列/并发。
- **编排仍是 bash**：状态机隐含在脚本中；检查点续跑只覆盖 S4m/S4.5/S5/S7/S8/提交（S1–S4 不可续跑，原因见 3.5）。
- **预算是软上限**：只在阶段边界检查，阶段内部靠单步超时；按调用次数计，不是 token；上限是暂定值。
- **启发式**：S1 空节检测、ref 校验、规则冲突检测、隐藏测试裁决都是启发式。
- `droid exec -r` 只做通用枚举校验。
- S2 耗时仍是最大瓶颈（t10 2246s、t11 1366s、t12 627s——v3.2 预装上下文后已减半，但仍占 t12 有效耗时约 37%）。
- **t12 已真实跑通的 v3.3.x 路径**：S1 high→medium 回退（因挂起）、S1.5 resolver、S1.8（Stubs=NONE）、S2 只改测试闸门（一次通过）、herdr 适配层、调用计数、metrics.jsonl、检查点写入、JSON 结论（S5/S6）与文本回退（S8）、ref 校验（无降级）、变异采样（5/5）、可执行隐藏测试（通过）、引用计数只读、孤儿报告、规则库合并（15 条）。
- **仍未真实跑到、只做过桩测试的路径**：TEST_DISPUTE/S2.5（t12 无争议；t11 只跑过 UPHELD）、沙箱 repro（t12 repro_ran=0）、隐藏测试裁决（隐藏测试未失败）、S8 修复循环 + 增量复审、IMPL2 升级、格式纠正与“全部降级→APPROVE+WARN”、预算 ESCALATE、`RESUME=1` 检查点续跑、s1chain 非 Amp 回退、进程排空 kill、S7 非文档回退，以及 v3.4 的 `LIGHT=1` 与 S1 超时。

### 8.1 消融计划（额度允许时；需用户批准）
**先做 A1，再做 A4**；其余待定。每个变体在同一组小任务上跑（复用规格 `REUSE_SPEC=1`，模型与 profile 固定），指标取 `metrics.jsonl`：总耗时、调用次数、S5–S8 REJECT 轮数、隐藏验收/可执行隐藏测试通过率、变异分数。
| 实验 | 变体 | 要回答的问题 |
|---|---|---|
| **A1** | `PREREVIEW=0` vs `1` | S4.5 是否减少 S5/S6 REJECT（t10/t11 中它没发现任何阻塞问题，t10 耗时 721s） |
| **A4** | `MUTATION_N=0` vs `5` | 存活变异提示是否带来更强测试/更少隐藏验收失败 |
| A2（待定） | S2 = Grok vs 与实现同家族 | 家族隔离的价值。**混杂因素**：换家族同时也换了模型能力、提示适配和速度，无法单独归因于“家族” |
| A3（待定） | S5+S6 vs **只留 S5**（对照组） | 安全评审的边际价值 |
| A5（待定） | 增量复审 vs 直接 S8 | 增量 S5/S6 是否发现新问题 |

**局限**：CLI 不支持随机种子，LLM 输出不可复现；每个变体样本很少（1–3 次）→ 结果只能看**趋势**，不能做统计结论。

## 9. 外部评审意见回应
### 9.1 v3.1 评审
| 建议 | 处理 |
|---|---|
| 实现/测试/评审家族隔离 | 采纳，改为硬+软约束 + 可审计解析器（3.2） |
| 允许实现者质疑测试 | 采纳并修改：限 1 轮、第三家族裁决、不计失败（3.3） |
| 测试先行加桩、红灯语义检查 | 采纳（表 3：S1.8/S2） |
| 隐藏标准泄露 | 采纳并加强：私有目录 + n-gram 遮蔽（3.4） |
| 回滚后清理、只读阶段、进程排空、格式纠正 | 采纳（3.4） |
| S1 回退可用 agy | 未采纳：agy 与实现者同家族 |
| 评审中的基准/排名数据 | **未核实**，未作为设计依据；仅以本仓库 t7–t11 实测为准 |

### 9.2 v3.2 评审（2026-10-15，逐条对照 t11 日志与代码）
| # | 建议 | 结论 | 依据 |
|---|---|---|---|
| 1 | 机器可读 `## Interface Stubs` + S1.8 自动生成桩，S2 只能改测试 | **采纳** | t11 S2 第 1 次：Grok 改了 `ledger/core.py`、`__main__.py`（spec 有点名但不是 NotImplementedError 桩）→ 被回退 → 红灯出现 ImportError → 需重提示 |
| 2 | `## Test plan` 匹配大小写敏感 → 静默 high | **采纳** | 确认：S1 闸门用 `grep -q '## Test plan'`，effort 判断用 `'^## Test plan'`，二者都大小写敏感且不一致。改为不敏感；S2 锁 medium；缺失=S1 失败 |
| 3 | S2 工具循环上限 | **采纳（证据不足）** | 低成本 prompt 改动；t11 transcript 未保留工具调用明细，无法证实 1366s 源于工具循环 |
| 4 | redcheck 语义 | **核实为已正确，小幅加强** | 原逻辑已是“≥1 失败 + 仅 Assertion/NotImplemented + 无收集错误”，不要求全部失败；新增显式 nonzero 判定（`FAILED (` / `tests_rc≠0`） |
| 5 | S2 prompt 预装上下文 | **采纳** | `lab_tools.py s2ctx`：桩目标模块公开签名 + 一个现有测试文件前 40 行，连同 spec/验收全文内联 |
| 6 | IMPL2 ≠ S5/S6/S8 家族（硬），≠ S1/S2（软）；core 下 IMPL2 不能是 kimi | **采纳** | t11 日志：`IMPL2 grok → droid:kimi-k3 … shares family with a reviewer (soft rule relaxed)`，而 S8=kimi-k3。注意：这把 v3.1 的“IMPL2≠S2 硬约束”降为软约束（测试已提交且不可改，同家族风险较小） |
| 7 | 遮蔽 = 隐藏 − (spec ∪ 验收)，保留前缀只替换泄露片段 | **采纳** | t11 S8 整行遮蔽 2 行，丢失 ref/类别；新实现保留前缀 |
| 8 | REJECTED → 回传理由、计 1 次失败、继续 | **采纳** | 确认原行为：REJECTED 与 UNCLEAR 一样直接 ESCALATE |
| 9 | 把 §9 并入正文 | **采纳** | 本文件即 v3.2 |
| — | “t11 S9 用时 124s” | **驳回（事实错误）** | t11 `stages.tsv`：S9-retro 262s；124s 是 t10 的 S9 |


### 9.3 v3.2 补充评审（3 条）
| # | 建议 | 结论 | 依据 |
|---|---|---|---|
| 1 | 桩签名必须可解析，生成失败不能让流水线崩溃 | **已存在，补强** | `gen_stubs` 已 `ast.parse`，S1 闸门有严格 `STUB_LINE`；桩测试：`def g(a b)` 能过正则 → S1.8 返回 1 → 流水线写 `S1.8-stubs FAIL` 并 `exit 1`（被捕获，非未捕获崩溃）。补强：`stubs_check` 现在也对每条签名 `ast.parse`，在 S1 闸门就失败（可走 S1 回退链），而不是到 S1.8 才失败 |
| 2 | 增量 S5/S6 只给 BLOCKING 列表 + 修复 diff + 相关测试，不看全量 | **采纳** | 原 prompt 含 “full change context: git diff $BASE”，邀请全量复审；已改，见 3.4 |
| 3 | 第二次争议按普通失败处理 | **驳回** | 已有：全局 `DISPUTE_ROUNDS=1`，第二次争议直接 ESCALATE。保留此设计：反复争议说明 spec/验收本身有问题，应交给人，而不是消耗修复轮次 |

### 9.4 v3.3 评审（第三方，原型 7/10、生产 4/10；逐条对照代码与日志）
| # | 断言 | 结论 | 证据 / 处理 |
|---|---|---|---|
| 1a | 相对 P1/P2 过于复杂 | **部分属实** | 13 个阶段、约 600 行 bash；个人原型可接受，但价值未量化 → 8.1 消融计划 |
| 1b | S4.5 代价高、收益低 | **属实** | t10：721s，结论“No production code changes”；t11：249s，只做了外观清理（删未用包装函数等），没有发现阻塞问题。`PREREVIEW` 默认本来就是 0，只在实验中开启 |
| 1c | S9 规则在 AGENTS.md 中重复 | **不属实（机制层面属实）** | 流水线从不写 AGENTS.md（sample-repo 所有分支都没有该文件），S9 只输出提议；但合并依赖 LLM → 新增确定性 `rules_merge`（去重/冲突/过期/上限） |
| 2 | 与 herdr / 模型 id 强耦合 | **部分属实** | pipeline.sh 中已经没有模型 id（grep 为 0），但 lab_tools.py 中硬编码了模型列表 → 移到 conf（`LAB_*_MODELS`）；约 35 处直接调用 herdr → 增加适配层函数。herdr 作为底座保留（用户选择） |
| 3a | 依赖 sleep 等待 | **部分属实** | `sleep 3`+wait 用于 agent 启动 → 改为轮询 idle；drain 中的 sleep 是有界的排空等待，保留 |
| 3b | prompt 丢失 | **已修复（v3）** | t9b 中出现过；现在等待 idle，缺输出文件时补发，忙时不重发 |
| 3c | 无全局超时 / 事务 / 幂等 | **属实（部分已有）** | 原来只有单步超时；快照/回滚已有（S2/S4.5/S7）。新增 `TASK_TIMEOUT` + 调用上限 + 检查点 |
| 3d | RESUME 只能从 S3 开始 | **属实** | 原代码 `RESUME` = 从 S3 起 → 改为检查点续跑 |
| 3e | 孤儿 worktree/tab 无法恢复 | **属实** | 新增启动时报告（不删除）；当前报告：t1 的 3 个 herdr worktree 为 ORPHAN（protected） |
| 4 | 家族隔离薄弱 | **属实（启发式）** | Amp=anthropic 未验证；S4.5/S7 与 S2 同为 xai。未改代码，在 §8 中如实说明并列入消融 A2 |
| 5 | 危险权限 / 无沙箱 | **属实** | agy skip-permissions、grok always-approve、Droid RO autonomy=medium。本机有 bwrap + unshare，无 firejail/docker/podman/nsjail。处理：编排者执行的代码走 bwrap（只读、断网），评审 chmod 只读；agent 本身未沙箱（herdr 检测/登录态风险）→ §8 |
| 6a | S1 闸门只靠 grep（空节可通过） | **部分属实** | v3.2 已有 stubs_check；空节确实能通过 → 修复 |
| 6b | redcheck 不衡量测试强度 | **属实** | → S4 变异采样（t11 实测：8 个变异杀死 7 个，score 0.88，存活 `core.py:81 or→and`） |
| 6c | 隐藏验收不可执行 | **属实** | → 可选 `HIDDEN_TESTS` |
| 6d | ref 泄露 | **部分属实** | 已有 n-gram 遮蔽；现在不在公开 id 集合中的 ref（如 H3）会降级为 SUGGESTION |
| 6e | 文件协议可伪造 VERDICT | **属实** | 原 `verdict()` 取全文最后一个匹配，工具输出中引用的 VERDICT 也算 → 只认 JSON 块或最后一行 |
| 7 | 没有 token/费用/时间上限 | **属实** | → 墙钟 + 调用次数上限；CLI 在 herdr 模式下不提供 token 数据 |
| 8 | 串行、单任务 | **属实，个人用途不在范围内** | 未来工作：Python 状态机 + 任务队列（体量大、需真实回归，暂缓） |
| — | 评分 7/10、4/10 | 不评论 | 主观评价 |
 
### 9.5 v3.3 评审（第四轮；功能冻结，只修正确性/语义/文档）
| # | 断言 | 结论 | 证据 / 处理 |
|---|---|---|---|
| 1 | 预算标定不合理 | **属实** | 原 `TASK_TIMEOUT=5400` < t10 成功用时 6245s；原上限是拍脑袋。改为 7200s 和 32/3/12/14/8（按 t10/t11 实测约 2 倍 + 循环余量），标注为暂定值；明确是软上限、调用 ≠ token |
| 2 | 检查点哈希/语义不清 | **属实** | 旧哈希 = HEAD + porcelain 文件名 + `git diff`：未跟踪文件的内容不计入，暂存的改动也漏掉。改为按内容的定义（3.5），测试中修改未跟踪文件内容、暂存都覆盖到了；不匹配统一回到 S4；S4m 纳入检查点；说明 S1–S4 为什么不可续跑 |
| 3 | 全部 BLOCKING 被降级时的语义 | **属实** | 旧行为：降级后 fmt_fix 重提示，但重提示的结果没有再做 ref 校验，仍是 REJECT 就会进入修复环。现在：重提示 1 次 → 仍无有效 BLOCKING → APPROVE + WARN |
| 4 | bwrap 挂载过宽 | **属实（严重）** | 旧代码 `--ro-bind / /`：沙箱里**能读到 $HOME 和 `~/.agents-lab-private`**；而且没有 bwrap 时直接在沙箱外运行。改为显式挂载 + 快照副本 + fail-closed；测试验证私有目录与 /home 不可见、写入失败、断网 |
| 5 | 存活变异被当成 BLOCKING | **属实** | 原 S5 提示写的是“is a BLOCKING [tests] issue” → 改为只能是 SUGGESTION |
| 6 | 隐藏测试本身可能有错 | **属实** | 原来失败 + 裁判 APPROVE 直接 ESCALATE → 先由第三家族裁决：INVALID 时在私有目录标记，不让任务失败 |
| 7 | 空节检测太弱 | **部分属实** | 已能挡住 TBD/TODO，但挡不住中文占位和过短内容 → 补上，并说明是启发式 |
| 8 | 规则过期会悄悄删规则 | **属实** | 旧代码会删除 N 次未再提议的规则 → 不再自动删除，只标 STALE 交给人 |
| 9 | S5/S6 并行时 chmod 有竞争 | **当前代码不属实，已加固** | 旧代码在 S5/S6 两者开始前 chmod 一次、`wait` 之后才恢复，没有交错；但 S9 用的是另一套 chmod，且以后改动容易引入竞争 → 引用计数 + flock，并发测试通过 |
| 10 | 桩测试散落在 /tmp | **属实** | 迁入 `tests/`（`tests/run.sh`，101 个断言全部通过），删除 /tmp 下的旧目录 |
| 11 | 文档前后不一致 | **属实** | 修正 §2.11、§5.3、§5.6、§6 单步协议、§6.1、§6.2、§4、表 3（只读范围、S4m、S9）、HIDDEN_TESTS 的编写者与时机 |
| 12 | “结论防伪”说得过头 | **属实** | 改为说明只防误解析，不防恶意伪造 |
| 13 | 消融计划过大、不可复现 | **属实** | 只保留 A1 → A4 为先；注明不可复现、A2 有混杂因素、A3 对照组改为只留 S5、结果只看趋势 |

### 9.6 t12 真实运行后的修正（v3.4）
| # | 发现 | 处理 |
|---|---|---|
| 1 | S1 的 amp 调用没有计入 `calls.tsv`/AMP 上限 | 修复：`count_call amp` + 测试 |
| 2 | S1 无硬超时，amp 挂起 19 分钟 | 修复：`S1_TIMEOUT=900` + 测试 |
| 3 | 被 kill 的 S1 记为 rc=0，S1 秒数含挂起时间却不注明 | 修复：`s1_rcdesc`（TIMEOUT/KILLED/0-EMPTY-OUTPUT），PASS 结果注明失败尝试耗时 + 测试 |
| 4 | 需要更轻的档 | `LIGHT=1`（3.6）；续跑判定容忍缺失的 S6/S7（S7 只在 `SKIP_DOCS=1` 时可缺）+ 测试 |
| 5 | tokens/cost 恒为 null | 不修：herdr 交互模式不暴露 |
| 6 | IMPL2 与 S2 同为 xai | 设计如此（软约束），记录在 trace |

---
## 附录 A：本机（agents-lab）路径与文件
- 根目录 `/workspace/agents-lab`；示例仓库 `sample-repo`；worktree `wt/<task>`；产物 `runs/<task>/`；私有隐藏验收 `~/.agents-lab-private/<task>/`。
- `pipeline.sh`（v3.4）、`pipeline.conf`（默认映射）、`pipeline.conf.core`（回退 profile）、`pipeline.conf.light`（`LIGHT=1` 叠加层）、`run-in-herdr.sh`（启动器，转发全部配置变量）、`cleanup.sh`、`review_issues.py`（阻塞问题解析与升级判断）、`vendor/mattpocock-skills`（commit 49dd158）。
- 已安装 skills：Droid `~/.factory/skills/`（tdd、code-review、diagnosing-bugs、codebase-design、writing-for-agents、retro）；Amp `~/.config/agents/skills/`（to-spec、to-tickets、codebase-design、domain-modeling）；agy `~/.gemini/config/skills/`（tdd、diagnosing-bugs、codebase-design）。
- 工具版本：herdr 0.9.4、droid 0.241.1、agy 1.3.5、grok 1.0.52（`~/.grok/bin/grok`，`~/.local/bin/grok` 软链）。

## 附录 B：用法
```bash
cd /workspace/agents-lab
AUTO_CLEANUP=1 ACCEPTANCE=tasks/<t>-acceptance.md HIDDEN_ACCEPTANCE=~/.agents-lab-private/<t>-hidden.md \
  ./run-in-herdr.sh sample-repo <t> tasks/<t>.md
# 回退 profile / 续跑 / 选项
PROFILE=core RESUME=1 PREREVIEW=1 REVIEW_AGENT=amp JUDGE_AGENT=amp ./run-in-herdr.sh ...
# 小任务档（可叠加 core）
PROFILE=core LIGHT=1 BASE_REF=<分支> ./run-in-herdr.sh sample-repo <t> tasks/<t>.md
./cleanup.sh <t> [--delete-branch] [--dry-run]
```

## 附录 C：实测记录（2026-10-14）
| 任务 | 配置 | 结果 | 要点 |
|---|---|---|---|
| t7 / t7r | v2 首版 | t7 失败保留；t7r 提交 c200743 | 修复了 reviewer 无结论、`$EXTRA` 未展开等问题 |
| t8 | 新 Droid 映射，复用 t7r 规格 | 评审门 2 轮后失败 | 每轮出现新一类问题 → 引出 Limits 节、单次全量、升级、一致性规则 |
| t9 | ledger CLI | 需求变更（按日期汇率）→ 中止归档 `runs/t9-aborted` | — |
| t9b | ledger + 按日期汇率；S1–S3 默认映射，S4 起 `PROFILE=core RESUME=1` | **PASS**，提交 789fad8（测试提交 7d353b4） | S3 agy 遇网络故障，经 2 次修复后通过；S5 glm-5.3 / S6 qwen3.8-max 一轮 APPROVE；S8 kimi-k3 APPROVE；隐藏验收抽查通过 |
| t10 | ledger `budget set/list/check`；`BASE_REF=agent/pipe-t9b`，`PROFILE=core PREREVIEW=1`，herdr-agent 模式 | **PASS**，提交 19f1cdb（测试提交 3ace0d7），总 6245s | Amp "Low Credit Balance" → S1 Grok 回退（348s）；S2 Grok high 2246s（长思考 + 超时后误补发 prompt，已修复）；agy 网络错误 → 快速升级到 Grok xhigh 完成实现；S4.5 预审 721s PASS；S5 glm-5.3 / S6 qwen3.8-max 一轮 APPROVE（845s）；S7 Grok 250s；S8 kimi-k3 APPROVE；S9 Grok 124s |


## 附录 D：v3.1 / v3.2 验证
- 桩测试（历史记录，原在 /tmp/v31，现由 `tests/` 覆盖）：redact（1 行遮蔽）、redcheck（好 0/坏 1）、snap_revert_except/snap_restore、fmt_fix 重提示、S8 修复循环（REJECT→fix→checks→增量评审 j1→APPROVE）、S1 回退链（kimi 失败→glm 成功）、resolver 三组合、leftovers（真实进程树检出遗留 sleep）均通过。
- t11 真实运行（PROFILE=core, PREREVIEW=1, BASE=agent/pipe-t10, TEST_FAULT_INJECT=1）：**PASS**，总 3900s，提交 591637c（测试 163752e → 争议修正 aaeb65a），7 文件 +412/-4。
  - S1 Amp high 真实可用（198s，Free 100%→92%），未触发回退链。
  - S1.5 resolver：S2=grok(xai)，IMPL2=kimi-k3(moonshot)，软约束放宽（与评审同家族）。
  - S2 闸门真实触发：第 1 次回退非桩实现改动 + 红灯含 ImportError → 重提示 → 第 2 次干净（1366s）。
  - 注入的错误测试（空年份 exit 2，违背 A4）被 agy 以 TEST_DISPUTE 指出 → qwen3.8-max 裁决 UPHELD(41s) → grok 修测试(24s) → S3 52s PASS。
  - S4.5/S5/S6/S8 全 APPROVE；S8 遮蔽 2 行（未遮蔽版仅在私有目录）；S9 17 条规则（≤30）。
- 未在 t11 真实触发、仅桩验证：S8 修复循环、格式纠正、S1 回退链、进程排空 kill、S7 非文档回退、IMPL2 升级。
- 已知问题：spec 未点名桩文件 → S2 无法保留桩，只能靠重提示（建议 S1 模板增加“Interface stubs: 文件列表”）；S2 grok 耗时仍长（1366s）。
- v3.2 桩测试（历史记录，原在 /tmp/v32，现由 `tests/` 覆盖）：stubs_check（合法/NONE/越界路径/缺节）；gen_stubs（新增函数与类、已有模块追加、幂等、NotImplementedError 可调用）；s2ctx；S1.8 + S2 闸门（非测试改动被回退、部分测试通过的红灯被接受）；spec_ok 大小写不敏感；争议 REJECTED（FAILS=1，回传理由）与 UNCLEAR（ESCALATE）；resolver 4 组合（core → grok xhigh；评审含 xai → glm；S2 与实现同家族 → 被换）；redact（保留前缀、公开文本不遮蔽）；redcheck 5 例。
- 尚未用 v3.2 跑真实任务（需用户批准额度）。
- v3.3 桩测试（已迁入 `tests/`，见附录 D 末尾）：spec_sections（缺节/空节）；ground（未知 ref 与 H3 降级；repro 在 bwrap 中运行，写 worktree 被拒 “Read-only file system”）；parse_verdict（中间伪造的 VERDICT 被忽略、JSON 优先并同步成 BLOCKING、无效 JSON 回退文本）；mutate（t11 相对 t10：8/7，0.88，worktree 未被改动）；hidden_tests（植入的错误测试 → 失败，正确的 → 通过）；rules_merge（去重、冲突标记、过期）；orphans；resolver 从 conf 读取模型 id；伪造 herdr 下的适配层 + 调用计数；metrics/检查点行；chmod 只读开/关；预算（调用上限、墙钟）→ ESCALATE，exit 5；检查点续跑判定（匹配→S8，哈希变化→S3，S6 REJECT→S5）；ground_review 先同步 JSON 再校验。
- v3.3.1：全部桩测试已迁到 `tests/`：`tests/run.sh` → test_lab_tools（57）、test_pipeline_funcs（31）、test_pipeline_flows（13），共 101 个断言全部通过，外加语法检查。旧的 /tmp/v3x 目录已删除。
- v3.4：test_lab_tools（57）、test_pipeline_funcs（33：S1 timeout/计数）、test_pipeline_flows（35：LIGHT 合并评审单次调用与 prompt、完整模式双评审、conf 叠加与环境优先、默认值、LIGHT/完整模式续跑判定、S1 rc 描述与 PASS 注释、SKIP_DOCS/SKIP_RETRO），共 **125** 个断言全部通过。

## 附录 E：t12 真实运行（v3.3.1，2026-10-15）
配置：`PROFILE=core`，`BASE_REF=agent/pipe-t11`，`MUTATION_N=5`（warn），`PREREVIEW=0`，可执行 `HIDDEN_TESTS`（6 个用例）+ hidden.md。任务：`ledger report --year Y --category NAME...`（L1–L4、A1–A6，Interface Stubs = NONE）。**PASS**，提交 `ccbba72`（测试提交 04de3d7，基线 591637c），总 3456s（去掉 S1 挂起约 39 分钟）。
| 阶段 | agent / 模型 | 秒 | 结果 |
|---|---|---|---|
| S1 | amp high（挂起，被 kill）→ amp medium | 1486（medium 实际约 40） | PASS |
| S1.5 / S1.8 | 编排者 | 0 | OK；stubs: none |
| S2 | grok-4.7 medium | 627 | PASS，red=clean，一次通过 |
| S3 | agy gemini-3.8-flash-high | 281 | PASS（一次，无升级、无争议） |
| S4 | ruff + unittest | 0 | PASS |
| S4m | mutate | 133 | 5/5，score 1.00，无存活 |
| S5 ‖ S6 | glm-5.3 high ‖ qwen3.8-max xhigh | 228 | APPROVE ‖ APPROVE |
| S7 | grok-4.7 medium | 224 | PASS |
| S8 | kimi-k3 high | 242 | APPROVE；隐藏测试 rc=0（未触发裁决） |
| S9 | grok-4.7 high | 182 | 规则 +15 |

- **调用**：grok 3/14、droid 3/12、agy 1/8、amp 2/3（当时漏计，见 9.6），合计 9/32。Amp Free 92%→63%。
- **metrics.jsonl**：12 行，字段一致；`agent_calls_total` 漏计 amp；tokens/cost 为 null。
- **结论解析**：S5/S6 走 JSON 块；S8 无 JSON，走文本回退（最后一行 VERDICT）；无格式纠正、无降级。
- **S1 卡死根因**：amp CLI 日志显示会话在 16:52:59 正常建立线程，16:58:03 websocket `connect_failed` → `disconnected`，`attempt=0`、`hasRetryTimer=False`，之后**再也没有重连**、没有输出；同一时间单独运行 `amp -x` 7 秒即返回。不是额度问题，也不是流水线重试。编排者在约 20 分钟时 kill 该进程，amp 以 0 退出（被记成 rc=0），随后 medium 回退约 40s 完成。→ v3.4 的 S1 超时与 rc 描述（9.6）。
- **仍未真实触发**：见 §8 列表（争议、沙箱 repro、隐藏测试裁决、S8 修复循环、IMPL2 等）。
