# quotio（nguyenphutrong/quotio）额度查询实现分析

## 1) 项目概述和主要功能

Quotio 是一个 macOS 原生（Swift/SwiftUI）应用，定位为 **CLIProxyAPI**（本地代理服务）的“控制台/指挥中心”，核心能力包括：

- 多账号多服务商 OAuth/API Key 接入（统一管理认证文件、代理配置、路由策略等）
- **额度/配额（quota/limits/credits）可视化**：支持不启动代理的“Standalone Quota Mode”（监控模式）直接查看各账号额度
- 代理流量与用量监控（requests/tokens/success rate）、日志查看、通知告警、菜单栏快速状态
- 一键为多种 CLI/IDE Agent 写入配置，让它们通过 CLIProxyAPI 使用统一入口

从“额度查询”的角度，Quotio 主要做两件事：

1. **从本地/云端数据源拉取各类“订阅/窗口额度”**（例如 5h / weekly、credits、按模型 bucket 等），统一成可展示的数据结构。
2. **在 UI（Quota 页面 + 菜单栏）聚合展示**，并支持低额度提醒、自动选中/排序等。

## 2) 支持哪些 AI 服务商的额度查询

Quotio 的“可连接 Provider”很广（README 宣称 Gemini/Claude/Codex/Qwen/Vertex/iFlow/Antigravity/Kiro/Trae/Copilot 等），但**真正实现了“额度/配额拉取”逻辑的 provider 以代码为准**，主要集中在：

- **OpenAI Codex / ChatGPT（OAuth）**：拉取 `wham/usage`，得到 session/weekly/credits 等窗口信息  
  - 关键实现：`Quotio/Services/QuotaFetchers/OpenAIQuotaFetcher.swift`
  - 监控模式下还支持 **Codex CLI 本地 auth.json**：`Quotio/Services/QuotaFetchers/CodexCLIQuotaFetcher.swift`
- **Anthropic Claude（OAuth）**：拉取 OAuth usage（5h、7d、sonnet/opus、extra usage）  
  - 关键实现：`Quotio/Services/QuotaFetchers/ClaudeCodeQuotaFetcher.swift`
- **GitHub Copilot（OAuth）**：拉取 copilot_internal entitlement/配额快照（chat / completions 等）  
  - 关键实现：`Quotio/Services/QuotaFetchers/CopilotQuotaFetcher.swift`
- **Cursor（IDE）**：从 Cursor 的本地 SQLite（`state.vscdb`）拿 token/邮箱，并调用 Cursor API 获取 usage-summary  
  - 关键实现：`Quotio/Services/QuotaFetchers/CursorQuotaFetcher.swift`
- **Trae（IDE）**：从 Trae 本地 `storage.json` 取 JWT，调用 Trae entitlement API 取各套餐额度与用量  
  - 关键实现：`Quotio/Services/QuotaFetchers/TraeQuotaFetcher.swift`
- **Antigravity**（与 Google Cloud Code 私有 API 相关的一套模型配额/可用性探测）
  - 关键实现：`Quotio/Services/Antigravity/AntigravityQuotaFetcher.swift`
- **GLM / z.ai（bigmodel.cn）**：查询配额/limit  
  - 关键实现：`Quotio/Services/GLMQuotaFetcher.swift`
- **Kiro**：查询 usage limits（AWS 相关 endpoint）  
  - 关键实现：`Quotio/Services/QuotaFetchers/KiroQuotaFetcher.swift`

以及一个重要“限制”：

- **Gemini CLI**：Quotio 目前**不做真实 quota 查询**，只读 `~/.gemini/oauth_creds.json` 推断账号信息，并返回“未知/不可用”的占位 quota。  
  - 关键实现：`Quotio/Services/QuotaFetchers/GeminiCLIQuotaFetcher.swift`

## 3) 额度查询的 API 端点和认证方式

下面按 provider 列出“额度查询”相关的端点与认证方式（均来自代码）：

### 3.1 Codex / ChatGPT（OpenAI OAuth usage）

