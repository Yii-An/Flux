# Flux 额度查询重构方案（基于 quotio / CodexBar / CLIProxyAPI / Management Center 的思路）

## 背景与约束

目标是对 Flux 的“额度/配额查询（quota/usage/limits/credits）”做一次结构性重构：

1. **不依赖 core 核心实现**：额度查询在 **Core 未安装 / 未运行** 时仍可工作；不把 `~/.cli-proxy-api`（Core/CLIProxyAPI 生成的 auth files）当作唯一数据源。
2. **不考虑向后兼容**：可以重做数据模型、文件结构、Provider 划分和刷新策略。
3. **吸收优秀思路**：融合
   - **CodexBar**：多数据源（OAuth/Web/CLI）分层 + fallback、有明确的 provider “探针”边界、强类型解析/测试
   - **Quotio**：可在不跑代理时独立查 quota（standalone quota mode）、并发刷新与 UI 聚合
   - **CLIProxyAPI**：`/v0/management/api-call` + `$TOKEN$` 替换、服务端代呼第三方、provider 特定 token refresh
   - **Management Center**：前端 config-driven 的 quota section（统一 loader / 状态模型 / 错误映射）

本方案以 **Codex quota** 为第一优先（文件名保持 `codex-quota-proposal.md`），但会给出可扩展到 Claude/Gemini/Copilot 等的统一架构。

---

## 现状分析：Flux 当前 quota 相关代码结构（问题点）

### 1) 现有数据流（从刷新到 UI）

- 自动刷新：`Flux/App/AppDelegate.swift` → `QuotaRefreshScheduler.shared.start(...)` → `QuotaAggregator.shared.refreshAll(...)`
- 聚合器：`Flux/Core/Services/QuotaAggregator.swift`
  - 通过 `CLIProxyAuthScanner.scanAuthFiles()` 扫描 `~/.cli-proxy-api` 下的 OAuth JSON
  - 并发调用 `QuotaFetcher.fetchQuotas(...)` 拉取各 provider quota
  - 内置缓存与刷新间隔控制（同时 `QuotaRefreshScheduler` 也在控制刷新）
- Fetcher 列表：`Flux/Core/Services/QuotaFetchers/*`
  - `CodexQuotaFetcher`：`GET https://chatgpt.com/backend-api/wham/usage`（可带 `Chatgpt-Account-Id`），可 refresh token（但**不回写 auth file**）
  - `ClaudeQuotaFetcher`：`GET https://api.anthropic.com/api/oauth/usage`（`anthropic-beta: oauth-2025-04-20`）
  - `GeminiCLIQuotaFetcher`：读 `~/.gemini/oauth_creds.json` + `~/.gemini/google_accounts.json`，调 `retrieveUserQuota`（**不做 refresh**，token 过期直接失败）
  - `CopilotQuotaFetcher`：`GET https://api.github.com/copilot_internal/user`（但 token 来源仍是 `~/.cli-proxy-api` 文件）
  - `AntigravityQuotaFetcher`：Cloud Code 私有 API（支持 refresh 且会回写 auth file）
- UI：
  - `Flux/Features/Quota/QuotaView.swift` + `Flux/Features/Quota/QuotaViewModel.swift`
  - Dashboard 风险卡片：`Flux/Features/Dashboard/DashboardViewModel.swift`（把 quota “压力/风险”映射为告警）

### 2) 关键耦合与不一致

1. **“不依赖 core”的目标与现状冲突**
   - Flux quota 的主路径依赖 `CLIProxyAuthScanner` 扫描 `~/.cli-proxy-api` 里的 OAuth 文件（本质上是 Core/CLIProxyAPI 产物）。
   - UI 文案也直接引导用户“把 OAuth JSON 放到 ~/.cli-proxy-api”。
