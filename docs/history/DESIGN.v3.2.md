# 多 Agent 软件开发流水线设计（通用版 v3.2，herdr-agent 模式）

> 本文与具体项目无关，可整体复用到其他仓库。项目相关的路径、ID、实测记录全部放在**附录**。最后更新：2026-10-14（UTC+8）。

## 0. 一页摘要
- **编排底座**：herdr（终端工作区管理器）。编排脚本必须跑在 herdr pane 内（`HERDR_ENV=1`）；每个任务一个 git worktree + 一个 herdr workspace；长会话 agent 用 `herdr agent start/prompt --wait/read/get`，一次性步骤用 `pane run` + `wait-output`。只关闭本流水线创建的界面，ID 全部取自 JSON 返回值。
- **流水线**：S0 需求访谈 → S1 规格 → S2 测试先行 → S3 实现 → S4 确定性门禁 →（S4.5 预审）→ S5 代码评审 ‖ S6 安全评审 → S7 文档 → S8 终审（含隐藏验收）→ 提交 → S9 复盘。
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
11. **可观测 + 可恢复**：每阶段落盘；`stages.tsv`、`trace.md`、`herdr-ids.json`；支持 `RESUME=1` 从 S3 起续跑。

## 3. 阶段与模型（默认映射）
| 阶段 | 角色 | 默认 agent / 模型 / effort | 备选 | 门禁 / 产物 | 循环 |
|---|---|---|---|---|---|
| S0 | 需求访谈 | **编排者**（grill-me/grilling 流程）+ 用户 | — | task.md、acceptance.md（含 Limits）、hidden.md | 直到用户确认 |
| S1 | 规格/架构/任务拆分 | Amp `-m high` | high→medium→`s1chain`（Droid 付费→core→grok，见 6.1） | 必含 Interface / Test plan / Limits & Input domain / **Interface Stubs**（标题大小写不敏感；缺任何一节=S1 失败） | 1 次调用 |
| S1.5 | 家族分配 | 编排者（`lab_tools.py resolve`） | — | 见 3.2；不可满足 → ESCALATE | — |
| S1.8 | 接口桩 | 编排者（`lab_tools.py gen_stubs`，确定性） | — | 按 Interface Stubs 生成 `raise NotImplementedError` 桩并单独提交（S2 的基线） | — |
| S2 | 测试先行 | **Grok** `grok-4.7` effort **medium（锁定）** | 由 resolver 换家族 | prompt 预装 spec/验收/公开签名/现有测试头部，禁止探索仓库、ruff 与 unittest 各最多 1 次；**只允许改测试**（其他全部回退 + `git clean`）；先 `ruff --isolated`，红灯只能是 AssertionError/NotImplementedError 且无收集错误（不要求全部失败）；单独 commit | 1 + 1 重提示 |
| S2.5 | 测试争议裁决 | 第三家族（judge/security/review 中首个合格者） | — | 见 3.3 | 最多 1 轮 |
| S3 | 实现 | agy `gemini-3.8-flash-high`（herdr agent） | **升级**：IMPL2 由 resolver 选（默认 Grok xhigh） | 不得改测试；可提 `TEST_DISPUTE` | 见 S4 |
| S4 | 确定性门禁 | 测试 + lint（如 `ruff --isolated`） | — | **必须全绿**才进入 S5/S6 | 修复 ≤2 |
| S4.5 | 预审（可选 `PREREVIEW=1`） | Grok `grok-4.7` medium | — | 只改生产代码；破坏门禁或碰测试即回滚 | 1 |
| S5 | 代码评审（只读、单次） | Droid `gpt-6.1-sol` high | `REVIEW_AGENT=amp`（medium/high） | `VERDICT:` + BLOCKING/SUGGESTION 行；关注异步调用、线程/协程共享状态、锁竞争 | ≤2 |
| S6 | 安全评审（只读、单次，与 S5 并行） | Droid `claude-sonnet-5-5` high | — | 同上 + 一致性约束 | 同上 |
| S7 | 文档/CHANGELOG | Grok `grok-4.7` medium | agy `gemini-3.8-flash-low` | 门禁仍绿；后置闸门回退一切非文档改动 | 1 |
| S8 | 终审（公开 + 隐藏验收） | Droid `claude-opus-5-5` high | `JUDGE_AGENT=amp` | 逐条 PASS/FAIL；BLOCKING 只引用公开 id；输出经遮蔽后才给实现者；修复后 S4→增量 S5/S6（见 3.4）→S8 | 1 + 1 修复 |
| 提交 | 编排者（确定性） | git | — | 终审 APPROVE + 门禁全绿；trailer 记录各阶段模型 | — |
| S9 | 复盘 | Grok `grok-4.7` high | droid / amp | worktree `chmod -R a-w`（trap 恢复）；与现有 AGENTS.md 合并、泛化，≤30 条 | 非阻塞 |

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
- 格式纠正：REJECT 无合法 BLOCKING 行 → 同会话重提示 1 次，不计轮次。
- S8 遮蔽：n-gram（默认 6）集合 = 隐藏文本 − (spec ∪ 公开验收)；保留 `BLOCKING: [cat] (ref: id)` 前缀，只把泄露片段替换为 `[REDACTED_HIDDEN_DETAIL]`；原文只在私有目录。
- **S8 修复后的增量复审**（`review_round j<r>` + `incr_pack`）：S5/S6 只拿到预装进 prompt 的三样东西：(1) 上一轮 S8 的 BLOCKING 列表（实现者看到的遮蔽版，绝不含隐藏文本）；(2) 修复 diff（`git diff <PRE8>` + 新增未跟踪文件）；(3) 修复触及的测试文件全文（无则只列已提交测试名）。不再邀请看 `git diff $BASE`；明确禁止探索其他文件，只判断“列出的问题是否修好 + 修复 diff 是否引入新的 BLOCKING”。
- 超时：`GROK_STEP_TIMEOUT=1800s`；`CORE_SWAP_REVIEW=1` 对调 core 的 S5/S6 模型。

