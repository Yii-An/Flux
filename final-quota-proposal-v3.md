# Flux 最终版额度查询重构方案 V3（精简：Antigravity / Codex / Gemini CLI）

> 仅保留 Provider：**Antigravity / Codex / Gemini CLI**  
> Flux 定位：**CLIProxyAPI 的 GUI**，以 `~/.cli-proxy-api` 为**主凭证来源**；不依赖 Core 进程运行（但依赖 Core/CLIProxyAPI 写入的 auth files 是合理的）。  
> 不考虑向后兼容：允许直接替换旧 quota 体系与旧模型。

---

## 0) 统一命名与模块边界

- 模块名：`FluxQuotaKit`
- 核心调度器（唯一刷新入口）：`QuotaEngine`（`actor`）
- 定时器（薄包装，可选）：`QuotaScheduler`
- Provider 执行器：`ProviderQuotaService`（按声明式 config 执行 data-source chain）
- 凭证编目：`CredentialInventory`（聚合多个 `CredentialProvider`，按优先级合并）
- CLIProxy 主凭证扫描器：保留并复用 **`CLIProxyAuthScanner`**（Flux 现有实现），作为 `FluxQuotaKit` 的主输入
- CLIProxy 目录实时监控：**核心功能**（watch `~/.cli-proxy-api`，驱动 inventory 更新与 quota 刷新）

---

## 1) “不依赖 Core”的精确定义（V3）

- **不依赖 Core 进程运行**：即使 CLIProxyAPI/Core 未启动，Flux 仍能基于本地已有的 `~/.cli-proxy-api/*.json` 查询额度。
- **依赖 Core 生成的 auth files**：Flux 作为 GUI，`~/.cli-proxy-api` 是权威来源；官方 CLI auth files 仅作为补充（见第 5 节）。

---

## 2) 总体架构设计（含架构图）

```
┌───────────────────────────────────────────────────────────────────┐
│                         QuotaEngine (actor)                        │
│  - refreshAll / refresh(provider) / refresh(account)               │
│  - cache + stale semantics + persist                               │
│  - in-flight 去重（provider/account/source）                        │
│  - per-provider backoff（429/5xx/网络失败）                          │
└───────────────────────────────────────────────────────────────────┘
                    ↓                          ↓
┌───────────────────────────────┐   ┌──────────────────────────────┐
│        CredentialInventory      │   │       ProviderRegistry       │
│  - list(provider) credentials   │   │  - ProviderQuotaService[]    │
│  - merge + priority selection   │   │  - ProviderQuotaConfig        │
│  - publish didChange events     │   │  - DataSource chain           │
└───────────────────────────────┘   └──────────────────────────────┘
                    ↑
┌───────────────────────────────────────────────────────────────────┐
│        CLIProxyAuthDirWatcher (核心) + CLIProxyAuthScanner          │
│  - watch ~/.cli-proxy-api changes                                  │
│  - create/update/delete → rescan → update inventory                │
└───────────────────────────────────────────────────────────────────┘
                    ↓
┌───────────────────────────────────────────────────────────────────┐
│  CredentialProviders (按优先级合并)                                  │
│  1) cliProxyAuthDir  (~/.cli-proxy-api)  ← 主来源                   │
│  2) officialFile     (~/.codex/auth.json, ~/.gemini/oauth_creds.json)│
└───────────────────────────────────────────────────────────────────┘
                    ↓
┌───────────────────────────────────────────────────────────────────┐
│                 Infrastructure: HTTPClient / FileIO / Clock         │
└───────────────────────────────────────────────────────────────────┘
```

行为要点：
- 单一刷新入口：移除旧 “Aggregator + Scheduler 双层节流”，统一走 `QuotaEngine`
- 主凭证目录：默认扫描并实时监控 `~/.cli-proxy-api`
- 声明式配置：Provider 能力由 `ProviderQuotaConfig` 描述（credential priority + data source chain）
- refresh 回写：对可 refresh 的 provider 执行，并回写到“当前凭证来源文件”（优先 `~/.cli-proxy-api`）

---

## 3) 统一数据模型定义（Swift 代码）

