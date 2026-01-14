# Flux 最终版额度查询重构方案 V2（GUI for CLIProxyAPI）

> 覆盖 Provider：Claude / Codex / GeminiCLI / Antigravity / Copilot  
> 目标：Flux 作为 **CLIProxyAPI 的 GUI**，把 `~/.cli-proxy-api` 视为**主凭证来源**，同时做到 **不依赖 Core 进程运行**（但依赖 Core/CLIProxyAPI 生成的 auth files 是合理的）。  
> 整合来源：`codex-full-quota-proposal.md`（落地细节）+ Claude 方案（协议清晰、声明式配置、简洁示例）+ 评审结论（命名统一、优先级统一）。

---

## 0) 统一命名与模块边界（解决冲突点）

- 模块名：统一为 **`FluxQuotaKit`**
- 核心调度器：统一命名为 **`QuotaEngine`**（actor，唯一刷新入口）
- 定时器：`QuotaScheduler`（薄包装，可选）
- Provider 执行器：`ProviderQuotaService`（按 config 执行 sources chain）
- 凭证编目：`CredentialInventory`（聚合多个 `CredentialProvider`）
- CLIProxy 主凭证扫描器：保留并复用 **`CLIProxyAuthScanner`**（Flux 现有实现），升级为 `FluxQuotaKit` 的核心输入之一
- CLIProxy 目录实时监控：**核心功能**（非可选增强）

> V2 约定：文档中不再使用 `QuotaCoordinator` 这个名字；统一用 `QuotaEngine`。

---

## 1) V2 关键澄清：何谓“不依赖 Core”

V1 的“不依赖 Core/CLIProxyAPI”被调整为：

- **不依赖 Core 进程运行**：即使 Core 不在运行（或 CLIProxyAPI 没启动），Flux 仍能基于本地已有凭证文件查询 quota。
- **依赖 Core 生成的 auth files 是合理的**：`~/.cli-proxy-api` 是 Flux 的主凭证目录（Flux 是 GUI），因此：
  - `~/.cli-proxy-api` 读取与实时监控是核心功能
  - 官方 CLI auth files（如 `~/.codex/auth.json`）是补充来源，用于填补 `~/.cli-proxy-api` 不存在或缺 provider 的场景

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
│  - merge + priority selection   │   │  - DataSource chain           │
└───────────────────────────────┘   └──────────────────────────────┘
                    ↓
┌───────────────────────────────────────────────────────────────────┐
│              CredentialProviders (按优先级合并)                      │
│  1) CLIProxyAuth (scanner + watcher)  ← 主来源                       │
│  2) Official CLI files                ← 补充来源                      │
│  3) Keychain / Device Flow / gh token  ← 最后兜底                      │
└───────────────────────────────────────────────────────────────────┘
                    ↓
┌───────────────────────────────────────────────────────────────────┐
│                 Infrastructure: HTTPClient / CLIRunner / PTY        │
└───────────────────────────────────────────────────────────────────┘
```

### 2.2 行为要点（落地约束）

- **单一刷新入口**：UI 手动刷新、后台定时刷新都调用 `QuotaEngine`；移除旧的 “Aggregator + Scheduler 双层节流”
- **主凭证目录**：运行时默认扫描并监控 `~/.cli-proxy-api`
- **补充来源**：当 `~/.cli-proxy-api` 缺失某 provider 或无有效 token 时，才使用官方 CLI files / keychain / device flow
- **强类型解析**：所有第三方响应使用 `Decodable`（容忍字段别名/缺失）
- **token refresh 回写**：对可 refresh 的 provider（Codex/GeminiCLI/Antigravity）执行，并回写到“该凭证来源”（优先回写 `~/.cli-proxy-api`）

---

## 3) 统一数据模型定义（Swift 代码）

> UI/Dashboard/菜单栏以此为唯一数据入口。

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
    case percent
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

public struct ProviderSummary: Sendable, Codable, Hashable {
    public var displayTitle: String
    public var primaryWindow: QuotaWindow?
    public var secondaryWindow: QuotaWindow?
    public var worstRemainingRatio: Double? // 0..1
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

## 4) 核心协议 + 声明式配置（Swift 代码）

> 取 Claude 方案优势（协议/配置清晰），并让 `~/.cli-proxy-api` 成为第一优先来源。

```swift
import Foundation

public enum CredentialSourceType: String, Sendable, Codable {
    case cliProxyAuthDir // ~/.cli-proxy-api (主来源)
    case officialFile    // ~/.codex/auth.json, ~/.gemini/oauth_creds.json, ~/.claude/.credentials.json
    case keychain        // macOS Keychain（补充）
    case cliAuth         // gh auth token 等（补充）
    case cookieStore     // 浏览器 cookie（可选）
    case fileStore       // Flux 自己的 credentials dir（可选：导入、备份、多账号）
    case localAppData    // App 本地数据（Antigravity 方案A）
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

