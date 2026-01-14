# Flux 完整额度查询重构方案（覆盖 Claude / Codex / GeminiCLI / Antigravity / Copilot）

> 目标：在 **不依赖 Core/CLIProxyAPI** 的前提下，为 Flux 设计一个可扩展、可测试、可降级的“额度/配额（quota/usage/limits/credits）”查询系统；不考虑向后兼容，允许重做模型、目录与 provider 实现方式。  
> 参考与吸收：quotio（独立 quota 模式 + 并发刷新）、CodexBar（多数据源 + fallback + 强类型解析）、CLIProxyAPI（token refresh/替换思路）、Management Center（声明式 config + loader + 错误映射）。

---

## 0. 范围与约束

### 当前 Flux 需要覆盖的 Provider（`supportsQuota=true`）

1. **Claude**：OAuth API `GET https://api.anthropic.com/api/oauth/usage`
2. **Codex**：OAuth API `GET https://chatgpt.com/backend-api/wham/usage`
3. **GeminiCLI**：Google Cloud Code API `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
4. **Antigravity**：Google Cloud Code API（多端点 fallback，支持 refresh + 回写）
5. **Copilot**：GitHub API `GET https://api.github.com/copilot_internal/user`

### 设计硬性要求

1. **不依赖 Core/CLIProxyAPI**
   - 不要求 Core 进程运行
   - 不依赖 CLIProxyAPI 的 Management API
   - 不把 `~/.cli-proxy-api` 作为必须存在的凭证来源
2. **不考虑向后兼容**
   - 可以重做 `Quota` 模型、刷新策略、目录结构、Provider 枚举/配置
3. **每个 Provider 必须提供可落地的实现策略**
   - 数据源（data sources）
   - 认证/凭证来源（credentials）
   - API 端点与请求头
   - 解析（强类型）
   - 降级（fallback）与错误分级

---

## 1. Flux 现状简述（为什么要重构）

### 现有主要链路（代码现状）

- 调度：`Flux/Core/Services/QuotaRefreshScheduler.swift`
- 聚合：`Flux/Core/Services/QuotaAggregator.swift`
- Provider 实现：`Flux/Core/Services/QuotaFetchers/*`
- 认证文件扫描：`Flux/Core/Services/CLIProxyAuthScanner.swift`（扫描 `~/.cli-proxy-api`）
- UI：`Flux/Features/Quota/*`、Dashboard 风险：`Flux/Features/Dashboard/DashboardViewModel.swift`

### 现状问题（与目标冲突）

1. **主路径绑定 `~/.cli-proxy-api`**：等价于“依赖 Core/CLIProxyAPI 产物”。
2. **Credential 可用性判断与 quota fetch 来源不一致**：例如 Copilot `authKind=.cli`（`gh auth status`）但 quota fetch 依赖 oauth 文件 token。
3. **Token refresh 分散且不统一**：Codex refresh 不回写、GeminiCLI 不刷新、Antigravity 刷新且回写，行为不一致。
4. **弱类型解析为主**：大量 `[String: Any]`，缺 fixture 测试，容易随上游字段变化而 silent break。
5. **刷新节流策略重复**：聚合器内节流 + scheduler 定时刷新并存，行为不透明。

---

## 2. 重构目标（系统级）

1. **Stand-alone quota**：Flux 可以像 CodexBar/Quotio 一样作为“独立额度监控器”运行。
2. **多数据源 + 自动降级**：每个 provider 都定义清晰的 source 优先级与 fallback 行为。
3. **强类型解析 + fixture 测试**：所有第三方响应都可离线测试。
4. **统一的 Credential 抽象与刷新策略**：token refresh 归一化，尽量回写到来源（文件/Keychain）。
5. **统一刷新引擎**：一个 actor 负责缓存、in-flight 去重、并发调度、持久化快照。

---

## 3. 新架构总览：`FluxQuotaKit`（独立额度子系统）

> 结构参考 CodexBar 的“provider/probe”边界 + Management Center 的“loader/config”思路；但不引入 WebUI，全部在本地 app 内完成。

### 3.1 分层

