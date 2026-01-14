# CLIProxyAPIPlus `~/.cli-proxy-api` Auth Files 分析

目标：基于 `router-for-me/CLIProxyAPIPlus` 的源码，整理它会在 `~/.cli-proxy-api` 下生成哪些 Provider 的认证文件（OAuth/凭证文件），每种 Provider 的文件命名规则、文件内容结构（字段），以及是否支持多账号并存。

> 结论先行：CLIProxyAPIPlus 的“凭证存储”统一落在 `auth-dir`（默认 `~/.cli-proxy-api`），绝大多数凭证文件是 `*.json`；另外管理端 OAuth 回调会产生短生命周期的 `.oauth-*` 临时文件（非 JSON 文件，不会被 `List()` 枚举）。

---

## 0. Auth 目录与持久化机制概览

### 默认目录
- `config.example.yaml`：`auth-dir: "~/.cli-proxy-api"`

### 写入方式与权限
- 目录：`0700`（`MkdirAll(..., 0700)`）
- 文件：`0600`
- 写入路径来源：
  - `sdk/auth/filestore.go`：`FileTokenStore.Save()` 会把 `coreauth.Auth` 写入文件：
    - `auth.Storage != nil`：调用 `Storage.SaveTokenToFile(path)`（由各 Provider 的 TokenStorage struct 决定 JSON 字段）
    - `auth.Metadata != nil`：直接 `json.Marshal(auth.Metadata)` 写入（用于 Antigravity/Kiro 等）
- 列举规则：
  - `sdk/auth/filestore.go`：`List()` 只遍历并解析 `*.json`；`.oauth-*.oauth` 不会被列举。
  - Provider 识别依赖 JSON 顶层的 `type` 字段：`metadata["type"]`，缺失则标记为 `unknown`。

---

## 1. 会生成哪些 Provider 的认证文件

CLIProxyAPIPlus（Plus）内置可登录/导入并落盘到 `~/.cli-proxy-api` 的 Provider：

### 1.1 OAuth / Device Flow / 登录生成（落盘 `*.json`）
- `claude`（Anthropic OAuth）
- `codex`（OpenAI/Codex OAuth）
- `gemini`（Google Gemini CLI OAuth / Cloud Code）
- `antigravity`（Google OAuth，带 project discovery）
- `github-copilot`（GitHub Device Flow）
- `iflow`（iFlow OAuth；另有 Cookie 导入模式）
- `qwen`（Qwen Device Flow）
- `kiro`（Kiro / AWS Builder ID / IDC / Google / GitHub 等多方式）

### 1.2 非 OAuth：导入生成（落盘 `*.json`）
- `vertex`（Google Vertex AI：导入 service account JSON 作为凭证）

### 1.3 OAuth 回调临时文件（落盘 `.oauth-*`）
- 用于管理端/回调解耦：`.oauth-<canonicalProvider>-<state>.oauth`
- canonicalProvider 规范化映射（来自 `internal/api/handlers/management/oauth_sessions.go`）：
  - `claude` → `anthropic`
  - `codex` → `codex`
  - `gemini` → `gemini`
  - `iflow` → `iflow`
  - `antigravity` → `antigravity`
  - `qwen` → `qwen`
  - `kiro` → `kiro`

---

## 2. 各 Provider 的文件命名规则（FileName）

> 说明：下列 `FileName` 是写入 `~/.cli-proxy-api/<FileName>` 的文件名（不含目录）。其中部分 Provider 在不同入口（CLI 登录 / 管理端登录 / 导入）存在细微差异，Flux 做扫描时建议“以 `type` 字段为准”，文件名仅用于人类可读/多账号区分。

### 2.1 Claude（`type="claude"`）
- 文件名：`claude-<email>.json`
- 多账号：支持（email 不同即不同文件）
- 备注：email 未做文件名净化（包含 `@` `.` 属于正常情况）

### 2.2 Codex（`type="codex"`）
- 文件名：`codex-<email>.json`
- 多账号：支持
- 备注：同上，email 未净化

