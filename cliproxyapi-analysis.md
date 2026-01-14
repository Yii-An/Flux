# CLIProxyAPI（router-for-me/CLIProxyAPI）额度查询实现分析

## 1) 项目概述和主要功能

CLIProxyAPI 是一个 Go 编写的本地代理服务，提供 OpenAI / Gemini / Claude 等“兼容接口”，把各种 AI coding 工具（CLI/IDE 插件/SDK）统一接入到一个本地端口，并支持：

- 多 provider、多账号、路由与自动切换（round-robin / failover / quota exceeded cooldown）
- OAuth 登录（Codex/Claude/Qwen/iFlow/Gemini CLI/Antigravity 等）与 auth files 管理
- Management API（`/v0/management`）：配置、凭证、日志、用量统计、控制面板等
- Usage Statistics：代理侧按请求/模型聚合 token、RPM/TPM 等

从“额度查询”角度，它更像底座：**它不内置一个“统一 quota 端点”去替你查询所有第三方的订阅额度**，而是提供两种能力，让上层 UI/客户端去实现“额度查询/展示”：

1. `GET /v0/management/usage`：代理侧聚合用量统计（属于“内部统计”）
2. `POST /v0/management/api-call`：一个通用的“带凭证代呼第三方 HTTP”工具（支撑 quota 拉取）

## 2) 支持哪些 AI 服务商的额度查询

CLIProxyAPI 本体的 “proxy provider” 支持范围很广（README：OpenAI/Gemini/Claude/Codex + 多种 OAuth/compat/upstream），但“额度查询”能力主要体现在 Management API 层：

- **通用额度查询（通过 api-call）**：理论上支持任何第三方，只要你能提供 URL + headers/body，并且服务端能从指定 auth file 解析/刷新 token。
- **内置 token 刷新特殊处理**（在 api-call 里显式支持）：
  - `provider == gemini-cli`：自动 refresh Google OAuth token
  - `provider == antigravity`：自动 refresh Google OAuth token
  - 其他 provider：使用 auth file metadata/attributes 的 token/api_key/cookie 等作为 `$TOKEN$`

这也是为什么管理中心（另一个 repo）能在浏览器里查看 Codex/Gemini CLI/Antigravity 的 quota：它们都可以通过 `/api-call` 组合出来。

## 3) 额度查询的 API 端点和认证方式

### 3.1 Management API 的认证方式

所有 management endpoints（包括 `/usage`、`/api-call`）由管理中间件保护，支持：

- `Authorization: Bearer <MANAGEMENT_KEY>`
- 或 `X-Management-Key: <MANAGEMENT_KEY>`

路由注册：`internal/api/server.go` 的 `registerManagementRoutes()`。

### 3.2 代理侧用量统计：`GET /v0/management/usage`

- Endpoint：`GET /v0/management/usage`
- 返回：`usage.StatisticsSnapshot`（内存快照）+ `failed_requests` 等
- 实现：`internal/api/handlers/management/usage.go`
- 说明：这是“代理统计”，用来回答“过去一段时间 CLIProxyAPI 代理了多少请求/多少 token/按模型分布”，不等同于“订阅额度剩余多少”。

### 3.3 通用代呼：`POST /v0/management/api-call`

这是实现“第三方 quota 查询”的关键。

- Endpoint：`POST /v0/management/api-call`
- 实现：`internal/api/handlers/management/api_tools.go`
- 请求体（核心字段）：
  - `auth_index` / `authIndex`：从 `GET /v0/management/auth-files` 获取的 credential 标识
  - `method`、`url`、`header`、`data`
  - header 支持 `$TOKEN$` 变量
- `$TOKEN$` 的替换来源（按优先级）：
  1) `metadata.access_token`
  2) `attributes.api_key`
  3) `metadata.token / metadata.id_token / metadata.cookie`
  - 注释与代码：`api_tools.go` 顶部说明 + `tokenValueForAuth()`
- **代理/出口选择**：
  1) credential 自带 `proxy_url`
  2) 全局 config `proxy-url`
  3) 直连
  - 见 `api_tools.go` 的注释与 `apiCallTransport()`

### 3.4 gemini-cli 与 antigravity 的 token refresh

`/api-call` 会在发现 provider 为 `gemini-cli` 或 `antigravity` 时走“强制 refresh”逻辑：

- `gemini-cli`：
  - 使用内置 client_id/client_secret + Google OAuth scopes
  - `oauth2.Config.TokenSource(...).Token()` 刷新并回写 auth metadata
  - 见 `refreshGeminiOAuthAccessToken()`（`api_tools.go`）
- `antigravity`：
  - `POST https://oauth2.googleapis.com/token`（refresh_token + client_id/client_secret）
  - 见 `refreshAntigravityOAuthAccessToken()`（`api_tools.go`）

这使得 UI 只需要发一次 `/api-call`，服务端就会在需要时刷新 token，然后把 `$TOKEN$` 替换成最新 access_token 去请求 quota endpoint。

## 4) 核心实现代码逻辑

### 4.1 Management routes 组织方式

Management API 路由集中注册于：

- `internal/api/server.go#registerManagementRoutes`

与“额度查询”直接相关的路由：

- `GET /v0/management/usage`（内部统计）
- `POST /v0/management/api-call`（代呼第三方 quota API）
- `GET /v0/management/auth-files`（提供 `auth_index` 与凭证元数据）
- `GET/PUT/PATCH /v0/management/quota-exceeded/*`（配置“额度超限行为”：自动切项目/切 preview model）

### 4.2 quota exceeded 的“运行时管理”与降级

CLIProxyAPI 在转发请求的执行器/调度器中，会根据上游返回的 quota 错误做：

- 标记某 client/model “quota exceeded”，进入 cooldown/backoff
- 在路由层自动切换到其他可用账号或备选模型

相关概念与实现可从以下路径追踪：

- `sdk/cliproxy/auth/conductor.go`（quota backoff / cooldown）
- `internal/registry/model_registry.go`（按 model 跟踪 quota exceeded clients）
- `internal/config/config.go`（`quota-exceeded` 行为配置）

这部分是“配额超限后的自动运维”，不是“额度查询”，但决定了系统如何在额度耗尽时保持可用性。

## 5) 数据展示方式

CLIProxyAPI 本体是服务端，不提供复杂 UI；展示主要通过：

- **JSON API 输出**：`/v0/management/usage`、`/v0/management/auth-files`、`/v0/management/api-call` 等
- **内置控制面板（management.html）**：项目内会下载/服务一个单文件 UI（对应另一个 repo 的构建产物）
  - 路由：`/management.html`（在 API 端口下）

因此，“额度查询”的最终呈现通常由上层 UI（如管理中心、Quotio）负责完成。

