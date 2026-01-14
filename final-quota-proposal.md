# Flux 最终版额度查询重构方案（Final）

> 覆盖 Provider：Claude / Codex / GeminiCLI / Antigravity / Copilot  
> 整合来源：`codex-full-quota-proposal.md`（细致落地与迁移）+ `claude-full-quota-proposal.md`（清晰协议与声明式配置）  
> 关键目标：**不依赖 Core/CLIProxyAPI**、多数据源降级、统一 Token 管理、强类型解析、可测试、渐进迁移、MVP 可快速落地。

---

## 0) 统一命名与模块边界（解决冲突点）

- 模块名：统一为 **`FluxQuotaKit`**
- 核心调度器：统一命名为 **`QuotaEngine`**（actor，唯一刷新入口）
- 定时器：`QuotaScheduler`（薄包装，可选）
- Provider 执行器：`ProviderQuotaService`（按 config 执行 sources chain）
- 凭证编目：`CredentialInventory`（聚合多个 `CredentialProvider`）

> 约定：文档中不再出现 `QuotaCoordinator`（避免混淆）。

---

## 1) 现状摘要（为何必须重构）

Flux 当前 quota 链路（`QuotaRefreshScheduler` → `QuotaAggregator` → `QuotaFetchers` → `CLIProxyAuthScanner`）存在根本问题：

- 主路径依赖 `~/.cli-proxy-api`（Core/CLIProxyAPI 产物），与“不依赖 Core”冲突
- Token refresh 行为不一致（Codex 不回写、GeminiCLI 不 refresh、Antigravity refresh+回写）
- 解析多为弱类型（`JSONSerialization`），缺 fixture 测试与字段变体兼容
- scheduler + aggregator 双层节流，行为不透明

重构必须把 Flux 变成像 CodexBar/Quotio 那样的 **standalone quota monitor**：Core 运行与否不影响额度监控。

---

## 2) 总体架构设计（含架构图）

### 2.1 逻辑架构图

```
┌───────────────────────────────────────────────────────────────────┐
│                         QuotaEngine (actor)                        │
│  - refreshAll / refresh(provider) / refresh(account)               │
│  - cache + persist + stale semantics                               │
│  - in-flight 去重（按 provider/account/source）                     │
│  - per-provider backoff（429/5xx/网络失败）                          │
└───────────────────────────────────────────────────────────────────┘
                    ↓                          ↓
┌───────────────────────────────┐   ┌──────────────────────────────┐
│        CredentialInventory      │   │       ProviderRegistry       │
│  - list(provider) credentials   │   │  - ProviderQuotaService[]    │
│  - unify identity/accountKey    │   │  - ProviderQuotaConfig        │
└───────────────────────────────┘   └──────────────────────────────┘
                    ↓                          ↓
┌───────────────────────────────────────────────────────────────────┐
│                     ProviderQuotaService (per provider)            │
│  - 根据 ProviderQuotaConfig 按优先级执行多个 QuotaDataSource           │
│  - fallbackBehavior：priorityChain / stopOnFirstSuccess / tryAllMerge│
└───────────────────────────────────────────────────────────────────┘
                    ↓
┌───────────────────────────────────────────────────────────────────┐
│                 CredentialProviders + Infrastructure                │
│  File/Keychain/CLI/Cookie/DeviceFlow + HTTPClient + CLIRunner/PTY   │
└───────────────────────────────────────────────────────────────────┘
```

### 2.2 行为要点（落地约束）

- **单一刷新入口**：所有 UI 刷新、定时刷新都调用 `QuotaEngine`，移除旧的 Aggregator/Scheduler 双层节流
- **不依赖 Core**：运行时不读取 `~/.cli-proxy-api`；该目录只允许作为“迁移导入源”（用户显式触发）
- **强类型解析**：所有第三方响应使用 `Decodable`（可容忍字段别名与缺失）
- **Token refresh 回写**：仅对“可 refresh 的 provider”执行；回写采用原子写 + `chmod 600`
- **降级链**：每 provider 明确 sources 优先级与停止条件（authMissing 是否继续、rateLimited 是否 backoff）

