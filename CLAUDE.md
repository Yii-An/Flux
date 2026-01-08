# Flux - CLIProxyAPI macOS 管理应用

## 项目概述

Flux 是一个 macOS 原生菜单栏应用，用于管理 CLIProxyAPI 代理服务。采用 SwiftUI + MVVM 架构，支持 macOS 15.0+。

## 技术栈

- **语言**: Swift 6.0
- **框架**: SwiftUI
- **架构**: MVVM
- **项目管理**: xcodegen (project.yml)
- **最低版本**: macOS 15.0 (Sequoia)

## 项目结构

```
Sources/
├── App/
│   └── FluxApp.swift              # 主入口，MenuBarExtra + Window
├── Models/
│   ├── SidebarItem.swift          # 侧边栏导航项枚举
│   ├── ManagementAPIModels.swift  # API 数据模型
│   └── ProxyModels.swift          # 托管模式模型 (ProxyVersion, GitHubRelease)
├── ViewModels/
│   ├── AppViewModel.swift
│   ├── NavigationViewModel.swift
│   ├── ManagementViewModel.swift
│   └── OverviewViewModel.swift
├── Views/
│   ├── ContentView.swift          # 主 NavigationSplitView
│   ├── OverviewView.swift         # 概览仪表盘
│   ├── ProvidersView.swift        # Provider 管理
│   ├── SettingsView.swift         # 设置页（纯托管模式）
│   ├── LogsView.swift             # 日志查看
│   └── PlaceholderView.swift
├── Services/
│   ├── AppSettings.swift          # UserDefaults + Keychain 持久化
│   ├── CLIProxyAPIRuntimeService.swift    # 进程生命周期管理
│   ├── ManagementAPIClient.swift          # REST API 客户端 (actor)
│   ├── NotificationService.swift          # 系统通知
│   ├── UpdateService.swift                # 自动更新占位
│   └── Proxy/
│       ├── ProxyStorageManager.swift      # 版本化存储管理
│       ├── ChecksumVerifier.swift         # SHA256 校验
│       ├── CLIProxyAPIReleaseSource.swift # 发布源定义 (单一来源)
│       ├── CLIProxyAPIReleaseService.swift # GitHub Release 下载
│       └── ManagedProxyCoordinator.swift  # 托管模式状态协调
└── Resources/
    ├── en.lproj/Localizable.strings
    └── zh-Hans.lproj/Localizable.strings
```

## CLIProxyAPI 连接

### API 端点
- **Base URL**: `http://127.0.0.1:8317/v0/management`
- **认证**: `Authorization: Bearer <management-key>`
- **健康检查**: `GET /config`
- **API Keys**: `GET/PUT/DELETE /api-keys`

### 默认配置
- **端口**: 8317 (代理和管理共用)
- **密码**: 存储在 macOS Keychain

## 托管模式

Flux 使用纯托管模式管理 CLIProxyAPI：

- 自动从 GitHub Releases 下载 CLIProxyAPI
- **发布源**: `CLIProxyAPIReleaseSource.official` (router-for-me/CLIProxyAPI)
- 版本化存储: `~/Library/Application Support/Flux/proxy/v{version}/CLIProxyAPI`
- `current` 符号链接指向激活版本
- 支持版本切换、更新检查、旧版本清理
- SHA256 校验确保下载完整性
- 二进制路径统一通过 `ProxyStorageManager.shared.currentBinaryPath` 获取

## 开发指南

### 构建项目
```bash
# 生成 Xcode 项目
xcodegen generate

# 构建
xcodebuild build -scheme Flux -configuration Debug CODE_SIGNING_ALLOWED=NO

# 运行
open /Users/leslie/Library/Developer/Xcode/DerivedData/Flux-*/Build/Products/Debug/Flux.app
```

### 添加新文件后
必须重新运行 `xcodegen generate` 以更新 Xcode 项目。

### 关键服务

1. **CLIProxyAPIRuntimeService** - 进程管理
   - 状态机: `stopped → starting → running → stopping → stopped`
   - 支持 SIGTERM + SIGKILL 优雅关闭
   - stdout/stderr 日志收集

2. **ManagementAPIClient** - API 客户端 (actor)
   - 线程安全的 async/await API
   - 自动处理 401 认证错误

3. **AppSettings** - 配置持久化
   - UserDefaults: 端口、配置路径
   - Keychain: 管理密码

4. **ProxyStorageManager** - 版本化存储
   - 安全解压 (防路径穿越)
   - chmod 0o755 + ad-hoc codesign
   - 版本激活/删除/清理
   - `shared` 单例提供 `currentBinaryPath`

5. **ManagedProxyCoordinator** - 托管模式协调器
   - GitHub Release 获取
   - 下载进度跟踪
   - 安装/激活/删除版本

6. **CLIProxyAPIReleaseSource** - 发布源定义
   - 单一来源管理 GitHub 仓库地址
   - `official` 常量: router-for-me/CLIProxyAPI
   - 提供 `releasesPageURL` 和 `apiReleasesURL` 计算属性
   - 支持自定义 host (企业 GitHub)

## 代码规范

- 使用 `@MainActor` 标记 UI 相关类
- 使用 `actor` 处理并发 API 调用
- ViewModel 使用 `@Published` 属性
- View 使用 `@EnvironmentObject` 共享状态
- `Sendable` 协议确保并发安全

## 安全考虑

- 解压前检查路径穿越和 symlink 逃逸
- SHA256 校验下载文件完整性
- 管理密码存储在 Keychain
- Best-effort ad-hoc 签名

<!-- CCA_WORKFLOW_POLICY -->
## CCA Workflow Policy

### Claude's Role (CRITICAL)
**Claude is the MANAGER, not the executor.**
- Plan and coordinate tasks
- Check role assignments before ANY action
- Delegate to appropriate executor (cask/oask/gask)
- NEVER execute file modifications directly

### Current Roles
- executor: codex+opencode (delegate)
- searcher: codex (delegate)
- git_manager: codex (delegate)

### Delegation Rules
- executor: codex+opencode → MUST use cask (Codex will delegate to OpenCode via oask)
- searcher: use cask "task"
- git_manager: use cask "task"

### Allowed Direct Operations (when role=claude)
- Read/Grep/Glob
- Write to ~/.claude/plans/**, /tmp/**, .autoflow/**
<!-- /CCA_WORKFLOW_POLICY -->