```swift
import Foundation

public enum ProviderKind: String, CaseIterable, Sendable, Codable {
    case antigravity
    case codex
    case geminiCLI
}

public enum QuotaUnit: String, Sendable, Codable {
    case requests
    case tokens
    case credits
    case percent
}

public enum QuotaStatus: String, Sendable, Codable {
    case ok
    case authMissing
    case error
    case stale
    case loading
}

public enum QuotaSource: String, Sendable, Codable {
    case oauthApi
}

public struct QuotaWindow: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var unit: QuotaUnit
    public var usedPercent: Double?
    public var remainingPercent: Double?
    public var used: Int?
    public var limit: Int?
    public var remaining: Int?
    public var resetAt: Date?
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

public struct ProviderQuotaReport: Sendable, Codable, Hashable, Identifiable {
    public var id: ProviderKind { provider }
    public var provider: ProviderKind
    public var fetchedAt: Date
    public var accounts: [AccountQuotaReport]
}

public struct QuotaReport: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var providers: [ProviderQuotaReport]
}
```

---

## 4) 核心协议 + 声明式配置（Swift 代码）

```swift
import Foundation

public enum CredentialSourceType: String, Sendable, Codable {
    case cliProxyAuthDir // ~/.cli-proxy-api (主来源)
    case officialFile    // ~/.codex/auth.json, ~/.gemini/oauth_creds.json (补充)
}

public protocol Credential: Sendable {
    var provider: ProviderKind { get }
    var sourceType: CredentialSourceType { get }

    var accountKey: String { get }     // 去重 key（通常是 email / username / email+project）
    var email: String? { get }

    var accessToken: String { get }
    var refreshToken: String? { get }
    var expiresAt: Date? { get }
    var isExpired: Bool { get }

    var filePath: String? { get }      // 文件来源可提供
    var metadata: [String: String] { get } // provider-specific extras
}

public protocol CredentialProvider: Sendable {
    var provider: ProviderKind { get }
    var sourceType: CredentialSourceType { get }

    func listCredentials() async -> [any Credential]
    func refresh(_ credential: any Credential) async throws -> any Credential
    func persist(_ credential: any Credential) async throws
}

public protocol QuotaDataSource: Sendable {
    var provider: ProviderKind { get }
    var source: QuotaSource { get }

    func isAvailable(for credential: any Credential) async -> Bool
    func fetchQuota(for credential: any Credential) async throws -> AccountQuotaReport
}

public enum FallbackBehavior: Sendable, Codable {
    case priorityChain
    case stopOnFirstSuccess
}

public enum RefreshStrategy: Sendable, Codable {
    case exponentialBackoff(baseSeconds: Int, maxSeconds: Int)
}

public struct ProviderQuotaConfig: Sendable, Codable {
    public var provider: ProviderKind
    public var credentialSources: [CredentialSourceType] // 按优先级排列
    public var refreshStrategy: RefreshStrategy
    public var fallbackBehavior: FallbackBehavior
}
```

内置配置（体现 `~/.cli-proxy-api` 主优先级）：

```swift
public enum BuiltinQuotaConfigs {
    public static let codex = ProviderQuotaConfig(
        provider: .codex,
        credentialSources: [.cliProxyAuthDir, .officialFile],
        refreshStrategy: .exponentialBackoff(baseSeconds: 60, maxSeconds: 300),
        fallbackBehavior: .priorityChain
    )

    public static let geminiCLI = ProviderQuotaConfig(
        provider: .geminiCLI,
        credentialSources: [.cliProxyAuthDir, .officialFile],
        refreshStrategy: .exponentialBackoff(baseSeconds: 60, maxSeconds: 300),
        fallbackBehavior: .priorityChain
    )

    public static let antigravity = ProviderQuotaConfig(
        provider: .antigravity,
        credentialSources: [.cliProxyAuthDir],
        refreshStrategy: .exponentialBackoff(baseSeconds: 60, maxSeconds: 300),
        fallbackBehavior: .priorityChain
    )
}
```

---

## 5) 凭证来源与优先级（V3 核心约束）

全局规则（必须在 `CredentialInventory` 实现并可测试）：