    // 文件来源（cliProxyAuthDir/officialFile/fileStore）可提供
    var filePath: String? { get }
    // provider-specific extras（如 Codex ChatGPT-Account-Id）
    var metadata: [String: String] { get }
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
    var priority: Int { get }

    func isAvailable(for credential: any Credential) async -> Bool
    func fetchQuota(for credential: any Credential) async throws -> AccountQuotaReport
}

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
    public var credentialSources: [CredentialSourceType]  // 按优先级排列
    public var dataSources: [DataSourceConfig]            // 按 priority 排序
    public var refreshStrategy: RefreshStrategy
    public var fallbackBehavior: FallbackBehavior
}
```

### 内置配置示例（体现优先级调整）

```swift
public enum BuiltinQuotaConfigs {
    public static let codex = ProviderQuotaConfig(
        provider: .codex,
        credentialSources: [.cliProxyAuthDir, .officialFile, .fileStore],
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

## 5) 凭证优先级（V2 核心调整）

**全局规则**（必须在 `CredentialInventory` 层实现并可测试）：

1. `~/.cli-proxy-api`（`cliProxyAuthDir`）——**主来源**
2. 官方 CLI auth files（`officialFile`）——补充来源
3. `keychain` / `cliAuth` / device flow（可实现为 `cliAuth`+`keychain`）——最后兜底
4. （可选）`fileStore` ——用于导入/备份/多账号管理，不必高于 `~/.cli-proxy-api`

合并策略：

- 对同一 `(provider, accountKey)`，选择优先级最高的 credential
- 允许保留“候选集”用于 Debug，但默认 UI 不混显

---

## 6) 5 个 的详细实现策略（按 V2 优先级）

### 6.1 Claude（Anthropic）

**Credential 优先级**

1. `~/.cli-proxy-api/claude-*.json`（主）
2. `~/.claude/.credentials.json` / Keychain（补）
3. CLI PTY（可选，仅在 OAuth 不可用时）

**API**

- `GET https://api.anthropic.com/api/oauth/usage`
  - `Authorization: Bearer <access_token>`
  - `anthropic-beta: oauth-2025-04-20`

**解析**

- buckets：`five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`
- extra：`extra_usage`（enabled + utilization）

**refresh**

- 默认不支持 refresh（失败 → 引导重新登录获取新 auth file；或降级到 CLI/Web）

**降级**

- 401/auth error：若存在 officialFile/keychain 凭证可用，则切换 credential source 再试；否则 authMissing

### 6.2 Codex（OpenAI / ChatGPT）

**Credential 优先级**

1. `~/.cli-proxy-api/codex-*.json`（主）
2. `~/.codex/auth.json`（补）
3. fileStore（可选）

**API**

- `GET https://chatgpt.com/backend-api/wham/usage`
  - `Authorization: Bearer <access_token>`
  - 可选：`ChatGPT-Account-Id`（从 `id_token` claims 或文件 metadata）

**refresh + 回写**

- `POST https://auth.openai.com/oauth/token`
- 刷新成功后回写到“当前 credential 来源文件”（优先回写 `~/.cli-proxy-api/codex-*.json`；若来源为 `~/.codex/auth.json` 则回写该文件）

### 6.3 GeminiCLI（Cloud Code）

**Credential 优先级**

1. `~/.cli-proxy-api/gemini-cli-*.json`（主；需要 scanner 支持识别 gemini-cli）
2. `~/.gemini/oauth_creds.json`（补）

**API**

- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - `Authorization: Bearer <access_token>`
  - body：`{"project":"<projectId>"}`

**refresh**

- Google OAuth refresh（`oauth2.googleapis.com/token`），并回写到来源文件
- 若来源是 `~/.cli-proxy-api`：client_id/secret 由 CLIProxy 文件携带或 Flux 配置提供；无法获取则标记 authMissing 并降级到 officialFile（若存在）

### 6.4 Antigravity（Cloud Code 多端点）

**Credential 优先级**

1. `~/.cli-proxy-api/antigravity-*.json`（主）
2. localAppData / fileStore（补充增强）

**API**

- `fetchAvailableModels` 多端点 fallback
- `loadCodeAssist` project/tier 发现

**refresh + 回写**

- 401 → refresh → retry once
- refresh 使用 oauth2 token endpoint，成功后回写 `~/.cli-proxy-api` auth file（chmod 600）

**project cache**

- 7 天 TTL，403 且使用 cached pid → loadCodeAssist 刷新 pid → retry once

### 6.5 Copilot（GitHub Copilot internal）

**Credential 优先级**

1. `~/.cli-proxy-api/github-copilot-*.json`（主）
2. `gh auth token`（补）
3. device flow（最后兜底；token 存 Keychain）

**API**

- `GET https://api.github.com/copilot_internal/user`
  - `Authorization: token <token>` 或 `Bearer <token>`（兼容）
  - `Accept: application/vnd.github+json`

**解析**

- `quota_snapshots`（premium_interactions/chat/completions）
- 兼容 `remaining+entitlement` 或 `percent_remaining`

---

## 7) 目录结构（V2：CLIProxy 监控成为核心）

```
Flux/FluxQuotaKit/
├── Credentials/
│   ├── CLIProxyAuth/
│   │   ├── CLIProxyAuthScannerAdapter.swift   # 复用现有 CLIProxyAuthScanner
│   │   ├── CLIProxyAuthDirWatcher.swift       # DispatchSource/FSEvents 核心监听
│   │   └── CLIProxyAuthCredentialProvider.swift
│   ├── Official/
│   │   ├── CodexAuthJSONProvider.swift
│   │   ├── GeminiOAuthCredsProvider.swift
│   │   └── ClaudeCredentialsProvider.swift
│   └── ...
└── ...
```

> 说明：保留旧 `CLIProxyAuthScanner`（在现有代码位置也可），但 `FluxQuotaKit` 内提供 adapter，使其成为标准 `CredentialProvider`。

---

## 8) 测试策略（V2 补充 watcher/scanner 测试）

在 V1 测试清单基础上新增：

- **CLIProxyAuthScannerAdapterTests**
  - 文件名/字段识别：claude/codex/antigravity/copilot/gemini-cli
  - 过期字段解析（expires_at/expired/expiry_date 等变体）
- **CLIProxyAuthDirWatcherTests**
  - 创建/删除/修改文件触发事件
  - debounce 生效（多次写入只触发一次 scan）
  - revoke/rename 处理
- **CredentialInventoryMergePriorityTests**
  - 同 `(provider, accountKey)` 下，确保 `cliProxyAuthDir` 覆盖 `officialFile/keychain`

---

## 9) 迁移路径（V2：以 CLIProxy 为主线）

### Phase 0（先把主线打通）

1. 在 `FluxQuotaKit` 内实现 `CLIProxyAuthCredentialProvider`（复用现有 scanner）
2. 实现 `CLIProxyAuthDirWatcher`（核心监听）
3. `CredentialInventory` 默认只接入 CLIProxy provider（即可覆盖大多数用户场景）

### Phase 1（引入 Official 兜底）

1. Codex/Gemini/Claude 的 officialFile providers
2. `CredentialInventory` 合并优先级：cliProxyAuthDir > officialFile > keychain/cliAuth

### Phase 2（迁移 quota fetch 到新 Engine）

1. 逐个 provider 把现有 fetcher 迁移为 `QuotaDataSource`（Decodable + backoff + in-flight）
2. UI/Dashboard 改读 `QuotaReport`

### Phase 3（移除旧调度）

1. 移除旧 `QuotaAggregator`/旧 scheduler
2. 保留旧 scanner 实现（但由 adapter 使用）

---

## 10) MVP 建议（V2）

最短可交付 MVP：

1. CLIProxyAuthDir 的 scan + watcher（核心）
2. 5 provider 的 OAuth API quota fetch（直接对第三方调用，不要求 Core 进程运行）
3. refresh 回写优先写回 `~/.cli-proxy-api`（Codex/GeminiCLI/Antigravity）
4. officialFile 作为兜底：当 `~/.cli-proxy-api` 没有对应 provider 文件时启用

---

## 11) 核心模块 - `~/.cli-proxy-api` 实时监控（从可选变为必需）

### 11.1 FileWatcher 设计（DispatchSource / FSEvents）

优先使用 `DispatchSourceFileSystemObject`：

- 监听目录 FD（`O_EVTONLY`）
- event mask：`.write/.delete/.rename/.attrib/...`
- debounce 150~300ms 后触发增量扫描

### 11.2 与 CredentialInventory 集成

- watcher 触发 → `CLIProxyAuthCredentialProvider` 重新 scan（增量/全量皆可）→ 更新 `CredentialInventory` snapshot
- `CredentialInventory` 发布 `credentialsDidChange(provider: ProviderKind, accountKeys: Set<String>)`
- `QuotaEngine` 接到事件后触发：
  - `refresh(provider:)`（推荐）或 `refreshAll(force: false)`（保守）

### 11.3 凭证优先级（再次强调）

- `~/.cli-proxy-api` 必须是第一优先级来源
- Official/keychain/device-flow 仅在 CLIProxy 缺失 provider 时启用

### 11.4 权限处理

- 非 sandbox：通常无需额外权限
- sandbox：需要用户选择目录获取 security-scoped bookmark（若 Flux 采用 sandbox）
  - 授权失败不阻塞主功能：可退化为“只在启动/手动刷新时 scan”（不做实时监听），但仍以 CLIProxy 目录为主来源