```
┌──────────────────────────────────────────────────────────┐
│                      QuotaEngine (actor)                 │
│  - refresh(scope) / cache / in-flight de-dupe / persist  │
│  - per-provider backoff / error classification           │
└──────────────────────────────────────────────────────────┘
                 ↓                      ↓
┌─────────────────────────┐   ┌────────────────────────────┐
│ CredentialInventory      │   │ ProviderRegistry            │
│ - gather credentials     │   │ - provider implementations  │
│ - unify account identity │   │ - per provider fetch plan   │
└─────────────────────────┘   └────────────────────────────┘
                 ↓                      ↓
┌──────────────────────────────────────────────────────────┐
│                     ProviderQuotaService                  │
│   dataSources[] (priority chain / tryAll / stopOnFirst)   │
└──────────────────────────────────────────────────────────┘
                 ↓
┌──────────────────────────────────────────────────────────┐
│     CredentialProviders + Shared Infrastructure            │
│  - File / Keychain / Cookie / CLI / (Optional Importer)    │
│  - HTTP client / CLI runner / JSON fixtures / logging      │
└──────────────────────────────────────────────────────────┘
```

### 3.2 核心类型（建议，不做兼容）

```swift
public enum ProviderKind: String, CaseIterable, Sendable {
  case claude, codex, geminiCLI, antigravity, copilot
}

public enum QuotaStatus: String, Sendable {
  case ok, authMissing, unsupported, error, stale, loading
}

public enum QuotaSource: String, Sendable {
  case oauthApi
  case webCookieApi
  case cliPty
  case cliRpc
  case localAppData   // e.g. Antigravity app local db (可选)
  case importedFile   // 用户导入的凭证（Flux 自己保存）
}

public struct QuotaWindow: Sendable, Hashable {
  public let id: String
  public let label: String
  public let unit: QuotaUnit
  public let usedPercent: Double?
  public let remainingPercent: Double?
  public let used: Int?
  public let limit: Int?
  public let remaining: Int?
  public let resetAt: Date?
}

public struct AccountQuotaReport: Sendable, Hashable {
  public let provider: ProviderKind
  public let accountKey: String
  public let email: String?
  public let plan: String?
  public let status: QuotaStatus
  public let source: QuotaSource
  public let fetchedAt: Date
  public let windows: [QuotaWindow]
  public let errorMessage: String?
}

public struct ProviderQuotaReport: Sendable, Hashable {
  public let provider: ProviderKind
  public let fetchedAt: Date
  public let accounts: [AccountQuotaReport]
  public let summary: ProviderSummary?
}

public struct ProviderSummary: Sendable, Hashable {
  public let displayTitle: String
  public let primaryWindow: QuotaWindow?
  public let secondaryWindow: QuotaWindow?
  public let worstRemainingRatio: Double? // 0..1 for Dashboard risk
}
```

> UI 可以像 Management Center 一样“渲染窗口条列表”，Dashboard 则只看 `ProviderSummary`。

---

## 4. 目录结构（建议）

为避免与现有 `Flux/Core` 强耦合，建议新增一个明确的 quota 目录（或 Swift Package）：

```
Flux/QuotaKit/
├── Domain/
│   ├── ProviderKind.swift
│   ├── QuotaModels.swift          # QuotaWindow/Report/Summary/Status/Source
│   └── QuotaErrors.swift          # 错误分级、可恢复建议
├── Engine/
│   ├── QuotaEngine.swift          # actor: refresh/caching/in-flight
│   ├── QuotaScheduler.swift       # 定时刷新（可选；也可合并进 Engine）
│   └── QuotaCacheStore.swift      # ~/.config/flux/quota-cache.json
├── Credentials/
│   ├── Credential.swift
│   ├── CredentialProvider.swift
│   ├── CredentialInventory.swift
│   ├── Stores/
│   │   ├── FileCredentialStore.swift       # Flux 自己的 credentials dir
│   │   ├── KeychainCredentialStore.swift   # macOS Keychain 封装
│   │   └── CookieStore.swift               # 可选：浏览器 cookie 抽象
│   └── Providers/
│       ├── CodexAuthJSONProvider.swift
│       ├── ClaudeCredentialsProvider.swift
│       ├── GeminiCLIOAuthProvider.swift
│       ├── AntigravityCredentialProvider.swift
│       └── CopilotCredentialProvider.swift
├── Providers/
│   ├── ProviderQuotaService.swift          # 统一 fallback 执行器
│   ├── Claude/
│   │   ├── ClaudeOAuthUsageDataSource.swift
│   │   ├── ClaudeWebUsageDataSource.swift      # 可选
│   │   └── ClaudeCLIPTYDataSource.swift        # 可选
│   ├── Codex/
│   │   ├── CodexOAuthUsageDataSource.swift
│   │   └── CodexCLIPTYDataSource.swift         # 可选
│   ├── GeminiCLI/
│   │   ├── GeminiQuotaDataSource.swift
│   │   └── GeminiOAuthClientExtractor.swift    # 类似 CodexBar
│   ├── Antigravity/
│   │   ├── AntigravityQuotaDataSource.swift
│   │   ├── AntigravityTokenRefresher.swift
│   │   └── AntigravityProjectCache.swift
│   └── Copilot/
│       ├── CopilotUsageDataSource.swift
│       ├── CopilotDeviceFlow.swift           # 类似 CodexBar
│       └── CopilotTokenStore.swift           # Keychain
└── Infrastructure/
    ├── HTTP/
    │   ├── HTTPClient.swift
    │   └── HTTPStubs.swift
    ├── CLI/
    │   ├── CLIRunner.swift
    │   └── PTYRunner.swift                   # 可选
    └── Serialization/
        ├── JSONDecoder+Defaults.swift
        └── Fixtures.swift
```