2. **“凭证可用性判断”与“quota fetch 数据源”不一致**
   - `AuthFileReader`（`Flux/Core/Services/AuthFileReader.swift`）对 Copilot 判断依赖 `gh auth status`（authKind `.cli`），但实际 quota fetch 使用的是 `~/.cli-proxy-api/github-copilot-*.json` 里的 token。
   - 这会导致 Dashboard 的 `credentialsAvailableCount` 与实际 quota fetch 能否成功出现偏差。
3. **Token refresh 策略不统一**
   - Antigravity refresh 会回写 auth file（好），Codex refresh 不回写（导致重复刷新、并且下一次仍可能拿到旧 token）。
   - Gemini CLI 有 refresh_token 但不刷新，导致可用性偏低。
4. **解析与模型表达偏“弱类型 + 混合语义”**
   - 多数 provider response 使用 `JSONSerialization` + `[String: Any]`，缺少强类型模型与单元测试保护。
   - `QuotaMetrics` 同时承载“百分比(0-100)”与“绝对值(remaining/limit)”语义，`unit` 也在不同 provider 里混用（requests/credits）。
5. **刷新策略重复/耦合**
   - `QuotaAggregator.refreshAll()` 内置 refresh interval cache；`QuotaRefreshScheduler` 同时周期触发刷新，形成“双层节流”，且 `QuotaAggregator` 允许最低 5 秒，与 scheduler 最低 60 秒不一致。

---

## 重构总体目标（非兼容）

1. **主路径不依赖 Core**  
   - 不要求 Core/CLIProxyAPI 运行；不把 `~/.cli-proxy-api` 当作必须存在的凭证来源。
2. **以“官方来源”为第一类数据源**
   - Codex：`~/.codex/auth.json` 或 Codex CLI（RPC/PTY）
   - Claude：Keychain / `~/.claude/.credentials.json` 或 Claude CLI（PTY）
   - Gemini：`~/.gemini/oauth_creds.json` + 私有 quota API（含 refresh）
   - Copilot：GitHub device flow 或 `gh auth token`（不依赖 core 生成的文件）
3. **模块化：provider 逻辑强隔离 + 输出模型统一**
4. **强类型解析 + fixture 测试**
5. **单一刷新与缓存策略**（去掉重复节流；支持 in-flight 去重）
6. **可选“Core 加速路径”**（不是依赖）
   - Core 若在运行，可用 `/v0/management/api-call` 做代呼第三方（特别是 token refresh、代理出口、减少客户端内嵌 secrets），但 Core 不存在时仍可完整工作。

---

## 新架构提案：引入 `FluxQuotaKit`（独立额度子系统）

### 1) 模块边界（不依赖 Core）

建议新建一个独立模块（推荐 Swift Package，或至少独立目录 + 最小依赖），示例结构：

- `Flux/QuotaKit/Domain/*`
- `Flux/QuotaKit/Infrastructure/*`（HTTP、CLI、Keychain 抽象）
- `Flux/QuotaKit/Providers/*`（每个 provider 一目录）
- `Flux/QuotaKit/Engine/*`（聚合、缓存、调度）

**依赖约束**：

- `FluxQuotaKit` 仅依赖 `Foundation`（可选 `FoundationNetworking`），不依赖 `Flux/Core/*` 的 `CoreManager`、`FluxLogger`、`FluxError`、`ProviderID` 等类型。
- App 层通过适配器注入 logger / settings / keychain / cli executor。

### 2) 统一输出模型（借鉴 CodexBar：明确 window + identity + source）

建议用更明确的数据模型替换当前 `QuotaMetrics + ModelQuota` 的混合表达：

- `QuotaReport`
  - `providers: [ProviderQuotaReport]`
  - `generatedAt: Date`
- `ProviderQuotaReport`
  - `providerID: ProviderKind`（新的 enum，仅包含“能查 quota 的 provider”，不复用现有 `ProviderID`）
  - `accounts: [AccountQuotaReport]`
  - `bestSummary: ProviderSummary`（用于 Dashboard 快速展示）
