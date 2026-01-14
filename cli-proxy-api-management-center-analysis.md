# Cli-Proxy-API-Management-Center（router-for-me/Cli-Proxy-API-Management-Center）额度查询实现分析

## 1) 项目概述和主要功能

该项目是一个 **React + TypeScript** 的“单文件 WebUI”，用于操作和排障 **CLIProxyAPI** 的 **Management API**（`/v0/management`）：

- 读取/修改配置（含 quota fallback、usage 统计开关等）
- 上传/下载/删除 OAuth 认证文件（Auth Files）
- 查看日志、请求错误、系统信息、模型列表
- 查看/导出/导入 **Usage Statistics**（代理侧聚合的 requests/tokens/模型分布等）
- 提供一个专门的 **Quota Management 页面**：对一组“OAuth/订阅类助手”的剩余额度做拉取与展示

它本身不转发 LLM 流量；所有能力依赖 CLIProxyAPI 实例提供的管理接口。

## 2) 支持哪些 AI 服务商的额度查询

从“额度查询（quota/remaining/limits）”来看，这个 WebUI 明确实现了 3 类 quota 源：

- **Antigravity**（Cloud Code 私有 API 的 `fetchAvailableModels`，用于推断可用模型与配额 bucket）
- **OpenAI Codex / ChatGPT**（`wham/usage` 返回 5h/weekly/code review 窗口等）
- **Gemini CLI**（Cloud Code 私有 API 的 `retrieveUserQuota` 返回 buckets）

除此之外，WebUI 还有一个 **Usage** 页面，用 `GET /v0/management/usage` 展示 CLIProxyAPI 的“代理侧用量统计”，这通常会覆盖 OpenAI/Claude/Gemini/OpenAI-compatible 等所有被代理的 provider，但它属于“代理内部统计”，不等同于“订阅/窗口额度”。

## 3) 额度查询的 API 端点和认证方式

### 3.1 Management API 认证（WebUI → CLIProxyAPI）

WebUI 通过 axios client 在每次请求带上管理密钥：

- Header：`Authorization: Bearer <MANAGEMENT_KEY>`
- Base：`{apiBase}/v0/management`
  - 见 `src/services/api/client.ts`

### 3.2 Quota 查询的“关键机制”：`POST /v0/management/api-call`

Quota 页面的外部 API 调用不是浏览器直连第三方（避免 CORS/泄露 token），而是走 CLIProxyAPI 的通用代理调用接口：

- Endpoint：`POST /v0/management/api-call`
- 由 WebUI 发送 payload：
  - `authIndex`：选择某个 auth file（来自 `GET /v0/management/auth-files` 列表里的 `auth_index`）
  - `method` / `url` / `header` / `data`
  - header 可包含魔法占位符：`$TOKEN$`（由服务端替换）
  - 见 `src/services/api/apiCall.ts`

### 3.3 各 quota 类型的第三方端点与 header

这些端点由前端常量定义，并由 `/api-call` 代为请求：

- **Antigravity**
  - `POST https://{daily-}cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
    - 常量：`src/utils/quota/constants.ts` 中 `ANTIGRAVITY_QUOTA_URLS`
  - Header 模板：`Authorization: Bearer $TOKEN$` + `User-Agent: antigravity/...`
- **Codex**
  - `GET https://chatgpt.com/backend-api/wham/usage`
    - 常量：`CODEX_USAGE_URL`
  - Header 模板：`Authorization: Bearer $TOKEN$` + `User-Agent: codex_cli_rs/...`
  - 额外 Header：`Chatgpt-Account-Id: <accountId>`
    - accountId 从 auth file 的 `id_token` JWT payload 提取
    - 见 `src/utils/quota/resolvers.ts` 的 `resolveCodexChatgptAccountId`
- **Gemini CLI**
  - `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
    - 常量：`GEMINI_CLI_QUOTA_URL`
  - Header 模板：`Authorization: Bearer $TOKEN$`
  - Body：`{"project": "<projectId>"}`（projectId 从 auth file 的 `account` 字段解析括号内容）
    - 见 `resolveGeminiCliProjectId`

## 4) 核心实现代码逻辑

### 4.1 页面结构：QuotaPage 组合 3 个 QuotaSection

- `src/pages/QuotaPage.tsx`
  - 加载 auth files 列表：`authFilesApi.list()`
  - 加载 config（用于显示/判断后端支持能力等）：`configFileApi.fetchConfigYaml()`
  - 渲染 `QuotaSection`（Antigravity/Codex/Gemini CLI 各一块）

### 4.2 QuotaSection：分页 + 批量刷新 + 状态缓存

- `src/components/quota/QuotaSection.tsx`
  - 对 auth files 做 `filterFn`（例如 `isCodexFile`）
  - 支持 paged/all 两种视图，避免一次性对太多文件发请求
  - 刷新通过 `useQuotaLoader` 批量执行，并把结果存到 Zustand store（`useQuotaStore`）

### 4.3 QuotaConfigs：每种 quota 的 fetch/parse/render 都在配置里闭包化

- `src/components/quota/quotaConfigs.ts`
  - `fetchAntigravityQuota`：轮询多个 Cloud Code host，成功后解析模型列表并分组（`buildAntigravityQuotaGroups`）
  - `fetchCodexQuota`：调用 `wham/usage`，解析 `rate_limit` 与 `code_review_rate_limit`，组装多个窗口条
  - `fetchGeminiCliQuota`：调用 `retrieveUserQuota`，把 buckets 归并成 UI 可展示的“按模型组”列表
  - 三者都通过 `apiCallApi.request()` 调 `POST /api-call`

### 4.4 UI 展示组件：QuotaCard + ProgressBar

- `src/components/quota/QuotaCard.tsx`
  - 根据 `QuotaStatusState`（idle/loading/success/error）显示不同内容
  - 统一用 `QuotaProgressBar` 渲染百分比条；并通过阈值换色（high/medium/low）

## 5) 数据展示方式

- **Quota Management 页面**：按 provider 分组，按 auth file（账号/凭证）为单位展示卡片；每张卡片展示若干“quota 行”（模型/窗口 → percent + reset）
- **Usage 页面**：展示 CLIProxyAPI 聚合的 requests/tokens 图表与分解（来自 `/v0/management/usage`），可导出/导入
- **错误与兼容性**：QuotaCard 对 `403/404` 映射友好提示（credential 问题 / 后端版本过低）