> 注意：此目录结构是“非兼容重构”，不需要保留当前 `Flux/Core/Services/QuotaFetchers/*`。

---

## 5. 通用机制设计

### 5.1 Credential Inventory（统一凭证收集）

每个 provider 由一个或多个 `CredentialProvider` 提供凭证，按优先级组合：

- **主路径**：读取官方 CLI/Keychain/本地文件（不依赖 core）
- **可选导入**：用户可“导入”旧来源（例如 `~/.cli-proxy-api/*.json`）进 Flux 自己的 credentials store（一次性迁移工具，不作为依赖）

关键设计点：

- 统一 `accountKey` 规则：优先 `email`，否则使用稳定的 `accountId` 或 `filename/hash`。
- `expiresAt`/`isExpired` 统一计算。
- 统一 refresh：由 `CredentialProvider.refresh()` 或 `TokenRefresher` 完成，并尽量回写到来源（文件/Keychain）。

### 5.2 ProviderQuotaService（降级执行器）

借鉴 CodexBar 的 fetch plan + Management Center 的 config-driven loader：

```swift
struct ProviderFetchPlan {
  let provider: ProviderKind
  let fallback: FallbackBehavior  // stopOnFirst | tryAll | priorityChain
  let sources: [QuotaDataSource]  // already sorted by priority
}

protocol QuotaDataSource: Sendable {
  var source: QuotaSource { get }
  var priority: Int { get }
  func isAvailable(for credential: Credential) async -> Bool
  func fetch(for credential: Credential) async throws -> AccountQuotaReport
}
```

执行策略：

- `priorityChain`：按优先级逐个尝试，成功即返回；失败则根据错误类型决定是否继续降级（例如 authMissing 可能直接停止）。
- `tryAll`：并发执行多个 source，然后合并（例如同时拿到 OAuth usage + Web dashboard extras）。

### 5.3 QuotaEngine（缓存 + in-flight 去重 + backoff）

行为：

- `refreshAll()`：并发刷新所有 provider；每个 provider 并发刷新账号列表
- `refresh(provider:)`：刷新单 provider
- in-flight：同一 `(provider, accountKey, source)` 的请求复用一个 `Task`
- backoff：遇到 `rateLimited`/`forbidden` 时延长 provider 的最小刷新间隔
- 持久化：成功快照写 `quota-cache.json`，启动先加载并标记 stale

### 5.4 错误分级（UI 友好）

统一把错误映射为：

- `authMissing`：凭证缺失或 token 失效且不可刷新（提示用户登录/授权）
- `unsupported`：当前环境不支持（例如 CLI 未安装、cookie 未允许）
- `error`：网络/解析/上游异常
- `stale`：用缓存展示但已过期

---

## 6. Provider 详细实现策略（必须覆盖 5 个）

> 下面按“数据源/认证/API/解析/降级/刷新”给出可落地方案。每个 provider 至少提供一个 **不依赖 Core** 的主数据源；可选再补充 fallback。

### 6.1 Claude（Anthropic）

#### 数据源（优先级）
1. **OAuth API（主路径）**：`https://api.anthropic.com/api/oauth/usage`
2. **Web Cookie API（可选降级）**：`claude.ai/api/organizations/*`（参考 CodexBar）
3. **CLI PTY（可选降级）**：运行 `claude`，发送 `/usage` 并解析文本（参考 CodexBar）

