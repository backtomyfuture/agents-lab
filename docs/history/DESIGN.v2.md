# 多 Agent 软件开发编排设计（agents-lab v2）

适用栈：herdr（编排/可视化）、Amp（免费额度 $5/天，只用于最高杠杆的推理）、agy `gemini-3.8-flash-high`（实现者，快且便宜）、Droid（多模型，用于测试/评审/安全/文档/终审）。

## 1. 业界实践调研（均已抓取原文）

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

提炼出的设计原则：
1. **角色分离**（spec / 测试 / 实现 / 评审 / 安全 / 文档 / 终审），每个角色独立上下文与结构化产物（P4,P9,P11）。
2. **Spec-first**：先有可测试的需求与接口（P6,P8,P11）。
3. **Test-first，且测试由非实现者编写**（P7）；测试先单独提交，实现者不得修改。
4. **独立验证 + 跨模型族**：实现者 Gemini，测试/代码评审 OpenAI gpt-6.1-sol，安全 Anthropic Sonnet 5.5，文档/复盘 Haiku 5.5，终审 Anthropic-Opus（P7,P10）。
5. **确定性 gate 优先**（测试、ruff）于 LLM 判断（P2,P7,P12）。
6. **有界修复循环**：实现 ≤2、评审 ≤2、终审 ≤1（P2,P11,P12）。
7. **人类关卡**：需求/验收标准确认、合并/推送前审批（P1 附录、P6）。
8. **上下文隔离与信息隔离**：隐藏验收标准只给终审（防止"应试"）（P7）。
9. **成本感知路由**：Amp 只做 spec（1 次调用，high→medium 回退）；廉价模型做文档/复盘（P1 routing, P5, P10）。
10. **可观测性**：每阶段落盘 artifact + stages.tsv + trace.md（P4）。

## 2. 流水线 v2（串行为主，评审阶段并行）

```mermaid
flowchart TD
  O0[S0 编排者: 需求澄清/验收标准/隐藏标准/预算] --> S1
  S1[S1 Spec+架构+任务拆分<br/>Amp high→medium, 1 次调用] -->|spec.md 必含 Interface/Test plan| S2
  S2[S2 测试先行<br/>Droid gpt-6.1-sol r=medium] -->|测试文件单独 commit, 应为红| S3
  S3[S3 实现<br/>agy gemini-3.8-flash-high (herdr agent)] --> S4
  S4{S4 确定性检查<br/>unittest + ruff} -->|失败 ≤2 次| S3
  S4 -->|通过| R
  subgraph R[并行评审]
    S5[S5 代码评审<br/>Droid gpt-6.1-sol r=high]
    S6[S6 安全评审<br/>Droid claude-sonnet-5-5 r=high]
  end
  R -->|任一 REJECT, ≤2 轮| F1[agy 修复 + S4 检查] --> R
  R -->|均 APPROVE| S7[S7 文档/CHANGELOG<br/>Droid claude-haiku-5-5 r=low]
  S7 --> S8{S8 终审<br/>Droid claude-opus-5-5<br/>公开+隐藏验收}
  S8 -->|REJECT ≤1 轮| F2[agy 修复] --> S8
  S8 -->|APPROVE + 检查通过| C[提交 agent/pipe-task]
  C --> S9[S9 复盘<br/>Droid claude-haiku-5-5 r=medium 或 AMP_RETRO=1]
  S9 --> H[编排者: 汇报/人工审批合并/清理]
```

## 3. 阶段表