---

## 3) 统一数据模型（Swift 代码）

> 这是 UI/Dashboard/菜单栏的唯一数据入口；避免当前 `QuotaMetrics` 的 percent/absolute 混用语义。

```swift
import Foundation

public enum ProviderKind: String, CaseIterable, Sendable, Codable {
    case claude
    case codex
    case geminiCLI
    case antigravity
    case copilot
}

public enum QuotaUnit: String, Sendable, Codable {
    case requests
    case tokens
    case credits
    case percent // 仅当上游只给百分比时使用；优先用 credits/requests 等
}

public enum QuotaStatus: String, Sendable, Codable {
    case ok
    case authMissing
    case unsupported
    case error
    case stale
    case loading
}

public enum QuotaSource: String, Sendable, Codable {
    case oauthApi
    case webCookieApi
    case cliPty
    case cliRpc
    case localAppData
    case importedFile // 迁移导入后的 Flux 自有凭证
}

public struct QuotaWindow: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var unit: QuotaUnit

    // 统一展示字段：二选一或同时存在（优先 absolute）
    public var usedPercent: Double?
    public var remainingPercent: Double?
    public var used: Int?
    public var limit: Int?
    public var remaining: Int?

    public var resetAt: Date?

    public init(
        id: String,
        label: String,
        unit: QuotaUnit,
        usedPercent: Double? = nil,
        remainingPercent: Double? = nil,
        used: Int? = nil,
        limit: Int? = nil,
        remaining: Int? = nil,
        resetAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.unit = unit
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

public struct AccountQuotaReport: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(provider.rawValue)::\(accountKey)" }

    public var provider: ProviderKind
    public var accountKey: String
    public var email: String?
    public var plan: String?

    public var status: QuotaStatus
    public var source: QuotaSource
    public var fetchedAt: Date

    public var windows: [QuotaWindow]
    public var errorMessage: String?
}

public struct ProviderSummary: Sendable, Codable, Hashable {
    public var displayTitle: String
    public var primaryWindow: QuotaWindow?
    public var secondaryWindow: QuotaWindow?

    // Dashboard 风险计算统一用 0..1：越接近 0 越危险
    public var worstRemainingRatio: Double?
}

public struct ProviderQuotaReport: Sendable, Codable, Hashable, Identifiable {
    public var id: ProviderKind { provider }

    public var provider: ProviderKind
    public var fetchedAt: Date
    public var accounts: [AccountQuotaReport]
    public var summary: ProviderSummary?
}

public struct QuotaReport: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var providers: [ProviderQuotaReport]
}
```

---

## 4) 核心协议与声明式配置（Swift 代码）

> 取 Claude 方案优势：协议清晰 + config-driven；并对接我的方案：Engine/Inventory/ProviderFetchPlan。