## 4. 评审协议（t8 复盘后引入）
- **单次全量**：每条一行  
  `BLOCKING: [类别] (ref: 规格/验收编号) 描述 + 复现命令`  
  `SUGGESTION: [类别] 描述`  
  类别 ∈ correctness, input-domain, limits, error-handling, security, tests, docs, api, other。最后一行 `VERDICT: APPROVE|REJECT`。
- **只依据规格阻塞**：规格未定义的边界情况只能是 SUGGESTION。
- **修复提示**：对每个阻塞问题，识别其整类输入、整类重测、修根因、为整类补回归测试。
- **升级（ESCALATE）**：每轮有 REJECT 时，解析器检查：本轮阻塞类别与之前已修类别重复，或出现无 ref / ref:none 的阻塞 → 停止修复，FINAL=ESCALATE，写 `escalation.md`（原因 + 各轮问题表），跳过文档/终审/提交，保留 worktree 与 herdr 界面，S9 照常运行。
- **安全评审一致性**：第 r>1 轮把上一轮结论、阻塞清单、代码改动统计放进 prompt；无新证据（复现命令）不得 APPROVE→REJECT。
- **无结论重试**：评审/终审未给出 VERDICT（崩溃/权限）重跑一次，不计入修复轮次。

## 5. 编排者职责
1. **S0 需求访谈（grill-me）**：逐轮提问、每题附推荐答案、能查的事实自己查；产出 task、公开验收（编号 A1..、含 Limits & Input domain）、隐藏验收（只测公开规格可推导的细节，考查周全而不是猜心思）。
2. 选择 profile / 模型映射，核对额度（`amp usage` 等），决定是否 `PREREVIEW=1`。
3. 在 herdr 内启动（启动器新建 tab）、按 JSON ID 追踪界面、监控进度；需求变更时中止、归档（`runs/<task>-aborted`）、清理并以新 ID 重启；额度/故障时用 `RESUME=1` 从 S3 续跑。
4. 处理 ESCALATE：阅读 `escalation.md`，与用户决定修订规格、接受为已知限制或放宽轮次。
5. 抽查终审结论（可对隐藏验收亲自跑几条命令）。
6. 合并/推送前请用户审批；采纳 S9 的 AGENTS.md 规则提案前同样征得同意。
7. 只清理本流水线创建的界面/分支（`cleanup.sh`），失败任务保留现场。