- **Usage endpoint**：`GET https://chatgpt.com/backend-api/wham/usage`
- **认证**：`Authorization: Bearer <access_token>`
- **token 刷新（两条路径）**
  - Codex CLI 监控：`POST https://auth.openai.com/oauth/token`（refresh_token + client_id）
    - 见 `CodexCLIQuotaFetcher.refreshAccessToken`
  - 代理 auth 文件（codex-*.json）路径：`POST https://token.oaifree.com/api/auth/refresh`（form: refresh_token）
    - 见 `OpenAIQuotaFetcher.refreshAccessToken`
- **额外 header**
  - Codex CLI 路径：主要使用 Authorization
  - 管理中心（另一个项目）会额外带 `ChatGPT-Account-Id`；Quotio 的 `OpenAIQuotaFetcher` 不需要该 header（但具体是否必需取决于上游策略）

### 3.2 Claude（Anthropic OAuth usage）

- **Usage endpoint**：`GET https://api.anthropic.com/api/oauth/usage`
- **认证**：`Authorization: Bearer <access_token>`
- **额外 header**：`anthropic-beta: oauth-2025-04-20`
- **token 来源**：`~/.cli-proxy-api/claude-*.json` 中的 `access_token`（并含 email）
- **token 刷新**：代码注释明确说明 OAuth token 通常短时有效且**不支持 refresh**，因此遇到 401/403 会提示重新登录。

### 3.3 GitHub Copilot（entitlement + 可用模型）

- **Entitlement（配额/订阅快照）**
  - `GET https://api.github.com/copilot_internal/user`
  - 认证：`Authorization: Bearer <github_oauth_token>`（从 `github-copilot-*.json` 读取）
  - 额外 header：`Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2022-11-28`
- **Copilot API token**
  - `GET https://api.github.com/copilot_internal/v2/token`
  - 认证：同上（GitHub OAuth token）
  - 返回 `token`，用于调用 Copilot API
- **模型列表（可用模型）**
  - `GET https://api.githubcopilot.com/models`
  - 认证：`Authorization: Bearer <copilot_api_token>`
  - 模拟编辑器 header：`User-Agent` / `Editor-Version` / `Editor-Plugin-Version`

### 3.4 Cursor（IDE 本地 token + Cursor API）