1. `cliProxyAuthDir`：`~/.cli-proxy-api` —— **主来源**
2. `officialFile`：官方 CLI auth files —— **补充来源**
   - Codex：`~/.codex/auth.json`
   - Gemini CLI：`~/.gemini/oauth_creds.json`（以及 projectId 辅助文件 `~/.gemini/google_accounts.json`）

合并策略：
- 对同一 `(provider, accountKey)`，只选优先级最高的 credential 用于 quota 查询（避免 UI “重复账号”）
- 只有当 `~/.cli-proxy-api` 缺失该 provider 或没有可用 token 时，才启用 `officialFile`

关于 `CLIProxyAuthScanner`（保留为主扫描器）：
- V3 要求在 scanner 中新增 **Gemini CLI 的识别**（建议以 JSON `type` 字段为准，并兼容 gemini 文件名变体）

---

## 6) 3 个 Provider 的详细实现策略

> 目标：每个 Provider 都能在“仅凭本地 auth files、无需 Core 进程”条件下完成 quota 查询；对 refreshable provider 执行 refresh + 回写。

### 6.1 Codex

**主凭证来源（CLIProxy）**
- 文件：`~/.cli-proxy-api/codex-<email>.json`
- 关键字段：`access_token`, `refresh_token`, `account_id?`, `expired?`, `type=codex`

**补充来源（Official）**
- 文件：`~/.codex/auth.json`

**额度 API**
- `GET https://chatgpt.com/backend-api/wham/usage`
  - Header：`Authorization: Bearer <access_token>`
  - 可选 Header：`ChatGPT-Account-Id: <account_id>`（若凭证中存在）

**refresh + 回写**
- `POST https://auth.openai.com/oauth/token`
  - `grant_type=refresh_token`
  - `refresh_token=<refresh_token>`
  - `client_id=<按 CLIProxy 文件/配置提供>`
- 401/过期 → refresh → 仅重试一次
- 回写策略：回写到“来源文件”（优先 `~/.cli-proxy-api/codex-*.json`）

**解析与窗口**
- 以 `primary_window / secondary_window` 为主（5h/周等），输出为 `QuotaWindow[]`

### 6.2 Gemini CLI

**主凭证来源（CLIProxy）**
- 文件：`~/.cli-proxy-api/*.json`（Gemini 在不同入口可能有 `gemini-<email>-<project>.json` 或 `<email>-<project>.json` 的命名差异）
- 识别建议：以 `type` 字段为准（通常为 `gemini`），从 payload 中解析：
  - `email`
  - `project_id`
  - `token`（包含 access/refresh/expiry 等）

**补充来源（Official）**
- `~/.gemini/oauth_creds.json`（token）
- `~/.gemini/google_accounts.json`（projectId 解析/选择）

**额度 API**
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Header：`Authorization: Bearer <access_token>`
  - Body：`{"project":"<project_id>"}`

**refresh + 回写**
- `POST https://oauth2.googleapis.com/token`
  - `grant_type=refresh_token`
  - `refresh_token=<refresh_token>`
  - `client_id/client_secret`：优先从 CLIProxy 生成文件携带的元数据/配置获取；否则降级到 officialFile（若存在）
- 401/过期 → refresh → 仅重试一次
- 回写策略：写回“来源文件”（CLIProxy → `~/.cli-proxy-api/...json`；Official → `~/.gemini/oauth_creds.json`）

### 6.3 Antigravity

**主凭证来源（CLIProxy）**
- 文件：`~/.cli-proxy-api/antigravity-*.json` 或 `antigravity.json`
- 关键字段：`access_token`, `refresh_token`, `expires_in?`, `expired?`, `project_id?`, `type=antigravity`

**额度/能力端点（多端点 fallback）**
- 以 Cloud Code 的内部端点为主（保持现有 Antigravity 的多端点策略）：
  - `https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
  - `https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
  - `https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels`

**projectId 策略**
- 若 auth file 含 `project_id`：优先使用
- 若缺失：调用 `loadCodeAssist` 发现并缓存（建议 7 天 TTL）
- 403 且 projectId 为缓存值 → 触发 projectId 刷新（loadCodeAssist）→ 重试一次