- `AccountQuotaReport`
  - `accountID` / `email` / `displayName`
  - `plan: String?`
  - `windows: [QuotaWindow]`（5h/weekly/code-review/extra-usage/credits 等）
  - `status: QuotaStatus`（ok/authMissing/unsupported/error/stale）
  - `source: QuotaSource`（oauthApi/webCookie/cliPty/managementApiCall）
  - `fetchedAt: Date`
  - `rawDebug: String?`（可选，仅 Debug 模式）
- `QuotaWindow`
  - `id`（stable）
  - `label`
  - `usedPercent` / `remainingPercent`（Double?）
  - `used` / `limit` / `remaining`（Int?，当 API 给绝对值时填）
  - `resetAt: Date?`
  - `unit: QuotaUnit`（requests/tokens/credits）

这样 UI 可以像 Management Center 那样“渲染窗口条列表”，而 Dashboard 可以像 CodexBar 那样“挑一个 primary window 做 icon/summary”。

### 3) 引擎（Engine）职责拆分

将当前 `QuotaAggregator` 拆成 3 层：

1. `QuotaCredentialInventory`：收集/规范化凭证（不做网络）
2. `QuotaProviderRegistry`：注册 provider probes（每个 provider 的 fetch pipeline）
3. `QuotaEngine`（actor）：负责刷新、缓存、并发调度、in-flight 去重、持久化快照

刷新策略（借鉴 Management Center 的“loader 去重 + scope”）：

- 同一 provider + account + source 的请求，在一个 refresh tick 内只会发一次（in-flight cache）。
- `RefreshPolicy`：全局 interval + provider-specific min interval（避免 429）。
- `QuotaCacheStore`：把上次成功快照写到 `~/.config/flux/quota-cache.json`（启动即展示，标记为 stale）。

---

## Provider 实现建议（Phase 1：先把 Codex 做到“可用且稳”）

### 1) Codex（最高优先级）

借鉴 CodexBar 的“多源 + fallback”：

**数据源优先级**

1. OAuth API（结构化、快）
2. Codex CLI（PTY `/status` 或 RPC）作为 fallback（当 OAuth 文件缺失或 API 不可用时）
3. （可选）Core `/api-call`（当 Core 在运行时，用它代呼；但不是依赖）

**凭证来源（不依赖 core）**

- 首选：`~/.codex/auth.json` 或 `$CODEX_HOME/auth.json`
  - 解析出 `access_token` / `refresh_token` / `id_token` / `last_refresh` 等
  - 从 `id_token` payload 提取 `chatgpt_account_id`、`chatgpt_plan_type`（参考现有 `CodexQuotaFetcher.readCodexIDTokenClaims`）

**API**

- `GET https://chatgpt.com/backend-api/wham/usage`
  - Header：`Authorization: Bearer <access_token>`
  - 可选：`ChatGPT-Account-Id: <accountId>`（如果能解析到）

**Token refresh（关键改进）**

- `POST https://auth.openai.com/oauth/token`
  - `grant_type=refresh_token`
  - `refresh_token=<refresh>`
  - `client_id=<client_id>`（如果 Codex auth.json 或安装信息可得；否则用已知 Codex CLI client_id）
- refresh 成功后**回写 auth.json**（像现有 Antigravity 那样 best-effort 写回 + chmod 600）。

**窗口映射**

- `rate_limit.primary_window` → 5h/session
- `rate_limit.secondary_window` → weekly
- `code_review_rate_limit.primary_window` → code review
- 若响应有 credits：作为独立 window（unit=credits）

> 这一套可以直接替换当前 `Flux/Core/Services/QuotaFetchers/CodexQuotaFetcher.swift`，但作为“非兼容重构”，建议迁移到 `FluxQuotaKit/Providers/Codex/*` 并使用强类型 `Decodable`。