#### 凭证来源（不依赖 core）
- **优先**：Keychain（Claude CLI 写入的 credentials）
- **fallback**：`~/.claude/.credentials.json`
- **（可选导入）**：导入旧的 `~/.cli-proxy-api/claude-*.json` 到 Flux credential store

#### API 与认证
- `GET https://api.anthropic.com/api/oauth/usage`
  - `Authorization: Bearer <access_token>`
  - `anthropic-beta: oauth-2025-04-20`
  - `Accept: application/json`

#### 解析（强类型）
定义 `ClaudeOAuthUsageResponse: Decodable`：
- `five_hour.utilization`, `five_hour.resets_at`
- `seven_day.*`
- `seven_day_sonnet.*`
- `seven_day_opus.*`
- `extra_usage.is_enabled / utilization / monthly_limit / used_credits`

映射到 windows：
- 5h、7d、Sonnet 7d、Opus 7d、Extra usage（如果 enabled）
  - `usedPercent = utilization`（0-100）
  - `remainingPercent = 100 - usedPercent`
  - `resetAt = ISO8601`

#### 降级策略
- OAuth API 返回 401/`authentication_error`：`authMissing`（停止降级或进入 Web/CLI，如果 credential provider 表示“可替代来源存在”）。
- 网络/解析错误：降级到 Web/CLI（如果用户启用 cookie 或 CLI 可用）。

#### Token refresh
- Claude OAuth token 通常不可 refresh（Quotio/ClaudeCodeQuotaFetcher 注释也强调这一点）。
- `CredentialProvider.refresh()` 对 Claude 返回 `.unsupportedRefresh`，UI 引导用户重新登录（Claude CLI 或 web）。

---

### 6.2 Codex（OpenAI / ChatGPT）

#### 数据源（优先级）
1. **OAuth API（主路径）**：`chatgpt.com/backend-api/wham/usage`
2. **Codex CLI（可选降级）**
   - RPC：如果实现成本可控（CodexBar 的 JSON-RPC）
   - PTY：跑 `codex`，发送 `/status` 解析（更易实现但更脆）
3. **Web dashboard（可选增强）**：`chatgpt.com/codex/settings/usage`（需要 cookie；若不想做可不实现）

#### 凭证来源（不依赖 core）
- **主路径**：`~/.codex/auth.json` 或 `$CODEX_HOME/auth.json`
  - access_token / refresh_token / id_token / last_refresh
- **（可选导入）**：导入 `~/.cli-proxy-api/codex-*.json` 到 Flux store

#### API 与认证
- `GET https://chatgpt.com/backend-api/wham/usage`
  - `Authorization: Bearer <access_token>`
  - `Accept: application/json`
  - 可选：`ChatGPT-Account-Id: <accountId>`（从 id_token claims 或 auth.json 字段）

#### 解析（强类型）
定义 `CodexUsageResponse: Decodable`：
- `plan_type`
- `rate_limit.primary_window.used_percent/reset_at/limit_window_seconds`
- `rate_limit.secondary_window.*`
- `code_review_rate_limit.primary_window.*`（如果存在）
- `credits.balance/has_credits/unlimited`（如果存在）

映射到 windows：
- 5h/session：primary_window
- weekly：secondary_window
- code review：code_review_rate_limit.primary_window
- credits：如果存在（unit=credits；同时生成一个 summary window）

#### 降级策略
- 401/403：尝试 refresh；refresh 失败 → `authMissing`，并可降级到 CLI PTY（如果用户已登录 codex CLI）
- 429：标记 rateLimited，延长 backoff（provider 级）
- 解析失败：视为 error，可降级到 CLI PTY

#### Token refresh（关键要求：统一 + 回写）
- `POST https://auth.openai.com/oauth/token`
  - `grant_type=refresh_token`
  - `refresh_token=<...>`
  - `client_id=<...>`（优先从 auth.json 或配置；缺失则用默认）
- refresh 成功后：
  - 更新内存 access_token
  - **回写 auth.json**（best-effort + chmod 600）
  - 更新 expiresAt（如果能得到）

> 这吸收了 CLIProxyAPI/Quotio 的“token refresh + persist”的思路，避免每次启动重复刷新。

