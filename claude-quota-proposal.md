# Claude 的额度查询重构方案

> 基于 quotio/CodexBar/CLIProxyAPI/Management-Center 的优秀实践，重新设计 Flux 的额度查询系统

## 一、当前实现分析

### 现有架构
```
QuotaRefreshScheduler (定时调度)
         ↓
   QuotaAggregator (聚合器)
         ↓
   QuotaFetcher (各 Provider 实现)
         ↓
   CLIProxyAuthScanner (认证文件扫描)
```

### 痛点
1. **紧耦合**：Fetcher 与 AuthScanner 紧密耦合，难以支持多数据源
2. **扩展性差**：新增 Provider 需修改多处代码
3. **数据源单一**：仅支持 OAuth auth files，不支持 Cookie/CLI/IDE 数据库等
4. **无降级策略**：一种方式失败后无法自动尝试其他方式
5. **Token 刷新分散**：每个 Fetcher 各自实现刷新逻辑

---

## 二、设计思路（汲取优秀项目经验）

### 借鉴 CodexBar 的多数据源策略
- OAuth API 优先
- Web Cookie 接口降级
- CLI 驱动（PTY/RPC）作为备选
- 本地文件/数据库扫描

### 借鉴 quotio 的插件化架构
- Provider 配置声明式
- Fetcher 可热插拔
- 统一的认证抽象层

### 借鉴 CLIProxyAPI 的 Token 管理
- 集中式 Token Refresh
- \$TOKEN\$ 占位符替换
- 多账号路由

---

## 三、新架构设计

### 3.1 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│                     QuotaCoordinator                        │
│            (调度、缓存、通知、降级策略)                       │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                    ProviderQuotaService                     │
│              (每个 Provider 一个实例)                        │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐         │
│  │ DataSource 1 │ │ DataSource 2 │ │ DataSource N │         │
│  │  (OAuth API) │ │ (Web Cookie) │ │  (CLI/PTY)   │         │
│  └──────────────┘ └──────────────┘ └──────────────┘         │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                  CredentialManager                          │
│        (统一管理 Token/Cookie/API Key/CLI Auth)             │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌──────────┐  │
│  │ FileStore  │ │  Keychain  │ │CookieStore │ │ CLIAuth  │  │
│  └────────────┘ └────────────┘ └────────────┘ └──────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 核心协议定义

```swift
// MARK: - 数据源协议
protocol QuotaDataSource: Sendable {
    var sourceID: String { get }
    var priority: Int { get }
    func isAvailable() async -> Bool
    func fetchQuota(credential: Credential) async throws -> ProviderQuotaResult
}

// MARK: - 凭证协议
protocol Credential: Sendable {
    var accountKey: String { get }
    var email: String? { get }
    var expiresAt: Date? { get }
    var isExpired: Bool { get }
}

// MARK: - 凭证提供者
protocol CredentialProvider: Sendable {
    var providerID: ProviderID { get }
    var sourceType: CredentialSourceType { get }
    func listCredentials() async -> [any Credential]
    func refresh(credential: any Credential) async throws -> any Credential
}

enum CredentialSourceType: String, Sendable {
    case oauthFile      // ~/.claude/auth.json
    case cookieStore    // 浏览器 Cookie
    case keychain       // macOS Keychain
    case cliAuth        // gh auth status
    case ideDatabase    // Cursor state.vscdb
    case cliProxy       // CLIProxyAPI auth files
}
```

### 3.3 Provider 配置（声明式）

```swift
struct ProviderQuotaConfig: Sendable {
    let providerID: ProviderID
    let dataSources: [DataSourceConfig]
    let refreshStrategy: RefreshStrategy
    let fallbackBehavior: FallbackBehavior
}

enum FallbackBehavior: Sendable {
    case stopOnFirst    // 第一个成功即停止
    case tryAll         // 尝试所有，合并结果
    case priorityChain  // 按优先级链式降级
}
```

### 3.4 内置 Provider 配置示例

```swift
extension ProviderQuotaConfig {
    static let claude = ProviderQuotaConfig(
        providerID: .claude,
        dataSources: [
            // 优先：OAuth API
            DataSourceConfig(sourceType: .oauthAPI, priority: 1, ...),
            // 降级：Web API（需 Cookie）
            DataSourceConfig(sourceType: .webAPI, priority: 2, ...),
            // 备选：CLI PTY
            DataSourceConfig(sourceType: .cliPTY, priority: 3, ...)
        ],
        refreshStrategy: .exponentialBackoff(base: 60, max: 300),
        fallbackBehavior: .priorityChain
    )
}
```

---

## 四、目录结构

```
Flux/Quota/
├── Coordinator/
│   ├── QuotaCoordinator.swift
│   └── QuotaRefreshScheduler.swift
├── Config/
│   ├── ProviderQuotaConfig.swift
│   └── BuiltinConfigs.swift
├── Credential/
│   ├── CredentialManager.swift
│   └── Providers/
│       ├── OAuthFileCredentialProvider.swift
│       ├── KeychainCredentialProvider.swift
│       ├── CookieCredentialProvider.swift
│       ├── CLIAuthCredentialProvider.swift
│       └── IDEDatabaseCredentialProvider.swift
├── DataSource/
│   ├── QuotaDataSource.swift
│   └── Sources/
│       ├── OAuthAPIDataSource.swift
│       ├── WebAPIDataSource.swift
│       ├── CLIRPCDataSource.swift
│       └── CLIPTYDataSource.swift
└── Models/
    ├── ProviderQuotaResult.swift
    ├── AccountQuota.swift
    └── QuotaMetrics.swift
```

---

## 五、关键优势

| 特性 | 现有实现 | 新方案 |
|------|----------|--------|
| 数据源类型 | 仅 OAuth API | OAuth + Cookie + CLI + IDE |
| 扩展性 | 需修改多处代码 | 声明式配置 |
| 降级策略 | 无 | 自动降级链 |
| Token 刷新 | 分散在各 Fetcher | 集中管理 |
| 新 Provider | 新增 Fetcher 类 | 添加配置即可 |
| 测试性 | 难以 Mock | 协议驱动，易于测试 |

---

## 六、与 Core 的解耦

本方案**完全不依赖 Core**：
- 不使用 CLIProxyAPI 的 Management API
- 不依赖 Core 进程状态
- 直接读取本地认证文件/Cookie/数据库
- 直接调用第三方 API

这与 CodexBar 的设计理念一致：作为独立的额度监控器运行，无需启动任何代理服务。