- **本地认证来源**：`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
  - 读取 `cursorAuth/*` 的 accessToken、refreshToken、cachedEmail、会员类型等
  - 见 `CursorQuotaFetcher.readAuthFromStateDB`
- **Usage endpoint**：`GET https://api2.cursor.sh/auth/usage-summary`
- **认证**：`Authorization: Bearer <cursor_access_token>`

### 3.5 Trae（IDE 本地 token + Trae API）

- **本地认证来源**：`~/Library/Application Support/Trae/User/globalStorage/storage.json`
  - 从 `iCubeAuthInfo://icube.cloudide` 读取 token、host、account.email 等
  - 见 `TraeQuotaFetcher.readAuthFromStorageJson`
- **Entitlement endpoint**：`POST {apiHost}/trae/api/v1/pay/user_current_entitlement_list`
  - 默认 `apiHost`：`https://api-sg-central.trae.ai`
- **认证**：`Authorization: Cloud-IDE-JWT <access_token>`
- **请求体**：`{"require_usage": true}`

### 3.6 Antigravity（Google Cloud Code 私有 API）

- **模型/配额探测**
  - `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
  - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- **token refresh**
  - `POST https://oauth2.googleapis.com/token`
- **认证**：`Authorization: Bearer <google_oauth_access_token>`

### 3.7 GLM / z.ai（bigmodel.cn）

- `GET/POST https://bigmodel.cn/api/monitor/usage/quota/limit`（代码为 quota limit endpoint）
- 认证：`Authorization: Bearer <apiKey>`  
  - 见 `Quotio/Services/GLMQuotaFetcher.swift`

### 3.8 Kiro

- `POST https://codewhisperer.us-east-1.amazonaws.com/getUsageLimits`
- 认证：`Authorization: Bearer <token>`（token 来源涉及 Kiro 多登录方式：Google OAuth / AWS Builder ID 等）  
  - 见 `Quotio/Services/QuotaFetchers/KiroQuotaFetcher.swift`

### 3.9 Gemini CLI（仅账号信息，占位 quota）

- **本地文件**：`~/.gemini/oauth_creds.json`、`~/.gemini/google_accounts.json`
- 不调用 quota API；返回 `percentage: -1`（表示 unknown/unavailable）  
  - 见 `GeminiCLIQuotaFetcher.fetchAsProviderQuota`

## 4) 核心实现代码逻辑

### 4.1 统一的“Quota 状态模型”

Quotio 将不同 provider 的 quota 数据统一为 `ProviderQuotaData`（包含 `models: [ModelQuota]`、`planType`、`lastUpdated` 等），并按 provider + account key 存在：

- `QuotaViewModel.providerQuotas: [AIProvider: [String: ProviderQuotaData]]`
  - 见 `Quotio/ViewModels/QuotaViewModel.swift`

UI 侧只关心“模型/窗口条目列表”，因此可以把 session/weekly/credits、或按 model bucket 的 quota 都塞进 `models` 进行渲染。

### 4.2 拉取调度：并发刷新 + 模式分流

核心刷新入口：

- `QuotaViewModel.refreshQuotasUnified()`
  - Full Mode：直接调用各 provider fetcher（不依赖代理是否运行）
  - Monitor Mode（Standalone Quota）：在 direct fetcher 外，额外启用 CLI fetcher（Codex CLI、Gemini CLI 等）
  - 使用 `async let` 并发获取不同 provider 的数据

各 provider 刷新函数通常形如：

- `refreshOpenAIQuotasInternal()` → `OpenAIQuotaFetcher.fetchAllCodexQuotas()`
- `refreshClaudeCodeQuotasInternal()` → 扫描 `~/.cli-proxy-api/claude-*.json` 并调 Anthropic OAuth API
- `refreshCopilotQuotasInternal()` → 扫描 `~/.cli-proxy-api/github-copilot-*.json` 并调 copilot_internal

### 4.3 “auth 文件”与“IDE 本地态”两类来源

Quotio 的 quota 查询来源分两类：

1. **Proxy auth files（~/.cli-proxy-api/*.json）**：用于 Codex/Claude/Copilot 等 OAuth 场景
2. **IDE 本地状态（SQLite/JSON）**：Cursor（SQLite）、Trae（storage.json）

这种设计让“监控额度”不必依赖服务端（CLIProxyAPI）一定在跑；同时也使得 UI 能覆盖 IDE 工具“订阅窗口额度”这类不走标准 LLM API 的用量信息。

### 4.4 解析逻辑：把不同返回映射成“窗口条”

典型映射方式：

- Codex `wham/usage` → `rate_limit.primary_window/secondary_window` 映射为 session/weekly 两条（可补充 code review window / credits）
  - 见 `OpenAIQuotaFetcher` / `CodexCLIQuotaFetcher.parseUsageResponse`
- Claude OAuth usage → `five_hour`/`seven_day`/`seven_day_opus`/`extra_usage` 映射为多条窗口
  - 见 `ClaudeCodeQuotaFetcher.parseQuotaUsage` / `parseExtraUsage`
- Copilot entitlement → 从 `quotaSnapshots` 或其他字段计算 remaining% 并写入 `ModelQuota`
  - 见 `CopilotQuotaFetcher.convertToQuotaData`

## 5) 数据展示方式

Quotio 主要有两套展示：

1. **应用内 Quota 页面**（SwiftUI）
   - `Quotio/Views/Screens/QuotaScreen.swift`
   - 支持按 provider 切换、按账号显示、不同展示风格/展示模式（Used vs Remaining）
2. **菜单栏（Status Bar）快速概览**
   - `Quotio/Services/StatusBarMenuBuilder.swift`
   - 在菜单中展示账号卡片、最低额度、模型徽标等；并可触发刷新、打开页面等操作

补充：当某 provider 无法获取 quota（例如 Gemini CLI），UI 会显示 “not available/unknown” 的占位状态；并通过通知系统（`NotificationManager`）对低额度触发提醒。