```swift
import Foundation

// MARK: - Credential primitives

public enum CredentialSourceType: String, Sendable, Codable {
    case fileStore      // Flux 自己的 credentials dir（主推荐）
    case keychain       // macOS Keychain
    case cookieStore    // 浏览器 cookie（可选）
    case cliAuth        // 通过 CLI 取 token（如 gh auth token）
    case officialFile   // 官方 CLI 的 auth 文件（~/.codex/auth.json, ~/.gemini/oauth_creds.json 等）
    case localAppData   // 读取某 App 本地存储（Antigravity 方案A）
    case importLegacy   // 仅迁移：~/.cli-proxy-api（非运行时依赖）
}

public protocol Credential: Sendable {
    var provider: ProviderKind { get }
    var sourceType: CredentialSourceType { get }

    var accountKey: String { get }
    var email: String? { get }

    var accessToken: String { get }
    var refreshToken: String? { get }
    var expiresAt: Date? { get }
    var isExpired: Bool { get }

    // 仅当来源是文件（officialFile/fileStore/importLegacy）时提供
    var filePath: String? { get }
    // Provider-specific extras（如 Codex accountId）
    var metadata: [String: String] { get }
}

public protocol CredentialProvider: Sendable {
    var provider: ProviderKind { get }
    var sourceType: CredentialSourceType { get }

    func listCredentials() async -> [any Credential]

    // 不一定都支持 refresh；不支持时抛出明确错误
    func refresh(_ credential: any Credential) async throws -> any Credential

    // 回写/持久化（Keychain 或文件）；仅当来源支持时实现
    func persist(_ credential: any Credential) async throws
}

// MARK: - Data sources

public protocol QuotaDataSource: Sendable {
    var provider: ProviderKind { get }
    var source: QuotaSource { get }
    var priority: Int { get }

    func isAvailable(for credential: any Credential) async -> Bool
    func fetchQuota(for credential: any Credential) async throws -> AccountQuotaReport
}

// MARK: - Config driven execution

public enum FallbackBehavior: Sendable, Codable {
    case stopOnFirstSuccess
    case priorityChain
    case tryAllMerge
}

public enum RefreshStrategy: Sendable, Codable {
    case fixed(intervalSeconds: Int)
    case exponentialBackoff(baseSeconds: Int, maxSeconds: Int)
    case adaptive(minSeconds: Int, maxSeconds: Int)
}

public struct DataSourceConfig: Sendable, Codable, Hashable {
    public var source: QuotaSource
    public var priority: Int
}

public struct ProviderQuotaConfig: Sendable, Codable {
    public var provider: ProviderKind
    public var credentialSources: [CredentialSourceType]
    public var dataSources: [DataSourceConfig]
    public var refreshStrategy: RefreshStrategy
    public var fallbackBehavior: FallbackBehavior
}
```

### 内置配置示例（简洁、可读）

```swift
public enum BuiltinQuotaConfigs {
    public static let codex = ProviderQuotaConfig(
        provider: .codex,
        credentialSources: [.officialFile, .fileStore],
        dataSources: [
            .init(source: .oauthApi, priority: 1),
            .init(source: .cliPty, priority: 2),
        ],
        refreshStrategy: .exponentialBackoff(baseSeconds: 60, maxSeconds: 300),
        fallbackBehavior: .priorityChain
    )
}
```

---

## 5) 5 个 Provider 详细实现策略（数据源/认证/API/解析/降级）

> 统一输出为 `AccountQuotaReport.windows[]`；同时计算 `ProviderSummary` 供 Dashboard。

### 5.1 Claude（Anthropic）

**数据源优先级**
1. OAuth API（`QuotaSource.oauthApi`）
2. Web Cookie API（`QuotaSource.webCookieApi`，可选）
3. CLI PTY（`QuotaSource.cliPty`，可选）

**凭证来源（不依赖 Core）**
- `CredentialSourceType.keychain`：Claude CLI 写入的 Keychain credentials（优先）
- `CredentialSourceType.officialFile`：`~/.claude/.credentials.json`（fallback）
- `CredentialSourceType.fileStore`：用户导入或 Flux 自建凭证（可选）

**API**
- `GET https://api.anthropic.com/api/oauth/usage`
  - `Authorization: Bearer <access_token>`
  - `anthropic-beta: oauth-2025-04-20`
  - `Accept: application/json`

**解析（Decodable）**
- buckets：`five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`
- extra：`extra_usage`（enabled + utilization）
- 映射规则：utilization 是 used%，`remaining = 100 - utilization`，`resets_at` ISO8601

**降级与停止条件**
- 401/`authentication_error`：`authMissing`（通常不可 refresh）
  - 若存在 cookie/CLI source 且用户启用，可继续降级；否则停止并提示重新登录
- 429：进入 provider backoff
- 解析失败/网络错误：可继续尝试 Web/CLI

**Token refresh**
- 默认不支持 refresh（CodexBar/Quotio 实践：Claude OAuth token 多为短期，不可 refresh）
- `CredentialProvider.refresh()` 明确抛出 `.unsupportedRefresh`，UI 引导用户重新登录（Claude CLI / Web）

---

### 5.2 Codex（OpenAI / ChatGPT）