**refresh + 回写**
- 401/过期 → Google OAuth refresh → 重试一次
- 回写：写回 `~/.cli-proxy-api` 对应文件（0600）

---

## 7) 精简目录结构（V3）

```
Flux/FluxQuotaKit/
├── Domain/
│   ├── ProviderKind.swift
│   ├── QuotaModels.swift              # QuotaReport/ProviderQuotaReport/AccountQuotaReport/QuotaWindow
│   └── Protocols.swift                # Credential/CredentialProvider/QuotaDataSource
├── Engine/
│   ├── QuotaEngine.swift
│   ├── QuotaScheduler.swift           # 可选
│   ├── QuotaCacheStore.swift
│   └── InFlightDeduplicator.swift
├── Credentials/
│   ├── CLIProxyAuth/
│   │   ├── CLIProxyAuthScannerAdapter.swift  # 复用现有 CLIProxyAuthScanner
│   │   ├── CLIProxyAuthDirWatcher.swift      # 核心：watch ~/.cli-proxy-api
│   │   └── CLIProxyCredentialModels.swift    # 解析到统一 Credential
│   └── Official/
│       ├── CodexOfficialCredentialProvider.swift
│       ├── GeminiOfficialCredentialProvider.swift
│       └── GeminiProjectResolver.swift
├── Providers/
│   ├── Codex/CodexQuotaDataSource.swift
│   ├── GeminiCLI/GeminiCLIQuotaDataSource.swift
│   └── Antigravity/AntigravityQuotaDataSource.swift
└── Infrastructure/
    ├── HTTPClient.swift
    ├── FileIO.swift
    └── Clock.swift
```

说明：
- 删除已移除 Provider 相关目录、providers、credential providers、测试 fixture
- 保留“watch + scan”作为核心能力（Flux GUI 的关键路径）

---

## 8) 测试策略（V3 精简）

必须覆盖：

1. **CLIProxyAuthScannerAdapterTests**
   - 识别与映射：Codex/Antigravity/Gemini（以 `type` 为主，文件名前缀为辅）
   - 过期字段解析：`expired/expires_at/expiry/expiry_date` 等
2. **CLIProxyAuthDirWatcherTests**
   - create/update/delete/rename 触发 inventory 更新
   - debounce 生效（避免频繁写入导致刷新风暴）
3. **CredentialInventoryMergePriorityTests**
   - `cliProxyAuthDir` 必须覆盖 `officialFile`
4. **Provider Parser / Fixture Tests（每个 Provider 至少 3 个）**
   - Codex：典型响应 / 缺字段 / auth error
   - Gemini：典型响应 / projectId 缺失 / auth error
   - Antigravity：多端点失败→成功 / 401 refresh / 403 projectId 刷新

---

## 9) 迁移路径（V3：缩短、以 CLIProxy 为主线）

### Phase 1（主路径先跑通：CLIProxy + 3 Provider）
1. 引入 `FluxQuotaKit` 的 `QuotaEngine` + `CredentialInventory`
2. 复用 `CLIProxyAuthScanner`，补齐 Gemini 识别，产出统一 `Credential`
3. 实现 `CLIProxyAuthDirWatcher`，目录变更自动触发刷新（provider/account 级别）
4. 实现 3 个 `QuotaDataSource`（Codex/GeminiCLI/Antigravity）直连第三方 API

### Phase 2（补充来源：Official files）
1. Codex：接入 `~/.codex/auth.json`（当 CLIProxy 缺失时启用）
2. Gemini：接入 `~/.gemini/oauth_creds.json` + project resolver（当 CLIProxy 缺失时启用）

### Phase 3（替换旧系统）
1. UI 全量切换到 `QuotaReport`
2. 删除旧 quota fetcher/aggregator/scheduler（仅保留当前 3 个 Provider 的实现）

---

## 10) MVP 建议（V3）

最短可交付（建议 3–5 天）：
- CLIProxy 主目录 scan + watcher（必须）
- 3 Provider 的 quota 查询（Codex/GeminiCLI/Antigravity）
- refresh + 回写（Codex/GeminiCLI/Antigravity）
- 仅在 CLIProxy 缺失时启用 official fallback（Codex/Gemini）
