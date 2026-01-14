# CodexBar（steipete/CodexBar）额度查询实现分析

## 1) 项目概述和主要功能

CodexBar 是一个 macOS 14+ 菜单栏应用（Swift/SwiftUI），目标是“把各种 AI coding 助手的用量/额度窗口一直显示在顶部”，并在窗口重置时提示：

- 多 Provider 支持：Codex、Claude、Cursor、Gemini、Antigravity、Droid(Factory)、Copilot、z.ai、Kiro、Vertex AI、Augment 等
- 多数据源融合：OAuth API、Web（cookie）接口、CLI（RPC/PTY）、本地日志扫描
- 菜单栏动态图标：双 bar 显示 session/weekly，低额度变色/变暗，附带 incident badge
- 可选的 CLI 工具：`codexbar`（用于脚本/CI 输出 usage/cost）

从“额度查询”视角，它的核心思想是：**每个 provider 都有独立的 fetcher/探针（probe），把各自数据源转成统一的 UsageSnapshot（primary/secondary window + reset + identity）**。

## 2) 支持哪些 AI 服务商的额度查询

CodexBar 的 provider 覆盖面最广；其中与“典型大模型服务商”直接相关的配额/额度查询包括：

- **OpenAI Codex / ChatGPT**：OAuth usage API + Web dashboard + Codex CLI（RPC/PTY）
- **Anthropic Claude**：OAuth usage API + claude.ai web API（cookie）+ Claude CLI PTY
- **Google Gemini**：Gemini CLI OAuth 凭证 + Cloud Code 私有 quota API（retrieveUserQuota/loadCodeAssist）
- **GitHub Copilot**：GitHub device flow + copilot_internal usage API

此外还有大量“IDE/工具型助手”的额度来源（Cursor、Factory/Droid、Augment、Kiro 等），但它们更多依赖 cookie/CLI/本地文件，而非标准 LLM API。

## 3) 额度查询的 API 端点和认证方式（按主要 provider）

CodexBar 的 provider 文档写得非常明确（建议直接从 docs 追踪；下面提炼最关键的 endpoint/认证组合）。

### 3.1 Codex（OpenAI）

**OAuth API（App 默认优先）**

- 凭证：`~/.codex/auth.json`（或 `$CODEX_HOME/auth.json`）
- Endpoint：`GET https://chatgpt.com/backend-api/wham/usage`
- Header：`Authorization: Bearer <access_token>`（可选 `ChatGPT-Account-Id`）
- 代码：`Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift`
  - 内部还支持 baseURL 兼容，并在 `/wham/usage` 与 `/api/codex/usage` 之间自适配

**Web dashboard（可选增强：credits、code review、图表等）**

- 页面：`https://chatgpt.com/codex/settings/usage`
- 认证：浏览器 cookie（可自动导入 Safari/Chrome/Firefox cookies 或手动粘贴 Cookie header）
- 技术实现：离屏 `WKWebView` + `WKWebsiteDataStore`，抓取并解析页面渲染后的文本/JSON
  - 见 `docs/codex.md` 与 `Sources/CodexBarCore/OpenAIWeb/*`

**Codex CLI（RPC/PTY fallback）**

- RPC：启动 `codex ... app-server`，用 JSON-RPC 读 account/rateLimits
- PTY：跑 `codex`，发送 `/status`，解析屏幕文本（Credits/5h/Weekly）
  - 见 `Sources/CodexBarCore/Providers/Codex/*` 与 `docs/codex.md`

### 3.2 Claude（Anthropic）

**OAuth API（优先）**

- Endpoint：`GET https://api.anthropic.com/api/oauth/usage`
- Header：
  - `Authorization: Bearer <access_token>`
  - `anthropic-beta: oauth-2025-04-20`
- 凭证：Keychain `Claude Code-credentials`（优先）或 `~/.claude/.credentials.json`
  - 见 `docs/claude.md`、`Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/*`

**claude.ai Web API（cookie）**