**数据源优先级**
1. OAuth API：`GET https://chatgpt.com/backend-api/wham/usage`
2. CLI PTY 或 RPC（可选；PTY `/status` 最易实现）
3. Web dashboard extras（可选 tryAllMerge，不作为 MVP 必需）

**凭证来源**
- `officialFile`：`~/.codex/auth.json` 或 `$CODEX_HOME/auth.json`（主路径）
- `fileStore`：Flux 自己存储（导入/多账号管理）

**API**
- `GET https://chatgpt.com/backend-api/wham/usage`
  - `Authorization: Bearer <access_token>`
  - `Accept: application/json`
  - 可选：`ChatGPT-Account-Id: <accountId>`（从 id_token claims 或 metadata）

**Token refresh（必须实现 + 回写）**
- `POST https://auth.openai.com/oauth/token`
  - body：`grant_type=refresh_token&refresh_token=...&client_id=...`
- refresh 成功后：
  - 更新内存 access_token
  - 回写 auth.json（原子写 + chmod 600）

**解析**
- windows：
  - `rate_limit.primary_window` → session/5h
  - `rate_limit.secondary_window` → weekly
  - `code_review_rate_limit.primary_window` → code review（可选字段）
  - `credits`（若存在）→ credits window（可选）

**降级策略**
- 401/403：尝试 refresh；refresh 失败 → `authMissing`，可降级到 CLI（若可用）
- 429：provider backoff
- parse/network：可降级到 CLI

---

### 5.3 GeminiCLI（Google Cloud Code）

**数据源**
1. Cloud Code quota API（`retrieveUserQuota`）
2. Tier detection（`loadCodeAssist`，可选）
3. Project discovery（Cloud Resource Manager，选配）

**凭证来源**
- `officialFile`：`~/.gemini/oauth_creds.json`（access_token/refresh_token/expiry_date/id_token）

**API**
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - `Authorization: Bearer <access_token>`
  - body：`{"project":"<projectId>"}`（projectId 通过 `~/.gemini/google_accounts.json` 或 discovery）

**Token refresh（必须补齐 + 回写）**
- `POST https://oauth2.googleapis.com/token`
  - `grant_type=refresh_token&refresh_token=...&client_id=...&client_secret=...`
- client_id/secret 获取策略（借鉴 CodexBar，避免硬编码）：
  1) 从 Gemini CLI 安装目录的 `oauth2.js` 提取（推荐）
  2) 失败时允许用户在 Flux 设置中配置
- refresh 成功回写 `oauth_creds.json`（原子写 + chmod 600）

**解析**
- `buckets[]`：`modelId/remainingFraction/resetTime/remainingAmount/tokenType`
- 规则：
  - 按 `modelId` 分组取最小 remainingFraction（最保守）
  - resetAt 取最早
  - 生成 windows：每个 model 一条（或按组聚合，MVP 可先“每 model 一条”）

**降级**
- 过期：refresh；失败 → `authMissing`
- 403/404：`authMissing` 或 `unsupported`（按错误体/状态映射）
- 429：provider backoff

---

### 5.4 Antigravity（Google Cloud Code 私有 API，多端点 fallback）

**数据源**
1. `fetchAvailableModels`（多端点 fallback）
2. `loadCodeAssist`（project/tier 发现；403 重试）

**凭证来源（必须不依赖 Core）：三方案并存**

- 方案 A（长期最佳）：从 Antigravity 本地存储提取 refresh_token（sqlite/protobuf/leveldb 视实际而定）
- 方案 B（MVP 推荐）：Flux 内实现一次 OAuth（PKCE + loopback 或 device flow）并保存 refresh_token 到 `FluxQuotaKit` 的 `fileStore`
- 方案 C（仅迁移）：导入 `~/.cli-proxy-api/antigravity-*.json` 到 `fileStore`（一次性工具，非运行时依赖）

**API**
- `POST https://{daily-}cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://{...}/v1internal:loadCodeAssist`
- Header：
  - `Authorization: Bearer <access_token>`
  - `Content-Type: application/json`
  - `User-Agent: antigravity/<version> <os/arch>`