## 6. herdr 作为编排底座（`AGENT_MODE=herdr`，默认）
每个 LLM 角色是一个**长会话 herdr agent**，在任务 workspace 中各占一个 tab（名字 `<角色>-<task>`，如 `s5-review-t10`），记录在 `herdr-ids.json` 的 `sessions`。

| agent | kind | 启动参数（选模型/effort） |
|---|---|---|
| Droid | `droid` | `--settings runs/<task>/droid-settings-<会话>.json`，内容 `{"model","reasoningEffort","sessionDefaultSettings":{"autonomyLevel"}}`（已验证 TUI 显示 "GLM-5.3 (High) · Auto (Med)"） |
| Grok | `grok` | `-m grok-4.7 --effort low/medium/high/xhigh --always-approve` |
| agy | `agy` | `--model <id> --dangerously-skip-permissions`（按路径信任，退出时移除） |
| Amp | `amp` | `-m <mode>`；**默认仍走 headless**（`AMP_AGENT_MODE=headless`），见 6.2 |

**单步协议**：`herdr agent prompt <会话> "指令在 <prompt 文件>；完成后把完整答案（含末行 VERDICT）写入 <输出文件>，然后回复 DONE" --wait`。
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
- `RESUME=1`：从 S3 续跑（复用规格、测试提交、herdr 面板与 agy 会话）。

### 6.2 已知坑
- Droid 刚启动时 herdr 报 idle 但首条 prompt 可能丢失 → 启动后 sleep 3s + `agent wait --until idle`，并在"无输出文件且会话空闲"时补发一次"请写文件"。
- Amp 交互模式与 headless 一样会因 "Low Credit Balance" 被拒；herdr 把该对话框识别为 `done` 而非 `blocked`，因此 Amp 默认 headless，失败由 S1 回退处理。
- Grok high/xhigh 在大任务上思考时间长（t10 S2 32 分钟、约 13 万 token）；`STEP_TIMEOUT` 需 ≥ 30 分钟或 S2 改用 medium。
- herdr 的 `idle/done` 不保证后台子任务已结束（agy、Grok）。

## 7. 额度策略
- Amp（免费日额度）：只用 S1 一次调用；余额不足时被服务端拒绝（即使 `amp usage` 显示仍有百分比，单次请求的预估成本超过剩余额度就会被拒）→ 自动走 `s1chain` 回退；`amp usage` 记录前后差；评审/终审的 Amp 选项默认关闭。
- Droid 付费模型：只用于 S5/S6/S8 这三个高杠杆只读角色；额度用尽 → `PROFILE=core`。
- Grok：承担测试、文档、复盘、预审和升级实现等高频角色。
- agy：主实现者（快、便宜）。
- 复用：`REUSE_SPEC=1` 跳过 S1，`RESUME=1` 复用规格+测试提交，从 S3 起续跑。

## 8. 已知限制
- `droid exec -r` 只做通用枚举校验。
- Amp 家族映射为假设（anthropic）。
- Grok 阶段无沙箱只读，靠 prompt + 后置闸门/`chmod`。
- S2 耗时仍是最大瓶颈（t10 2246s、t11 1366s）；v3.2 的工具预算/预装上下文/确定性桩尚未经真实运行验证。
- **尚未真实跑到、只做过桩测试的路径**：S1 回退链、S1.8 生成桩（含真实 spec）、S2 只改测试的新闸门、争议 REJECTED/UNCLEAR、S8 修复循环 + 增量复审、格式纠正、进程排空 kill、S7 非文档回退、IMPL2 升级（v3 中 t10 真实跑过一次 Grok 升级）、新版 resolver（IMPL2≠评审家族）、新版遮蔽。

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

