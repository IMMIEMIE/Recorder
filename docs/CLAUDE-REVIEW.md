# Claude PR 审查（`claude-review`）

`.github/workflows/claude-review.yml` 让 Claude 按 `CLAUDE.md` 的规则审查每个本仓库分支发起的 PR，并在 PR 的 head 提交上写提交状态 `claude-review`：

| 状态 | 含义 |
|---|---|
| `pending` · `reviewing` | 审查进行中 |
| `success` | 三个维度都没有阻塞问题（`unverified` 不阻塞） |
| `failure` | 有阻塞问题，或任一维度为 `fail` |
| `error` | 没有得出结论，描述里写明原因（见下方排查表） |

每个 head 提交只有一条审查评论（以 `<!-- claude-review:<sha> -->` 标记，重跑时原地更新），代码问题以行内评论标出。

## 流程

1. **`prepare`**（不调用 Claude）：解析 PR；草稿、已关闭和 fork 发起的 PR 直接跳过，不写状态。其他 PR 把 `claude-review` 设为 `pending`。
2. **`review`**：检出 PR head（完整历史），安装 Java 17 + Gradle、Python 3、.NET 10，收集关联 issue 写入 `$RUNNER_TEMP/review/issues.md`，然后以只读工具运行 Claude，并要求按 JSON schema 给出结论。
3. **`Report status`**（总会运行）：解析结论，写入最终状态并发表评论。

关联 issue 的来源：GitHub 的关联（`closingIssuesReferences`）、PR 描述里的 `Closes/Fixes/Resolves #N`（忽略 HTML 注释和代码块），以及分支名 `fix/<N>-`；最多 10 个，PR 编号会被跳过。没有关联 issue 时，需求正确性一项为 `unverified`。

审查分三个维度：需求正确性（逐条核对验收标准）、实现一致性（测试覆盖，并运行能在 Linux 上跑的现有测试：Android `core`/`app`、`check_version.sh`、`check_localization.py`、`design_tokens.py --check`、`make_icon.py --check-android`、`test_hy_session.py`、`test_windows_portable.sh`），以及系统级正确性（跨平台一致、版本号、本地化、并发、隐私与安全，以及改动接口的其他调用方）。Swift 测试脚本需要 macOS，这里只读代码核对，评论中会写明。

Claude 只能读文件、看 PR/issue、看 git 历史、运行上面列出的检查和发表行内评论；不能改代码、推送，也不能自己发 PR 评论。

## 配置

1. 在仓库上安装 Claude GitHub App：<https://github.com/apps/claude>，授权范围选择 `IMMIEMIE/Recorder`。
2. 在你自己的终端里（不要在对话里粘贴令牌）生成 OAuth 令牌并存为仓库 secret：

   ```bash
   claude setup-token
   ```

   ```bash
   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R IMMIEMIE/Recorder
   ```

   第二条命令会提示粘贴令牌。
3. 合并这个工作流到 `main`。

### 必须先在 `main` 上

claude-code-action 只在工作流文件与默认分支上的版本完全一致时才运行，否则会静默跳过。因此：

- 新增这个文件的 PR 不能审查自己，它的状态会是 `error`（`not on main yet`）。
- 修改这个文件的 PR 同样无法得到结论（`differs from main`）；合并后，以后的 PR 才会用新版本。
- 要验证新版本，合并后开一个很小的临时 PR（例如只改一行文档）看结果，再关闭它。

### 设为必需检查

在 *Settings → Rules → Rulesets* 中为 `main` 新建或编辑规则集：

1. *Target branches* 包含默认分支（`main`）。
2. 勾选 *Require status checks to pass*，点 *Add checks*，搜索并加入 `claude-review`。
3. 该检查的来源（*source*）选择 **GitHub Actions**，这样别的应用或令牌写入同名状态不会被算作通过。
4. 保存。只有在工作流至少运行过一次之后，搜索框里才能找到 `claude-review`。

注意：草稿 PR 和 fork PR 不会得到 `claude-review` 状态。草稿转为可审查（`ready_for_review`）时会自动审查；fork PR 需要把分支推到本仓库重新开 PR，或由管理员绕过规则集。

### 手动重跑

*Actions → Claude Review → Run workflow*，填入 PR 编号。也可以在某次运行页面点 *Re-run jobs*。同一个 PR 新的运行会取消旧的运行；旧运行不会覆盖新运行已经写入的状态。

## 排查

按状态描述查找：

| 状态描述 | 原因 | 处理 |
|---|---|---|
| `reviewing`（长时间不变） | 运行在排队或卡住；或运行被删除 | 看 Actions 页面；必要时手动重跑 |
| `no verdict: secret CLAUDE_CODE_OAUTH_TOKEN is missing` | 仓库没有该 secret | 按「配置」第 2 步设置 |
| `no verdict: claude-review.yml is not on main yet (merge it first)` | 工作流尚未合并到 `main` | 合并后在新 PR 上验证 |
| `no verdict: claude-review.yml differs from main, so claude-code-action skipped` | PR 修改了工作流，或 `main` 上的版本已更新而 PR 分支是旧的 | 修改工作流的 PR 预期如此；其他 PR 先合并或变基 `main` 后重跑 |
| `no verdict: Claude step failed (see run log)` | 令牌失效或额度用尽、GitHub App 未安装、Claude 运行出错 | 看 *Claude review* 步骤日志；令牌过期就重新运行 `claude setup-token` 并更新 secret |
| `no verdict: Claude step did not run (an earlier step failed)` | 检出、工具链安装或收集 issue 失败 | 看对应步骤日志后重跑 |
| `no verdict: Claude ended without structured output (e.g. max turns)` | 用完 60 轮、超时，或输出不符合 schema | 重跑；大 PR 可拆小 |
| `cancelled` | 同一 PR 有更新的运行，或手动取消 | 一般无需处理，看最新提交的状态 |
| `N blocking issue(s) · req=… impl=… sys=…` | 正常结论 | `failure` 时按评论修改后推送，会自动重新审查 |

审查结论不对（误报、漏报）时，用行内评论回复说明，然后推送修复或手动重跑；必要时由管理员绕过规则集合并。