**Token refresh（必须 + 回写）**
- `POST https://oauth2.googleapis.com/token`（form-urlencoded）
  - client_id/secret 来源：
    - 方案 B：Flux 内部 OAuth client（配置化）
    - 方案 C：从导入文件读（若有），否则走 Flux 配置
- refresh 成功写回 `fileStore` 的凭证文件（chmod 600）

**projectId 缓存与重试（保留现有优秀逻辑）**
- project cache：7 天 TTL（key=accountKey）
- 401：refresh + retry once
- 403 且使用了 cached projectId：触发 `loadCodeAssist` 刷 projectId 后 retry once
- endpoint fallback：按 URL 列表顺序尝试直到成功

**解析**
- `models.{modelId}.quotaInfo.remainingFraction/resetTime`
- 生成 windows：按 model 分组；可再映射到 UI 组（MVP 可先只输出 model list）
- summary：最小 remainingFraction → worstRemainingRatio

---

### 5.5 Copilot（GitHub Copilot internal）

**数据源**
1. GitHub Device Flow（主路径，存 Keychain）
2. `gh auth token`（降级，用户已登录 gh CLI 时）

**凭证来源**
- `cliAuth`：通过 `gh auth token` 获取（不需要刷新逻辑）
- `keychain`：device flow 保存 token
- `importLegacy`：仅迁移 `~/.cli-proxy-api/github-copilot-*.json` → `fileStore`

**API**
- `GET https://api.github.com/copilot_internal/user`
  - `Authorization: token <token>` 与 `Bearer <token>` 两种都兼容（实际以 GitHub 接口为准）
  - `Accept: application/vnd.github+json`
  - `X-GitHub-Api-Version: <固定版本>`
  - （推荐）补齐 editor header（CodexBar 经验：更稳）

**解析**
- `quota_snapshots`：优先 `premium_interactions` → `chat` → `completions`
- 支持两种形态：
  1) `remaining` + `entitlement`（绝对值，unit=requests）
  2) `percent_remaining`（百分比，unit=percent/credits）
- reset date：`quota_reset_date_utc` 等（容忍多 key）

**降级**
- token 失效（401/403）：device flow 重新授权或重新获取 gh token
- 429：backoff

---

## 6) 完整目录结构（最终定版）

```
Flux/FluxQuotaKit/
├── Domain/
│   ├── ProviderKind.swift
│   ├── QuotaModels.swift
│   ├── QuotaErrors.swift
│   └── QuotaConfigModels.swift
├── Engine/
│   ├── QuotaEngine.swift
│   ├── QuotaScheduler.swift
│   ├── QuotaCacheStore.swift
│   └── InFlightDeduplicator.swift
├── Credentials/
│   ├── Credential.swift
│   ├── CredentialProvider.swift
│   ├── CredentialInventory.swift
│   ├── Stores/
│   │   ├── FileCredentialStore.swift
│   │   ├── KeychainCredentialStore.swift
│   │   └── CookieStore.swift
│   └── Providers/
│       ├── ClaudeCredentialProvider.swift
│       ├── CodexCredentialProvider.swift
│       ├── GeminiCLICredentialProvider.swift
│       ├── AntigravityCredentialProvider.swift
│       └── CopilotCredentialProvider.swift
├── Providers/
│   ├── ProviderQuotaService.swift
│   ├── Claude/
│   │   ├── ClaudeOAuthUsageDataSource.swift
│   │   ├── ClaudeWebUsageDataSource.swift
│   │   └── ClaudeCLIPTYDataSource.swift
│   ├── Codex/
│   │   ├── CodexOAuthUsageDataSource.swift
│   │   ├── CodexCLIPTYDataSource.swift
│   │   └── CodexTokenRefresher.swift
│   ├── GeminiCLI/
│   │   ├── GeminiQuotaDataSource.swift
│   │   ├── GeminiOAuthTokenRefresher.swift
│   │   └── GeminiOAuthClientExtractor.swift
│   ├── Antigravity/
│   │   ├── AntigravityQuotaDataSource.swift
│   │   ├── AntigravityTokenRefresher.swift
│   │   └── AntigravityProjectCache.swift
│   └── Copilot/
│       ├── CopilotUsageDataSource.swift
│       ├── CopilotDeviceFlow.swift
│       └── CopilotTokenStore.swift
├── Infrastructure/
│   ├── HTTP/
│   │   ├── HTTPClient.swift
│   │   └── HTTPStubs.swift
│   ├── CLI/
│   │   ├── CLIRunner.swift
│   │   └── PTYRunner.swift
│   └── Serialization/
│       ├── JSONDecoder+Defaults.swift
│       └── Fixtures.swift
└── Config/
    ├── BuiltinQuotaConfigs.swift
    └── ProviderQuotaConfig.swift
```