| 阶段 | Agent / 模型 | 输入 | 输出 | Gate | 最大循环 |
|---|---|---|---|---|---|
| S0 需求接收 | 编排者（我） | 用户需求 | task.md、acceptance.md、隐藏验收（~/.agents-lab-private） | 用户确认需求/验收 | — |
| S1 Spec/架构/任务拆分 | Amp `high`→`medium` | task + 公开验收 | spec.md（Requirements/Interface/Architecture/Task breakdown/Test plan/Out of scope） | 必含 Interface 与 Test plan 节 | 1 次 + 1 次回退 |
| S2 测试先行 | Droid `gpt-6.1-sol` -r medium（auto medium；skill: tdd 的好测试准则） | spec | test_*.py（单独 commit） | 有测试文件；非测试改动被回滚；记录是否"红" | 1 |
| S3 实现 | agy `gemini-3.8-flash-high`（herdr agent，同一会话） | spec + 已提交测试 | 生产代码 | S4 通过；测试未被修改 | 1 + 2 修复 |
| S4 静态检查/单测 | 确定性：`unittest` + `ruff --select E9,F,B` | 工作区 | s*-check.log | rc=0 | 同上 |
| S5 代码评审 | Droid `gpt-6.1-sol` -r high（auto medium，只读约定；skill: code-review 双轴） | diff、spec | s5-review-N.md | VERDICT | ≤2 轮 |
| S6 安全评审（与 S5 并行） | Droid `claude-sonnet-5-5` -r high（auto medium，只读约定） | diff | s6-security-N.md | VERDICT | 同上 |
| S7 文档/变更日志 | Droid `claude-haiku-5-5` -r **low**（高 effort 会产生大量 thinking；备选 `gpt-6-luna` -r none） | spec、代码 | README.md、CHANGELOG.md | 检查仍通过；不得改 .py | 1 |
| S8 终审 | Droid `claude-opus-5-5`（只读） | 全部产物 + **隐藏验收** | s8-judge-N.md（逐条 PASS/FAIL + 证据） | VERDICT=APPROVE | 1 + 1 修复 |
| 提交 | pipeline | — | 提交（trailer 记录各阶段模型） | 终审 APPROVE 且检查通过 | — |
| S9 复盘 | Droid `claude-haiku-5-5` -r medium（/retro skill；或 Amp） | trace、stages、评审 | s9-retro.md | 非阻塞 | — |

配置：`pipeline.conf`（bash 变量，均可被环境变量覆盖）。

## 4. 编排者（我，box 外的助手）的职责

- **需求接收与澄清**：把模糊需求变成 task.md；不清楚时先问用户；拆分过大的任务。
- **编写验收标准**：公开验收（acceptance.md）+ 隐藏验收（只给终审，存 `~/.agents-lab-private/<task>/`，不进 worktree/runs）。
- **预算与额度**：开跑前后读 `amp usage`；Amp high 不可用则用 medium；额度低时 `REUSE_SPEC=1` 或手写 spec；选择 droid 模型档位。
- **把关与人工审批**：合并到 main、推送、开 PR、删除分支均需用户批准；pipeline 只提交到 `agent/pipe-<task>`。
- **冲突仲裁**：评审意见矛盾（如代码评审 vs 安全评审）或循环耗尽时，由我判断/上报，而不是让 agent 无限循环。
- **监控与重试**：看 trace/stages、herdr pane；超时/卡住（blocked）时检查 `agent read` 再决定，不盲目重发。
- **结果汇总**：读 compare/trace/judge，向用户报告（耗时、额度、提交 sha、风险）。
- **PR/合并**：用户同意后执行 merge/PR。
- **项目约定记忆**：维护项目约定（测试命令、lint 规则、目录结构），写入 task/spec 提示或 AGENTS.md。
- **清理**：成功后 AUTO_CLEANUP，失败保留现场。

## 4b. Skills 集成（mattpocock/skills @49dd158，vendor/mattpocock-skills）
| 阶段 | 谁 | skill | 用法 |
|---|---|---|---|
| S0 需求澄清 | 编排者（我） | grill-me → grilling（+ domain-modeling 可选） | 与用户逐轮提问（每题附推荐答案，事实自己查），产出 tasks/<t>.md、<t>-acceptance.md、私有 hidden 验收 |
| S1 规格 | Amp | to-spec、to-tickets、codebase-design（全局 ~/.config/agents/skills） | 去掉 issue tracker 发布步骤，输出到 spec.md；Task breakdown 用 tracer-bullet 垂直切片 |
| S2 测试 | Droid | tdd（+tests.md/mocking.md） | 只用"好测试"准则；与 tdd 的"一次一个垂直切片"冲突（我们是测试全量先行），已在 prompt 中说明 |
| S3/修复环 | agy | tdd、diagnosing-bugs、codebase-design（~/.gemini/config/skills） | 修复环先复现再修根因 |
| S5 评审 | Droid | code-review | Spec 轴 + Standards 轴，单会话内完成 |
| S9 复盘 | Droid | retro（disable-model-invocation，需 prompt 中显式 /retro） | 非交互，禁止写文件 |
| prompt 编写 | 编排者 | writing-for-agents | 改进各阶段 prompt |