---
## 附录 A：本机（agents-lab）路径与文件
- 根目录 `/workspace/agents-lab`；示例仓库 `sample-repo`；worktree `wt/<task>`；产物 `runs/<task>/`；私有隐藏验收 `~/.agents-lab-private/<task>/`。
- `pipeline.sh`（v3）、`pipeline.conf`（默认映射）、`pipeline.conf.core`（回退 profile）、`run-in-herdr.sh`（启动器，转发全部配置变量）、`cleanup.sh`、`review_issues.py`（阻塞问题解析与升级判断）、`vendor/mattpocock-skills`（commit 49dd158）。
- 已安装 skills：Droid `~/.factory/skills/`（tdd、code-review、diagnosing-bugs、codebase-design、writing-for-agents、retro）；Amp `~/.config/agents/skills/`（to-spec、to-tickets、codebase-design、domain-modeling）；agy `~/.gemini/config/skills/`（tdd、diagnosing-bugs、codebase-design）。
- 工具版本：herdr 0.9.4、droid 0.241.1、agy 1.3.5、grok 1.0.52（`~/.grok/bin/grok`，`~/.local/bin/grok` 软链）。

## 附录 B：用法
```bash
cd /workspace/agents-lab
AUTO_CLEANUP=1 ACCEPTANCE=tasks/<t>-acceptance.md HIDDEN_ACCEPTANCE=~/.agents-lab-private/<t>-hidden.md \
  ./run-in-herdr.sh sample-repo <t> tasks/<t>.md
# 回退 profile / 续跑 / 选项
PROFILE=core RESUME=1 PREREVIEW=1 REVIEW_AGENT=amp JUDGE_AGENT=amp ./run-in-herdr.sh ...
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
- 桩测试（/tmp/v31）：redact（1 行遮蔽）、redcheck（好 0/坏 1）、snap_revert_except/snap_restore、fmt_fix 重提示、S8 修复循环（REJECT→fix→checks→增量评审 j1→APPROVE）、S1 回退链（kimi 失败→glm 成功）、resolver 三组合、leftovers（真实进程树检出遗留 sleep）均通过。
- t11 真实运行（PROFILE=core, PREREVIEW=1, BASE=agent/pipe-t10, TEST_FAULT_INJECT=1）：**PASS**，总 3900s，提交 591637c（测试 163752e → 争议修正 aaeb65a），7 文件 +412/-4。
  - S1 Amp high 真实可用（198s，Free 100%→92%），未触发回退链。
  - S1.5 resolver：S2=grok(xai)，IMPL2=kimi-k3(moonshot)，软约束放宽（与评审同家族）。
  - S2 闸门真实触发：第 1 次回退非桩实现改动 + 红灯含 ImportError → 重提示 → 第 2 次干净（1366s）。
  - 注入的错误测试（空年份 exit 2，违背 A4）被 agy 以 TEST_DISPUTE 指出 → qwen3.8-max 裁决 UPHELD(41s) → grok 修测试(24s) → S3 52s PASS。
  - S4.5/S5/S6/S8 全 APPROVE；S8 遮蔽 2 行（未遮蔽版仅在私有目录）；S9 17 条规则（≤30）。
- 未在 t11 真实触发、仅桩验证：S8 修复循环、格式纠正、S1 回退链、进程排空 kill、S7 非文档回退、IMPL2 升级。
- 已知问题：spec 未点名桩文件 → S2 无法保留桩，只能靠重提示（建议 S1 模板增加“Interface stubs: 文件列表”）；S2 grok 耗时仍长（1366s）。
- v3.2 桩测试（/tmp/v32，全部通过）：stubs_check（合法/NONE/越界路径/缺节）；gen_stubs（新增函数与类、已有模块追加、幂等、NotImplementedError 可调用）；s2ctx；S1.8 + S2 闸门（非测试改动被回退、部分测试通过的红灯被接受）；spec_ok 大小写不敏感；争议 REJECTED（FAILS=1，回传理由）与 UNCLEAR（ESCALATE）；resolver 4 组合（core → grok xhigh；评审含 xai → glm；S2 与实现同家族 → 被换）；redact（保留前缀、公开文本不遮蔽）；redcheck 5 例。
- 尚未用 v3.2 跑真实任务（需用户批准额度）。