- Cookie：`sessionKey=sk-ant-...`
- API：
  - `GET https://claude.ai/api/organizations`（拿 orgId）
  - `GET https://claude.ai/api/organizations/{orgId}/usage`
  - `GET https://claude.ai/api/organizations/{orgId}/overage_spend_limit`
  - `GET https://claude.ai/api/account`（邮箱/plan hints）
  - 见 `docs/claude.md`、`Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift`

**Claude CLI PTY（fallback）**

- 跑 `claude` PTY，发送 `/usage`（必要时 `/status`），解析文本
  - 见 `Sources/CodexBarCore/Providers/Claude/ClaudeStatusProbe.swift`

### 3.3 Gemini（Google）

CodexBar 的 Gemini 路径比“只读 auth 文件”更完整：它使用 Gemini CLI 的 OAuth 凭证，并通过 Cloud Code 私有 API 查询 quota。

- 凭证：`~/.gemini/oauth_creds.json`（含 access_token/refresh_token/id_token/expiry_date）
- Token refresh：`POST https://oauth2.googleapis.com/token`
  - client_id/client_secret 通过解析 Gemini CLI 安装目录里的 `oauth2.js` 提取
  - 见 `docs/gemini.md`
- Quota：
  - `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Body：`{ "project": "<projectId>" }`（可通过 projects API 推断项目）
- Project discovery：
  - `GET https://cloudresourcemanager.googleapis.com/v1/projects`
- Tier detection：
  - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- 代码：`Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift`

### 3.4 Copilot（GitHub）

- 认证：GitHub OAuth device flow（scope `read:user`），token 存 Keychain
  - 见 `docs/copilot.md`
- Usage：
  - `GET https://api.github.com/copilot_internal/user`
  - Header 组合模拟 VSCode/Copilot 生态（Editor-Version/Plugin-Version/User-Agent 等）
- 代码：`Sources/CodexBarCore/Providers/Copilot/CopilotUsageFetcher.swift`、`CopilotDeviceFlow.swift`

## 4) 核心实现代码逻辑

### 4.1 Provider “描述符 + FetchPlan + Probe”结构

CodexBarCore 把 provider 逻辑分层组织（便于添加/替换数据源）：

- Provider descriptor：声明 UI 元数据、dashboard URL、可用的数据源策略等
  - 示例：`Sources/CodexBarCore/Providers/Codex/CodexProviderDescriptor.swift`
- Probe / Fetcher：真正执行数据拉取/解析（HTTP、cookie、CLI、log scan）
  - Codex OAuth：`CodexOAuthUsageFetcher.fetchUsage`
  - Gemini：`GeminiStatusProbe.fetch`
  - Claude：OAuth/Web/CLI 三路径选择

统一输出通常会落到：

- `UsageSnapshot`（primary/secondary window percent used + reset + identity）
- 可选的 `CreditsSnapshot`（余额/credits history）

### 4.2 多数据源降级与合并

CodexBar 的共同模式：

- **优先“最稳定/结构化”的 API**（OAuth usage）→ 失败则降级（Web cookie / CLI 文本解析）
- Web dashboard（OpenAI）作为“增强信息”并行加载：即使 primary quota 来自 OAuth/CLI，仍可补齐 credits、code review、图表
  - 见 `docs/codex.md`

### 4.3 认证与本地敏感数据处理

它大量使用“本地来源”避免把敏感 token 发往第三方服务：

- Keychain：Claude OAuth、Copilot token、z.ai token 等
- Browser cookies：可选、需授权 Full Disk Access 时读取 Safari/Chrome/Firefox cookie DB
- CLI PTY：直接驱动官方 CLI 命令获取 usage/status

## 5) 数据展示方式

CodexBar 的展示以“菜单栏常驻 + 下拉菜单卡片”为核心：

- 顶部图标是“双 bar meter”（session + weekly / credits 变体），带低额度配色与 incident badge
- 下拉菜单显示：每个 provider 的窗口百分比、重置倒计时、账号/plan 信息、错误状态等
- CLI（可选）：`codexbar usage` / `codexbar cost ...` 用于脚本化输出（尤其是本地 cost usage 扫描）

关键 UI/控制文件示例：

- `Sources/CodexBar/StatusItemController+Animation.swift`
- `Sources/CodexBar/IconView.swift`
- `Sources/CodexBar/SettingsStore.swift`