## 4c. t8 复盘后的改进（2026-10-14 已实施）
1. **规格必须含 `## Limits & Input domain`**：数值范围/最大量级、资源上限（嵌套深度、输入长度、结果大小）、允许字符集、每种违规的错误类型+消息+退出码。S1 门禁检查该节；`REUSE_SPEC=1` 复用的旧规格缺该节也直接 FAIL。
2. **评审一次列全**：S5/S6 每条问题一行 `BLOCKING: [类别] (ref: 规格/验收编号) 描述+复现命令` 或 `SUGGESTION: [类别] …`；类别 = correctness/input-domain/limits/error-handling/security/tests/docs/api/other。只有违反规格或验收的才能 BLOCKING 且必须带 ref；规格未定义的边界情况只能是 SUGGESTION。
3. **修复提示**：agy 对每个阻塞问题要识别整类输入、整类重测、修根因并为整类补回归测试。
4. **升级（ESCALATE）**：`review_issues.py escalate` 在每轮评审后判断——本轮阻塞问题类别与之前轮次已修类别重复，或出现无 ref / `(ref: none)` 的规格外阻塞问题 → 停止修复环，FINAL=ESCALATE，写 `runs/<task>/escalation.md`（原因 + 各轮问题表），跳过 S7/S8/提交，S9 仍运行；herdr 界面和 worktree 保留（AUTO_CLEANUP 只在 PASS 时清理）。
5. **安全评审一致性**：第 r>1 轮 S6 prompt 带上一轮 verdict 与 BLOCKING 列表 + 代码改动统计；无新证据（复现命令）不得从 APPROVE 翻成 REJECT。

## 5. 已知限制
- 升级判断依赖评审严格遵守 BLOCKING 行格式；不按格式写的 REJECT 不会触发升级，只会按原上限耗尽轮次。
- Droid `-r` 只做通用枚举校验（none…max），某模型是否真正支持某档 effort 无法从 CLI 确认。

- 同一 Linux 用户下"隐藏"只是不放在 agent 的工作目录/提示里，agy 理论上仍能读到 `~/.agents-lab-private`（若要强隔离需不同用户或容器）。
- 安全评审提示里列出了"深嵌套/超大指数"类别，会与部分隐藏标准重叠（这是安全评审的正常职责）。

## 6. 实测（t7 / t7r，2026-10-14）
- t7（Amp `high` 真实写 spec，82 s）：S2→S4 通过；S6 安全评审前两轮因 `--auto low` 无权限跑测试而**无 VERDICT**，却被当作 REJECT 消耗了修复轮；第 3 轮真实 REJECT（指数爆内存、递归深度、复数取模 TypeError）→ 评审循环耗尽 → 不提交，现场保留。
- 修复：评审默认 `--auto medium` + 工作区哈希检查；无 VERDICT 时**基础设施重试一次**，不计修复轮；终审同理。
- t7r（复用 t7 的 spec，不耗 Amp）：S6 第 1 轮 REJECT（嵌套幂 `((2**4000)**4000)**4000` 仍爆内存）→ agy 修复 → S5/S6 APPROVE → 文档 → Opus 终审 APPROVE（含 3 条隐藏验收全部 PASS）→ 提交 c200743（测试先行提交 b4fa592）。总 1195 s。
- 新教训：实现者为过 lint 新增 `pyproject.toml` 忽略 F401（规避 gate）→ LINT_CMD 改为 `ruff check --isolated`；README 优先级描述有误被终审列为非阻塞。