### 2) Claude（Phase 1 同步做）

**凭证来源（不依赖 core）**

- 优先：Keychain（Claude CLI 写入的 credentials）
- fallback：`~/.claude/.credentials.json`
- fallback：Claude CLI PTY `/usage`（当 OAuth scope 不足或 API 不通）

**API**

- `GET https://api.anthropic.com/api/oauth/usage`
  - `Authorization: Bearer <access_token>`
  - `anthropic-beta: oauth-2025-04-20`

**输出**

- five_hour / seven_day / seven_day_sonnet / seven_day_opus / extra_usage → windows 列表

### 3) Gemini CLI（Phase 1 做到“可自动 refresh”）

现有 `GeminiCLIQuotaFetcher` 已经能调 `retrieveUserQuota`，但缺两个关键点：

1. token 过期后刷新
2. projectId 发现逻辑更稳健

建议借鉴 CodexBar：

- 凭证：`~/.gemini/oauth_creds.json`（含 refresh_token/expiry_date）
- refresh：`POST https://oauth2.googleapis.com/token`
  - client_id/client_secret **不硬编码**：优先从 Gemini CLI 安装目录 `oauth2.js` 提取（CodexBar 的做法）
  - 抽取失败再使用 fallback（可配置）
- projectId：
  - 先用 `~/.gemini/google_accounts.json` 的括号内容（保留现有逻辑）
  - 再尝试 `GET https://cloudresourcemanager.googleapis.com/v1/projects` 找 `gen-lang-client*`（可选）
- quota：`POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

### 4) Copilot（Phase 1 改为不依赖 core 文件）

当前 Copilot quota fetch 依赖 `~/.cli-proxy-api` 中的 token，这不满足“脱离 core”。

建议改为两种来源之一：

- 使用 GitHub device flow（CodexBar 做法）并把 token 存 Keychain
- 或依赖 `gh auth token` 获取 access token（前提：用户已登录 gh）

然后调用：

- `GET https://api.github.com/copilot_internal/user`
  - Header：`Authorization: token <github_token>`（或 Bearer，根据实际返回）
  - 需要模拟部分 header（Editor-Version / Plugin-Version / User-Agent）可参考 CodexBar/Management Center

### 5) Antigravity（Phase 2：建议“降为可选插件”）

Antigravity 涉及私有 API + OAuth client secret：

- 如果坚持“客户端不内嵌 secret”，可以让 **Core 在运行时通过 `/api-call`** 完成 refresh + quota 查询（借鉴 CLIProxyAPI 的服务端代呼）。
- Core 不在时：可以把 Antigravity quota 标记为 unsupported，或允许用户显式配置 client_id/secret。

---

## “Core 加速路径”（可选，不是依赖）

借鉴 CLIProxyAPI + Management Center：把“代呼第三方 quota API”的能力抽象成一个 backend：

- `QuotaBackend`
  - `DirectBackend`：客户端直连第三方
  - `ManagementBackend`：若 Core 运行，调用 `POST http://127.0.0.1:<port>/v0/management/api-call`

好处：

- 统一 `$TOKEN$` 替换与 token refresh（尤其是 Gemini CLI / Antigravity）
- 避免浏览器/CORS 的问题（虽然 Flux 是原生 app，但仍能受益于“统一出口/代理配置”）
- 把 provider 的 URL/header/body “配置化”（接近 Management Center 的 `QuotaConfig` 思路）

但要坚持原则：**没有 Core 时仍有 DirectBackend**，所以不会形成依赖。

---

## 刷新/缓存/告警策略（吸收 Quotio + CodexBar）

1. **单一刷新入口**
   - UI 触发刷新、定时刷新，都走 `QuotaEngine.refresh(scope:)`
   - 移除 `QuotaAggregator` 内部与 `QuotaRefreshScheduler` 的双层节流，改为 Engine 统一控制。
