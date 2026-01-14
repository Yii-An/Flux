# 四个项目的额度查询实现对比（summary）

## 1) 项目定位差异（“谁在查额度、查什么额度”）

- **CLIProxyAPI**：底座/代理服务（Go）。重点在“转发 + 多账号路由 + quota exceeded 运维”，自身提供管理 API（内部用量统计 + 代呼第三方 API 的工具）。
- **Cli-Proxy-API-Management-Center**：CLIProxyAPI 的 WebUI（React/TS）。重点在“通过 Management API 做配置/凭证/日志/用量展示”，其中 Quota 页面用 `/api-call` 去拉第三方 quota。
- **Quotio**：macOS 原生“GUI 控制台”（SwiftUI）。既能通过 CLIProxyAPI 管 OAuth，也能在不启动代理时直接读取本地 auth/IDE 数据去查额度并展示。
- **CodexBar**：独立的 macOS 菜单栏额度监控器（SwiftUI），覆盖 provider 最广，强调多数据源融合（OAuth/Web/CLI/本地扫描）和常驻展示体验。

## 2) “额度”数据源类型对比

| 数据源类型 | Quotio | Management Center | CodexBar | CLIProxyAPI |
|---|---|---|---|---|
| 第三方结构化 quota API（OAuth usage / quota buckets） | 有（Claude OAuth、Codex `wham/usage`、Copilot 等） | 有（通过 `/api-call`） | 有（Codex/Claude/Gemini/Copilot 等） | 提供能力（`/api-call`），本体不内置统一聚合 |
| Web（cookie）接口/页面抓取 | 少（代码中未见 Codex/Claude web 抓取） | 无（浏览器侧不直接抓，统一走管理 API） | 多（OpenAI dashboard、Claude web、Cursor/Factory/Augment 等） | 不直接做（但可被 `/api-call` 间接利用） |
| CLI 驱动（PTY/RPC） | 部分（Gemini CLI 仅账号占位；Codex CLI 读取 auth.json 并请求 usage） | 无 | 多（Codex RPC/PTY、Claude PTY、Kiro CLI 等） | 主要做转发/执行器，不以“驱动 CLI 查 quota”为中心 |
| 本地文件/数据库（IDE 状态） | 有（Cursor `state.vscdb`、Trae `storage.json`） | 无 | 有（cookies、日志扫描等） | 有（auth files），但展示不在本体 |
| 代理侧用量统计（requests/tokens） | 有（通过 Management API 拉 `usage`） | 有（Usage 页面） | 有（本地 cost usage 扫描） | 有（`GET /v0/management/usage`） |

## 3) 认证与安全模型对比

- **CLIProxyAPI**
  - Management API：管理密钥（`Authorization: Bearer ...`）
  - `/api-call`：支持 `$TOKEN$` 替换，并对 `gemini-cli` / `antigravity` 做 refresh；可按 credential 或全局代理出网
- **Management Center**
  - 浏览器只持有 management key；真正的第三方调用与 token 替换在服务端完成（减少 token 暴露与 CORS 问题）
- **Quotio**
  - 既能调用 Management API 启动 OAuth 流程，也能直接读取本地文件/数据库拿 token（更强，但对本机权限要求更高）
- **CodexBar**
  - Keychain + cookie 导入 + CLI 驱动；强调“本地解析/最小上传”，但涉及浏览器 cookie 时需要 Full Disk Access（用户可选择不开）

## 4) 典型 quota 端点对比（代表性）

- Codex：`GET https://chatgpt.com/backend-api/wham/usage`
  - Quotio：直接调用（Bearer token）
  - Management Center：通过 `/v0/management/api-call`，并补充 `Chatgpt-Account-Id`
  - CodexBar：OAuth API + Web dashboard + CLI（RPC/PTY）
- Claude：`GET https://api.anthropic.com/api/oauth/usage`
  - Quotio：直接调用（Bearer + anthropic-beta）
  - CodexBar：OAuth 优先；失败可用 claude.ai cookie API 或 CLI
- Gemini：`POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Management Center：通过 `/api-call` 调用
  - CodexBar：直接调用（并含 token refresh、project discovery、tier detection）
  - Quotio：当前仅账号占位，不查真实 quota

## 5) 展示方式对比

- **Quotio**：应用内 Quota 页面 + 菜单栏下拉菜单（账号卡片/模型条/阈值提示）+ 通知告警
- **Management Center**：Web 页面卡片 + 进度条 + 分页（按 auth file 聚合）
- **CodexBar**：菜单栏常驻图标（双 bar + reset 倒计时 + incident）+ 下拉菜单；另有 CLI 输出用于脚本
- **CLIProxyAPI**：以 JSON API 为主；控制面板是外部 UI 构建产物（management.html）

## 6) 适用场景建议

- 需要一个“可编排的底座/统一入口/多账号路由 + 管理 API” → **CLIProxyAPI**
- 想要“浏览器里管配置/凭证/日志/用量 + 查特定 OAuth quota” → **Management Center**
- 想要“macOS 原生、围绕 CLIProxyAPI 的一体化控制台，并支持不跑代理也能查额度” → **Quotio**
- 想要“单纯把各种助手额度常驻显示在菜单栏，并支持多种抓取方式（API/CLI/cookies）” → **CodexBar**

