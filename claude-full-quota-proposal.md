# Claude 的完整额度查询重构方案

> 覆盖所有 Provider：Claude / Codex / GeminiCLI / Antigravity / Copilot

## 一、设计原则

### 借鉴的优秀思路
- CodexBar: 多数据源分层降级、Provider 探针模式、强类型解析
- Quotio: 独立运行（不依赖代理）、并发刷新、UI 聚合
- CLIProxyAPI: Token 刷新回写、可选服务端代呼
- Management Center: Config-driven loader、统一状态模型

### 核心约束
1. 完全脱离 Core：不依赖 ~/.cli-proxy-api
2. 多源降级：OAuth API → Web Cookie → CLI PTY
3. Token 刷新回写：刷新成功后回写 auth file
4. 强类型解析：用 Decodable 替代 JSONSerialization
5. 单一调度入口：去掉双层节流

## 二、统一架构

### 分层架构
- QuotaCoordinator: 调度、缓存、降级策略、in-flight 去重
- ProviderQuotaService: 每个 Provider 一个实例，包含多个 DataSource
- CredentialManager: 统一管理 Token/Cookie/API Key

### 核心协议
- QuotaDataSource: 数据源协议
- Credential: 凭证协议
- CredentialProvider: 凭证提供者协议

## 三、各 Provider 详细实现

### Claude
- 凭证: ~/.claude/.credentials.json, Keychain, CLI PTY
- API: GET https://api.anthropic.com/api/oauth/usage
- 窗口: five_hour, seven_day, seven_day_sonnet, seven_day_opus, extra_usage

### Codex
- 凭证: ~/.codex/auth.json, Codex CLI RPC
- API: GET https://chatgpt.com/backend-api/wham/usage
- Token 刷新: POST https://auth.openai.com/oauth/token (刷新后回写)
- 窗口: primary_window, secondary_window, code_review

### GeminiCLI
- 凭证: ~/.gemini/oauth_creds.json + google_accounts.json
- API: POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota
- Token 刷新: POST https://oauth2.googleapis.com/token (刷新后回写)

### Antigravity
- 多端点 fallback
- ProjectId 缓存 (7天 TTL)
- 401 触发 refresh + 重试, 403 触发 projectId 刷新 + 重试

### Copilot
- 凭证: GitHub Device Flow, gh auth token
- API: GET https://api.github.com/copilot_internal/user

## 四、目录结构

Flux/QuotaKit/
├── Domain/Models/ (QuotaReport, QuotaWindow...)
├── Engine/ (QuotaCoordinator, QuotaCacheStore...)
├── Credential/ (CredentialManager, TokenRefresher...)
├── Providers/ (Claude/, Codex/, GeminiCLI/, Antigravity/, Copilot/)
├── Infrastructure/ (HTTPClient, PTYSession...)
└── Config/ (ProviderQuotaConfig...)

## 五、迁移路径

- Phase 1: 基础架构 + Claude/Codex (3-5天)
- Phase 2: GeminiCLI + Antigravity (2-3天)
- Phase 3: Copilot + 清理 (2天)
- Phase 4: 扩展 (可选)

## 六、关键改进

- 依赖 ~/.cli-proxy-api → 直接读取官方凭证
- Codex/Gemini refresh 不回写 → 刷新后回写
- Copilot 依赖 Core → GitHub Device Flow
- 弱类型解析 → Decodable 强类型
- 双层节流 → 单一 QuotaCoordinator
- 无 in-flight 去重 → InFlightDeduplicator
- 无持久化缓存 → QuotaCacheStore