---

### 6.3 GeminiCLI（Google Cloud Code / Gemini CLI OAuth）

#### 数据源（优先级）
1. **Cloud Code Quota API（主路径）**：`retrieveUserQuota`
2. **（可选）tier/plan detection**：`loadCodeAssist`（用于 UI 展示“Free/Paid/Workspace”，参考 CodexBar）
3. **（可选）项目发现**：Cloud Resource Manager projects API（参考 CodexBar）

#### 凭证来源（不依赖 core）
- `~/.gemini/oauth_creds.json`
  - `access_token`, `refresh_token`, `expiry_date`, `id_token`
- `~/.gemini/google_accounts.json`
  - account 字段内包含 projectId（Flux 现有逻辑：括号解析）

#### API 与认证
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Header：`Authorization: Bearer <access_token>`
  - Header：`Content-Type: application/json`
  - Body：`{"project":"<projectId>"}`（没有 projectId 时可尝试 `{}` 或先跑 project discovery）

#### 解析（强类型）
定义 `GeminiRetrieveUserQuotaResponse: Decodable`：
- `buckets[]`：`modelId`, `remainingFraction`, `remainingAmount`, `resetTime`, `tokenType`

聚合规则（沿用 Management Center / Flux 现有做法）：
- 以 `modelId` 分组
- 对每个 model 取 **最小 remainingFraction**（最保守）
- `resetAt` 取最早
- `remainingPercent = remainingFraction * 100`

#### 降级策略
- token 过期：先 refresh；refresh 失败 → `authMissing`
- API 返回 403/404：`authMissing` 或 `unsupported`（按错误文本/状态区分）

#### Token refresh（必须补齐）
参考 CodexBar 的“从 Gemini CLI 安装中提取 client_id/client_secret”：

- `POST https://oauth2.googleapis.com/token`
  - `grant_type=refresh_token`
  - `refresh_token=...`
  - `client_id/client_secret`：
    - 优先：从 Gemini CLI 安装目录（`oauth2.js`）提取
    - fallback：允许用户在 Flux 设置中手动填写（避免硬编码 secret）
- refresh 成功后回写 `~/.gemini/oauth_creds.json`（best-effort）

---

### 6.4 Antigravity（Google Cloud Code 私有 API，多端点 fallback）

> Antigravity 是最“敏感/复杂”的 provider：涉及 Google OAuth refresh、projectId 缓存、多 endpoint fallback。Flux 现有实现已经做到了“refresh + 回写 + project cache”，但凭证来源依赖 `~/.cli-proxy-api`。重构的关键是：**给它一个不依赖 core 的凭证来源**。

#### 数据源（优先级）
1. `fetchAvailableModels`（多 endpoint fallback）
2. `loadCodeAssist`（用于 projectId/tier 发现与 403 重试）

#### 凭证来源（不依赖 core）：三选一（都可实现）

**方案 A（推荐，最像 CodexBar/Quotio）：从 Antigravity 本地数据提取 refresh_token**
- 读取 Antigravity app/extension 的本地存储（sqlite/protobuf/leveldb，具体以 Antigravity 实际实现为准）
- 提取 refresh_token 或可换取 access_token 的凭证
- 用 Google OAuth token endpoint 刷新成 access_token

**方案 B（可落地、实现成本低）：Flux 自己做一次 OAuth 登录并保存 refresh_token**
- 在 Flux 内实现 Google OAuth 安装应用流程（PKCE + loopback redirect 或 device flow）
- scope 至少包含 Cloud Code 需要的权限
- 把 refresh_token 保存到 `~/.config/flux/credentials/antigravity/*.json`（chmod 600）

**方案 C（迁移工具）：一次性导入旧 auth files**
- 仅用于迁移：读取 `~/.cli-proxy-api/antigravity-*.json` 导入 Flux store
- 不作为运行时依赖（文件不存在也不影响）

> 方案 A/B 满足“不依赖 core”，方案 C 作为迁移辅助。

#### API 与认证

- `POST https://{daily-}cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
  - Header：
    - `Authorization: Bearer <access_token>`
    - `Content-Type: application/json`
    - `User-Agent: antigravity/<version> <os/arch>`（参考 Flux 现有实现）
  - Body：与现有实现一致（包含 project 等）
- `POST https://{...}/v1internal:loadCodeAssist`
  - 用于拿 project/tier，并在 403 时刷新 projectId 再重试