### 2.3 Gemini（`type="gemini"`）
存在两套常见命名：
- CLI 登录（`sdk/auth/gemini.go`）：`<email>-<project_id>.json`
- 管理端保存（`internal/api/handlers/management/auth_files.go`）：`gemini-<email>-<project_id>.json`
- 特殊：当 `project_id` 表示多项目（`ALL` 或逗号分隔列表）时，`CredentialFileName()` 会生成：
  - `gemini-<email>-all.json`（即便 `includeProviderPrefix=false` 也会强制加 `gemini-` 前缀）
- 多账号：支持（email + project_id 作为区分维度；同 email 同 project 会覆盖）

### 2.4 Antigravity（`type="antigravity"`）
- 文件名：
  - 有 email：`antigravity-<email_sanitized>.json`（`@`/`.` 会被替换为 `_`）
  - 无 email：`antigravity.json`
- 多账号：基本支持（有 email 时）；无 email 会产生单文件覆盖风险

### 2.5 GitHub Copilot（`type="github-copilot"`）
- 文件名：`github-copilot-<username>.json`
- 多账号：支持（GitHub username 区分）

### 2.6 Qwen（`type="qwen"`）
- 文件名：`qwen-<email_or_alias>.json`
- 多账号：支持（email/alias 区分）

### 2.7 iFlow（`type="iflow"`）
存在两套命名：
- OAuth 登录（`sdk/auth/iflow.go`）：`iflow-<email>-<unix_ts>.json`
- Cookie 导入（`internal/cmd/iflow_cookie.go`）：`iflow-<email_sanitized>-<unix_ts>.json`
- 多账号：支持（email + 时间戳；时间戳也避免同账号重复登录覆盖）

### 2.8 Kiro（`type="kiro"`）
Kiro 支持多种登录/导入方式，因此文件名也更“多样化”，总体规则：
- 账号标识部分 `idPart`：
  - 优先用 email（会被净化），否则用 `profile_arn` 的末段（也会净化），再否则用时间戳兜底
- 文件名前缀：
  - AWS/IDC 登录：`kiro-aws-<idPart>.json` 或 `kiro-idc-<idPart>.json`（取决于 auth method/label）
  - Google 登录：`kiro-google-<idPart>.json`
  - GitHub 登录：`kiro-github-<idPart>.json`
  - IDE 导入：`kiro-<provider>-<idPart>.json`（provider 会被净化；缺失则 `imported`）
- 多账号：支持（不同 email/ARN/来源可并存；同“来源+账号标识”会覆盖）

### 2.9 Vertex（`type="vertex"`，导入 Service Account）
- 文件名：`vertex-<project_id_sanitized>.json`（`/\\: ` 等字符会被替换）
- 多账号：以 `project_id` 为主；同 `project_id` 会覆盖（除非修改文件名策略）

### 2.10 OAuth 回调临时文件（不属于凭证 JSON）
- 文件名：`.oauth-<canonicalProvider>-<state>.oauth`
- 多账号：不适用（短生命周期、按 state 区分）

---

## 3. 各 Provider 的文件内容结构（JSON 字段）

### 3.1 Claude（`claude-*.json`）
写入结构来自 `internal/auth/claude/token.go`（`ClaudeTokenStorage`）：
- `id_token` (string)
- `access_token` (string)
- `refresh_token` (string)
- `last_refresh` (string)
- `email` (string)
- `type` = `"claude"`
- `expired` (string)

### 3.2 Codex（`codex-*.json`）
写入结构来自 `internal/auth/codex/token.go`（`CodexTokenStorage`）：
- `id_token` (string)
- `access_token` (string)
- `refresh_token` (string)
- `account_id` (string)
- `last_refresh` (string)
- `email` (string)
- `type` = `"codex"`
- `expired` (string)

### 3.3 Gemini（`*-<project>.json` / `gemini-*.json`）
写入结构来自 `internal/auth/gemini/gemini_token.go`（`GeminiTokenStorage`）：
- `token` (any)：
  - 原样保存 OAuth2 token 对象（字段随实现变化，通常包含 `access_token`/`refresh_token`/`token_type`/`expiry` 等）
- `project_id` (string)
- `email` (string)
- `auto` (bool)
- `checked` (bool)
- `type` = `"gemini"`