2. **in-flight 去重**
   - 同一 provider/account/source 的请求正在进行时，后续请求复用 Task（避免 UI/后台重复打 API）。
3. **持久化快照**
   - 写到 `~/.config/flux/quota-cache.json`，启动即展示并标记 stale。
4. **告警**
   - 保留 Dashboard 的 “quotaPressure / riskyProviders” 思路，但基于新的 `ProviderSummary.primaryWindow` 计算。
   - 低额度阈值放入 Settings（类似 Quotio 的 quota alert threshold）。

---

## 对 Flux 现有结构的落地改动建议（非兼容）

### 1) 删除/替换点（建议）

- 替换 `Flux/Core/Services/QuotaAggregator.swift` → `FluxQuotaKit/Engine/QuotaEngine.swift`
- 替换 `Flux/Core/Services/QuotaRefreshScheduler.swift` → `FluxQuotaKit/Engine/QuotaScheduler.swift`（或把 scheduler 并入 engine）
- 删除 `Flux/Core/Services/CLIProxyAuthScanner.swift` 作为主路径依赖（保留为“可选 Core backend”的 credential source）
- 替换 `Flux/Core/Services/QuotaFetchers/*` → `FluxQuotaKit/Providers/*`
- 替换 `Flux/Core/Domain/Entities/Quota.swift` → `FluxQuotaKit/Domain/*`（由 app 侧做 UI 映射）

### 2) UI 层适配（最小侵入）

- `Flux/Features/Quota/QuotaViewModel.swift` 改为持有 `QuotaStore`（Observable class）：
  - `QuotaStore` 内部用 `QuotaEngine` 刷新并暴露 `providerReports`、`isRefreshing`、`errors`
- `DashboardViewModel` 的 quota 相关逻辑改为从 `QuotaStore` 读取 summary（不直接依赖 Core 下的 quota 类型）

---

## 测试与质量保障（必须补齐）

借鉴 CodexBar：每个 provider 的“解析/映射”都要有 fixture 测试。

建议新增：

- `FluxQuotaKitTests/CodexUsageResponseTests.swift`
  - fixtures：`wham/usage` 的典型响应（含 primary/secondary/code_review/credits）
  - 覆盖：字段缺失、reset_at vs reset_after_seconds、plan_type 变化
- `FluxQuotaKitTests/ClaudeOAuthUsageTests.swift`
- `FluxQuotaKitTests/GeminiRetrieveUserQuotaTests.swift`
- `FluxQuotaKitTests/CopilotEntitlementTests.swift`

并用接口注入把 HTTP 层替换为 stub（保证测试不依赖网络）。

---

## 分阶段实施建议（按收益/风险排序）

1. **Phase 1（1-2 天）：Codex quota 重构落地**
   - 新建 `FluxQuotaKit` + Codex provider（OAuth API + refresh 回写）
   - UI 通过适配层读新模型
2. **Phase 1.5（同周）：Claude / Gemini / Copilot 迁移**
   - Claude OAuth（优先）+ CLI fallback（可后置）
   - Gemini refresh + 更稳 projectId
   - Copilot 改为 device flow / gh token
3. **Phase 2（可选）：Core backend（management api-call）与 Antigravity**
   - 当 Core 在运行时才启用（加速/减少 secrets），但不作为依赖

---

## 结论

Flux 现有 quota 体系已经具备“并发刷新 + UI 聚合”的雏形，但主路径绑定了 `~/.cli-proxy-api`（Core 产物）与弱类型解析，难以满足“脱离 core”的要求，也难以扩展到更复杂的 fallback（CLI/Web）。

本方案建议以 **CodexBar 的 provider/probe 模式** 作为骨架，辅以 **Management Center 的 config-driven loader 思想** 与 **CLIProxyAPI 的可选 api-call 后端**，最终实现：

- Core 不在也能查额度
- 强类型 + 可测试
- Provider 隔离清晰，可持续扩展