#### 解析（强类型）
沿用 Flux 现有强类型 decoder（已经存在 `FetchAvailableModelsResponse` / `LoadCodeAssistResponse`）：
- 从 `models.*.quotaInfo.remainingFraction/resetTime` 映射为 windows（按模型分组/再分组展示）
- 生成 summary：选择最差 remainingFraction 作为 provider 风险指标

#### 降级策略（保留现有优秀逻辑）
- endpoint fallback：按 URL 列表轮询（Management Center 同款）
- 401：触发 refresh（若有 refresh_token），然后 retry 一次
- 403 + 使用 cached projectId：跑 `loadCodeAssist` 刷 projectId 后 retry 一次
- 429：rateLimited，provider backoff

#### Token refresh（保留并统一）
- `POST https://oauth2.googleapis.com/token`（form）
  - 使用 client_id/client_secret（来源取决于 A/B）
- refresh 成功后：
  - 回写 Flux store credential（或本地 Antigravity 数据可写则写回）
  - 更新 expiresAt

---

### 6.5 Copilot（GitHub Copilot internal）

#### 数据源（优先级）
1. **GitHub OAuth device flow（主路径）**：参考 CodexBar
2. **GitHub CLI token（可选降级）**：如果用户安装并登录 `gh`

> Copilot 目前 Flux 的 quota fetch 依赖 `~/.cli-proxy-api` token 文件；重构后必须改为独立来源（device flow 或 gh token），以满足“不依赖 core”。

#### 凭证来源（不依赖 core）
- **主路径**：Device flow 获取 GitHub OAuth token，存 Keychain（service: `com.flux.*`）
  - scope：至少 `read:user`（CodexBar 的做法）
- **降级**：`gh auth token`（或 `gh auth status` + token 获取）
- **可选导入**：导入旧 `~/.cli-proxy-api/github-copilot-*.json`（迁移工具）

#### API 与认证
- `GET https://api.github.com/copilot_internal/user`
  - Header：
    - `Authorization: token <github_oauth_token>` 或 `Bearer`（以实际响应为准；建议兼容两种）
    - `Accept: application/json` 或 `application/vnd.github+json`
    - `X-GitHub-Api-Version`：建议使用较新的固定值（CodexBar 使用 `2025-04-01`，Flux 现有是 `2022-11-28`）
    - 可选：模拟 editor header（CodexBar 会带 Editor-Version/Plugin-Version/User-Agent；有助于稳定）

#### 解析（强类型）
定义 `CopilotEntitlementResponse: Decodable`：
- `quota_snapshots`（preferred：premium_interactions/chat/completions）
  - 支持两种形态：
    - `remaining` + `entitlement`（绝对值）
    - `percent_remaining`（百分比）
- reset date 字段：`quota_reset_date_utc` / `quota_reset_date` / `limited_user_reset_date`

输出：
- summary window：优先 premium_interactions → chat → completions
- unit：requests（如果有 entitlement/remaining），否则 credits（百分比）

#### 降级策略
- 401/403：token 失效 → 尝试刷新/重新 device flow（视 credential provider 能力）
- 429：provider backoff

---

## 7. 统一刷新策略（跨 Provider）

### 7.1 并发与限流

- Provider 级并发：`withTaskGroup` 并发账号拉取（类似现有 QuotaAggregator）
- Account 级限流：对同 provider 的并发请求设置上限（避免 GitHub/Anthropic 瞬时 429）
- Backoff：遇到 `rateLimited` 时提高 provider 的最小刷新间隔（指数退避，参考 Management Center 的“API 层已有 60 秒超时/限流提示”）

### 7.2 缓存与 UI 体验

- 启动即显示：加载 `quota-cache.json`（stale 标记）
- 手动刷新：强制忽略 interval，但仍遵守 in-flight 去重
- 错误提示：沿用当前 UI 的 ok/authMissing/unsupported/error，但由 `QuotaStatus` 驱动

---

## 8. 测试策略（必须覆盖解析 + refresh + fallback）

### 8.1 单元测试（Fixtures）

每个 provider 至少提供：

- `ParsingTests`：对响应 JSON fixture 做 decode + mapping → windows
- `ErrorMappingTests`：401/403/429/500 映射为 QuotaStatus 的规则

建议 fixtures 路径：