> 说明：`Flux/FluxQuotaKit/` 是目录名；如果采用 SwiftPM，可把模块名也叫 `FluxQuotaKit`。

---

## 7) 测试策略（完整、可执行）

### 7.1 单元测试（Parsing fixtures）

为每个 provider 提供 fixtures（至少 3 类）：

1. 正常响应（typical）
2. 字段变体/缺失（missing/alias）
3. 错误响应（401/403/429/500）

建议 fixtures：

```
Flux/FluxQuotaKitTests/Fixtures/
├── claude-oauth-usage-typical.json
├── claude-oauth-usage-auth_error.json
├── codex-wham-usage-typical.json
├── codex-wham-usage-missing_fields.json
├── gemini-retrieveUserQuota-typical.json
├── antigravity-fetchAvailableModels-typical.json
├── antigravity-loadCodeAssist-typical.json
└── copilot-entitlement-typical.json
```

### 7.2 Token refresh + 回写测试（必须）

- Codex：mock `/oauth/token` 返回，验证：
  - access_token 更新
  - auth.json 原子写
  - 文件权限 600
- GeminiCLI：mock google token endpoint，验证 oauth_creds.json 回写与 expiry 更新
- Antigravity：401 → refresh → retry 成功（一次重试），并验证 project cache 行为

### 7.3 Fallback / in-flight / backoff 行为测试（必须）

- `priorityChain`：source1 失败 → source2 成功
- endpoint fallback（Antigravity）：URL1 fail → URL2 ok
- in-flight 去重：同 key 触发两次 refresh → 只发一次 HTTP
- backoff：429 后 provider 刷新间隔提升，且在 backoff 窗口内不再发请求

### 7.4 集成测试（建议）

- 使用 `HTTPStubs` + `CredentialProviders` stub，验证 `QuotaEngine.refreshAll()` 输出的 `QuotaReport` 与 `ProviderSummary`

### 7.5 E2E（可选，不做 CI 强制）

- 本地手动跑，避免把真实 token 放进 CI
- 提供 Debug “导出脱敏响应为 fixture”的工具，便于回归

---

## 8) 迁移路径（分 Phase，渐进落地）

> 不考虑向后兼容 ≠ 一次性大爆破；采用“新系统并行 + UI 逐步切换”的方式，降低风险。

### Phase 0：脚手架（1-2 天）
- 建立 `FluxQuotaKit` 目录/模块
- 实现 Domain 模型 + `QuotaEngine` 最小骨架（无 provider）
- 实现 `QuotaCacheStore`（读写 `~/.config/flux/quota-cache.json`）

### Phase 1：Codex（2-3 天，先验证 refresh 回写 + Engine）
- 实现 `CodexCredentialProvider`（读 `~/.codex/auth.json`）
- 实现 `CodexOAuthUsageDataSource`（Decodable + 401 refresh + 回写）
- 接入 UI：Quota 页面先显示 Codex provider 的新数据（其余仍旧系统）

### Phase 2：Copilot（2-3 天，验证 device flow + Keychain）
- 实现 `CopilotDeviceFlow` + `CopilotTokenStore`（Keychain）
- 实现 `CopilotUsageDataSource`（header 兼容 + quota_snapshots 映射）
- 接入 UI：Copilot 迁移到新系统