### 3.4 Antigravity（`antigravity*.json`）
Antigravity 走 `Metadata map[string]any` 落盘（`sdk/auth/antigravity.go`），典型字段：
- `type` = `"antigravity"`
- `access_token` (string)
- `refresh_token` (string)
- `expires_in` (number)
- `timestamp` (number，ms)
- `expired` (string，RFC3339)
- `email` (string，可选)
- `project_id` (string，可选)

### 3.5 GitHub Copilot（`github-copilot-*.json`）
写入结构来自 `internal/auth/copilot/token.go`（`CopilotTokenStorage`）：
- `access_token` (string)
- `token_type` (string)
- `scope` (string)
- `expires_at` (string，可选)
- `username` (string)
- `type` = `"github-copilot"`

### 3.6 Qwen（`qwen-*.json`）
写入结构来自 `internal/auth/qwen/qwen_token.go`（`QwenTokenStorage`）：
- `access_token` (string)
- `refresh_token` (string)
- `last_refresh` (string)
- `resource_url` (string)
- `email` (string)
- `type` = `"qwen"`
- `expired` (string)

### 3.7 iFlow（`iflow-*.json`）
写入结构来自 `internal/auth/iflow/iflow_token.go`（`IFlowTokenStorage`）：
- `access_token` (string)
- `refresh_token` (string)
- `last_refresh` (string)
- `expired` (string)
- `api_key` (string)
- `email` (string)
- `token_type` (string)
- `scope` (string)
- `cookie` (string)
- `type` = `"iflow"`

### 3.8 Kiro（`kiro-*.json`）
Kiro 主要以 `Metadata map[string]any` 落盘（`sdk/auth/kiro.go`），字段会因登录方式不同而略有差异；常见字段：
- `type` = `"kiro"`
- `access_token` (string)
- `refresh_token` (string)
- `profile_arn` (string)
- `expires_at` (string，RFC3339)
- `auth_method` (string)：
  - 例如 `builder-id` / `idc` 等
- `provider` (string)：
  - 例如 `google` / `github` / `aws` 等
- `email` (string，可能为空；IDE 导入时会尝试从 JWT 提取)
- `client_id` / `client_secret` (string，可选，IDC/Builder ID 刷新相关)
- `start_url` / `region` (string，可选，IDC 相关)

### 3.9 Vertex（`vertex-*.json`）
写入结构来自 `internal/auth/vertex/vertex_credentials.go`（`VertexCredentialStorage`）：
- `service_account` (object：原样保存 service account JSON)
- `project_id` (string)
- `email` (string)
- `location` (string，可选，默认 `us-central1`)
- `type` = `"vertex"`

### 3.10 OAuth 回调临时文件（`.oauth-*.oauth`）
写入结构来自 `internal/api/handlers/management/oauth_sessions.go`：
- `code` (string)
- `state` (string)
- `error` (string)

---

## 4. 是否支持多账号（按 Provider 汇总）

总体结论：**支持多账号并存**（同一 Provider 通过文件名区分账号），但存在少量覆盖风险点。

- Claude / Codex / Copilot / Qwen：通过 `email/username` 区分，多账号 OK。
- Gemini：通过 `email + project_id` 区分；同组合会覆盖；多项目有 `*-all.json` 归一文件名。
- iFlow：文件名带时间戳，天然支持同账号多份并存；OAuth 与 Cookie 两种入口的 email 是否净化不一致。
- Antigravity：有 email 时多账号 OK；无 email 会落到 `antigravity.json`，存在覆盖风险。
- Kiro：文件名包含来源与账号标识（email/ARN），通常多账号 OK；同来源同账号标识会覆盖。
- Vertex：按 `project_id` 命名，同项目会覆盖；不同项目可并存。

---

## 5. 对 Flux 扫描/监控实现的直接建议（与本分析相关）

- **强依赖 `type` 字段**进行 Provider 归类（不要仅靠文件名前缀），因为 Gemini/iFlow/Kiro 存在多种命名分支。
- 监控/扫描时同时考虑：
  - `*.json`：主凭证文件（`FileTokenStore.List()` 的行为）
  - `.oauth-*.oauth`：短生命周期回调文件（如果 Flux 要在 UI 中展示“登录进行中/等待回调”，需要单独 watch）
- 处理覆盖/冲突：
  - `antigravity.json`、`vertex-<project>.json` 属于“单 key 覆盖型”文件名；Flux UI 需要能解释“为什么只有一份”。