```
Flux/QuotaKitTests/Fixtures/
├── claude-oauth-usage.json
├── codex-wham-usage.json
├── gemini-retrieveUserQuota.json
├── antigravity-fetchAvailableModels.json
├── antigravity-loadCodeAssist.json
└── copilot-entitlement.json
```

### 8.2 Token refresh 测试

- Codex refresh：mock `oauth/token` 响应，验证 auth.json 回写逻辑（权限、字段更新）
- Gemini refresh：mock `oauth2.googleapis.com/token`，验证 oauth_creds.json 回写
- Antigravity refresh：mock token endpoint + retry 逻辑（401 → refresh → retry 成功）

### 8.3 Fallback 与调度测试

- `priorityChain`：source1 失败 → source2 成功；确保只返回成功 source 的 report
- endpoint fallback（Antigravity）：URL1 失败 → URL2 成功
- in-flight 去重：同 key 触发两次 refresh，只发一次 HTTP 请求（使用 stub 计数）

### 8.4 可选集成测试（离线录制）

可以提供一个 Debug 工具把真实响应保存成 fixture（不提交 token）：

- 只保存结构化响应，脱敏 token/email
- 用于回归测试，类似 CodexBar 的测试方式

---

## 9. 迁移路径（非兼容，但要可落地）

> 不考虑向后兼容不等于“一步删除全部”；建议用分支式迁移，让功能不断档。

### Phase 0：准备（不改 UI）
1. 新增 `Flux/QuotaKit/` 目录与基础 Domain/Infrastructure（HTTP/Logging 注入）
2. 提供 `QuotaEngine.refreshAll()` 与 `QuotaCacheStore`

### Phase 1：Codex 迁移（最大收益/最清晰）
1. 实现 `CodexAuthJSONProvider`（读 `~/.codex/auth.json`）
2. 实现 `CodexOAuthUsageDataSource`（强类型解析 + refresh + 回写）
3. 写 fixtures 测试

### Phase 2：Claude / GeminiCLI / Copilot 迁移
- Claude：Keychain/credentials.json + OAuth usage
- GeminiCLI：oauth_creds + refresh + quota API
- Copilot：device flow + entitlement API（并提供 gh token 降级）

### Phase 3：Antigravity 迁移（选择 A/B/C）
1. 先落地方案 B（Flux 自己存 refresh_token）或方案 C（导入旧文件）确保可用
2. 再评估是否实现方案 A（从 Antigravity 本地数据提取）
3. 移植并保留现有 Antigravity 的 endpoint fallback + project cache + retry 逻辑（这是现有代码的亮点）

### Phase 4：切换 UI 与移除旧实现
1. 用 `QuotaEngine` 替换 `QuotaAggregator` 在 UI/Dashboard 的依赖
2. 删除旧目录：
   - `Flux/Core/Services/QuotaAggregator.swift`
   - `Flux/Core/Services/QuotaRefreshScheduler.swift`
   - `Flux/Core/Services/QuotaFetchers/*`
   - `Flux/Core/Services/CLIProxyAuthScanner.swift`（可保留为“导入器”但不作为运行时依赖）

---

## 10. 关键取舍（明确写出来）

1. **不依赖 Core** 的代价：部分 provider（尤其 Antigravity/Copilot）必须在 Flux 内实现登录/凭证存储，而不是“等 Core 帮你生成 auth files”。
2. **强类型 + 测试** 是长期成本，但能显著降低上游字段变化带来的崩坏风险（CodexBar 经验证有效）。
3. **可选导入旧文件** 是现实迁移手段，但必须定位为“一次性迁移”，不能成为运行时必需路径（否则仍然依赖 core）。

---

## 11. 建议的最小可行落地（MVP）

若要尽快交付“完整覆盖 5 个 provider”的可用版本，建议 MVP 优先实现：

- Codex：`~/.codex/auth.json` + OAuth usage + refresh 回写
- Claude：Keychain/credentials.json + OAuth usage（不做 web/CLI fallback）
- GeminiCLI：oauth_creds + refresh + retrieveUserQuota
- Antigravity：先做“导入旧文件到 Flux store”（方案 C）或“手动粘贴 refresh_token”（方案 B）
- Copilot：device flow + entitlement

后续再按需补充：

- Claude web cookie / CLI PTY
- Codex CLI PTY/RPC、Web dashboard extras
- Antigravity 本地数据提取（方案 A）