### Phase 3：Claude + GeminiCLI（2-4 天）
- Claude：Keychain/credentials.json provider + OAuth usage
- GeminiCLI：oauth_creds + refresh（oauth2.js 提取策略）+ retrieveUserQuota
- UI 完全切到新系统（Dashboard 风险计算改用 ProviderSummary）

### Phase 4：Antigravity（3-6 天，分方案落地）
- MVP 推荐：先实现方案 B（Flux 内 OAuth 存 refresh_token 到 fileStore）
- 保留现有优秀逻辑：endpoint fallback / 401 refresh retry / 403 projectId refresh retry / project cache
- 最后再做方案 A（从 Antigravity 本地数据提取）作为增强

### Phase 5：删除旧系统（1 天）
- 移除：
  - `Flux/Core/Services/QuotaAggregator.swift`
  - `Flux/Core/Services/QuotaRefreshScheduler.swift`
  - `Flux/Core/Services/QuotaFetchers/*`
  - `Flux/Core/Services/CLIProxyAuthScanner.swift`（可保留为 Importer 工具，但不参与 runtime）

---

## 9) MVP 建议（最快可交付且满足“不依赖 Core”）

**MVP 目标：5 个 provider 都能在没有 Core 的情况下产出可用 quota**，允许部分 provider 暂不实现高成本 fallback（Web/CLI）。

建议 MVP 范围：

- Codex：`~/.codex/auth.json` + OAuth usage + refresh 回写（必须）
- Copilot：device flow + entitlement（必须）
- Claude：Keychain/`~/.claude/.credentials.json` + OAuth usage（不做 web/CLI fallback）
- GeminiCLI：oauth_creds + refresh + retrieveUserQuota（必须）
- Antigravity：先做方案 B（Flux 内 OAuth）或提供“导入旧文件→写入 Flux fileStore”（迁移工具），并完成 fetchAvailableModels fallback

MVP 明确不做：

- Codex Web dashboard extras
- Claude Web Cookie API / CLI PTY
- Gemini project discovery（可先只依赖 google_accounts.json 提取）
- Antigravity 本地数据提取（方案 A）

---

## 10) 可选：Core 加速路径（不形成依赖）

保留接口但默认不用：

```swift
public protocol QuotaBackend: Sendable {
    func perform(request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct DirectBackend: QuotaBackend { /* URLSession */ }

public struct ManagementBackend: QuotaBackend {
    // 可选：仅当 Core 运行时通过 /v0/management/api-call 代呼
    // 目的：统一代理出口、token 替换、特定 provider refresh（类似 CLIProxyAPI）
}
```

验收标准：`DirectBackend` 单独运行必须覆盖 MVP 的 5 provider，不允许因 Core 缺失而失效。

---

## 11) 可选模块 - CLIProxy Auth 实时监控（`~/.cli-proxy-api`）

> 定位：**可选增强（enhancement）**，用于“实时感知旧生态（CLIProxyAPI/Core）写入的 auth files”，并把它们作为 **低优先级凭证来源** 自动加入 `CredentialInventory`。  
> 原则：即使该模块不可用/无权限/目录不存在，**官方来源与 Flux 自有 fileStore 仍可完整工作**，不形成依赖。

### 11.1 监控模块设计（FileWatcher）

#### 目标
- 实时监控 `~/.cli-proxy-api` 目录的新增/修改/删除
- 在变更发生时触发一次“增量扫描”，输出：
  - 新增文件列表（added）
  - 删除文件列表（removed）
  - 变更文件列表（modified）

#### 建议实现（macOS）

优先使用 **DispatchSource**（轻量、易集成）：

- 打开目录 FD：`open(path, O_EVTONLY)`（或 `O_RDONLY`）
- 建立 `DispatchSourceFileSystemObject`：
  - eventMask：`.write`, `.delete`, `.rename`, `.attrib`, `.extend`, `.link`, `.revoke`
- 收到事件后做 debounce（例如 150~300ms）再触发扫描，避免一连串写入导致重复解析

备选：**FSEvents**（目录事件更强，但引入更多复杂度；当需要跨层级或高频时再上）。

#### API 形态（示例）

```swift
public protocol FileWatcher: Sendable {
    func start() throws
    func stop()
}

public final class CLIProxyAuthDirWatcher: FileWatcher {
    public struct Event: Sendable {
        public var added: [URL]
        public var removed: [URL]
        public var modified: [URL]
    }

    public var onEvent: (@Sendable (Event) -> Void)?
}
```

扫描策略：
- 仅关心 `*.json` 文件
- 文件内容解析失败不阻塞整个 batch（单文件错误记录为 warning）
- 用 `fileURL` + `mtime` + `size` 作为快速判定（减少读文件次数）

### 11.2 与 CredentialInventory 的集成

#### 集成方式（推荐：新增一个可热插拔 CredentialProvider）

新增 `CredentialProvider`：
- `provider`: `.claude/.codex/.geminiCLI/.antigravity/.copilot`（按文件名或 JSON 字段识别）
- `sourceType`: `.importLegacy`（明确表示它来自“旧生态监控来源”）

运行方式：
1. `CredentialInventory` 启动时：
   - 若用户开启“Enable CLIProxy auth monitoring”，则创建 watcher 并启动
   - 先做一次全量 scan（得到初始 credentials）
2. watcher 收到事件后：
   - 触发增量 scan
   - 更新 `CredentialInventory` 的内部 snapshot（增删改）
   - 通知 `QuotaEngine` 进行一次“轻量 refresh”（例如只刷新受影响 provider/account）

建议加一个轻量事件总线（in-process）：
- `CredentialInventory` 发布：`credentialsDidChange(provider: ProviderKind, accountKeys: Set<String>)`
- `QuotaEngine` 订阅后触发：`refresh(provider:)` 或 `refreshAll(force: false)`（按变更范围决定）

> 这样监控模块只负责“发现变化 + 更新凭证列表”，不会把 quota fetch 与文件系统事件强耦合。

### 11.3 凭证优先级（官方来源 > 监控来源）

必须把优先级写成规则，避免 “旧文件覆盖官方凭证”：

1. **官方来源（officialFile/keychain/cliAuth）优先**
   - Claude：Keychain / `~/.claude/.credentials.json`
   - Codex：`~/.codex/auth.json`
   - GeminiCLI：`~/.gemini/oauth_creds.json`
   - Copilot：device flow(Keychain) / `gh auth token`
2. **Flux 自有 fileStore（importedFile）次之**
   - 用户显式导入/登录后保存的凭证
3. **CLIProxy 监控来源（importLegacy）最低**
   - 仅作为“自动拾取旧生态文件”的补充

落地机制：
- `CredentialInventory` 在合并多来源 credentials 时，按 `CredentialSourceType` 排序，遇到同一 `(provider, accountKey)` 时选择最高优先级的 credential
- 同时保留“候选列表”供 Debug（可选），但默认不在 UI 混显，避免用户困惑

### 11.4 权限处理（不阻塞主功能）

#### 非沙盒（多数开发期/自签）
- 访问 `~/.cli-proxy-api` 通常不需要额外权限

#### App Sandbox（若启用）
- 直接读取 `~/.cli-proxy-api` 可能受限；建议策略：
  1) 默认关闭监控模块（feature flag）
  2) 用户在设置里点击 “Enable CLIProxy auth monitoring” 时：
     - 弹出说明（为何需要访问目录、仅用于读取 auth files）
     - 通过 `NSOpenPanel` 让用户选择 `~/.cli-proxy-api` 目录并获取 security-scoped bookmark
     - 保存 bookmark 到 `fileStore` 配置，后续 `startAccessingSecurityScopedResource()` 后再监听
  3) 授权失败/撤销时：
     - watcher 停止
     - 记录状态为 `.unsupported`（仅对监控模块），但 quota 系统其余来源继续工作

#### 失败策略（必须）
- 目录不存在：静默禁用（不报错，只在 Debug logs 记录）
- 监听 FD 被 revoke：停止 watcher + 提示用户重新授权（不影响其他来源）
