# CatPawAI Linux Build

将 macOS DMG 版本的 CatPawAI 转换为 Linux 可运行的应用包。

## 概述

CatPawAI 是美团基于 VS Code (1.101.0) 开发的 AI IDE，使用 Electron 35.5.1。
本构建系统从 macOS DMG 中提取应用资源，替换原生模块为 Linux 版本，生成可在 Linux 上运行的 tar.gz / deb 包。

### 工作原理

```
macOS DMG                    Windows (7zip)              WSL2 (Ubuntu)
┌─────────────┐              ┌──────────────┐            ┌──────────────────┐
│ CatPawAI.app│  ──提取──→   │ extracted/   │  ──构建──→ │ Electron Linux   │
│  Resources/ │              │   app/       │            │ + app/           │
│    app/     │              │   icns       │            │ + Linux natives  │
└─────────────┘              └──────────────┘            │ → tar.gz / .deb  │
                                                         └──────────────────┘
```

1. **提取** - 使用 7-Zip 从 DMG 中提取 `Contents/Resources/app/` 目录
2. **下载** - 下载 Electron 35.5.1 Linux 版本
3. **重建** - 在 WSL2 中重新编译所有原生模块（.node 文件）
4. **组装** - 将 Electron 运行时 + 应用代码 + Linux 原生模块组装为完整应用
5. **打包** - 生成 tar.gz 和 .deb 安装包

## 前置要求

### Windows 端
- **7-Zip** (`winget install 7zip.7zip`)
- **WSL2** with Ubuntu (`wsl --install -d Ubuntu`)
- **PowerShell 7+**

### WSL2 内 (自动安装)
- Node.js 22+
- build-essential (gcc, g++, make)
- Python 3
- p7zip-full

## 使用方法

### 一键构建

```powershell
# 在 Windows PowerShell 中运行
cd CatPaw-Linux-Build
.\build.ps1
```

### 指定架构

```powershell
.\build.ps1 -Arch x64    # 默认, 适用于大多数 Linux
.\build.ps1 -Arch arm64  # ARM64 设备
```

### 跳过已完成的步骤

```powershell
# 跳过 DMG 提取（使用已提取的资源）
.\build.ps1 -SkipExtract

# 跳过 Electron 下载（使用已下载的）
.\build.ps1 -SkipDownload

# 仅在 WSL2 中运行构建
wsl bash -c "cd /mnt/c/LinuxBackup/catpaw-linux/CatPaw-Linux-Build/scripts && bash build-linux.sh --skip-extract"
```

### 分步执行

```powershell
# 1. 仅提取 DMG
.\extract-dmg.ps1

# 2. 在 WSL2 中构建
wsl bash -c "cd /mnt/c/LinuxBackup/catpaw-linux/CatPaw-Linux-Build/scripts && bash build-linux.sh"
```

## 输出

构建产物位于 `scripts/out/`：

| 文件 | 说明 |
|------|------|
| `CatPawAI-linux-x64-2026.2.3.tar.gz` | 便携版，解压即用 |
| `CatPawAI-linux-x64-2026.2.3.deb` | Debian/Ubuntu 安装包 |

## 安装

### tar.gz 方式

```bash
# 解压到 /opt
sudo tar xzf CatPawAI-linux-x64-2026.2.3.tar.gz -C /opt/

# 创建快捷方式
sudo ln -sf /opt/CatPawAI-linux-x64/bin/catpawai /usr/local/bin/catpawai

# 运行
catpawai --no-sandbox
```

### deb 方式

```bash
sudo dpkg -i CatPawAI-linux-x64-2026.2.3.deb

# 运行（从应用菜单或终端）
catpawai --no-sandbox
```

## 原生模块处理

以下原生模块会从 macOS 版本重新编译为 Linux 版本：

| 模块 | 用途 |
|------|------|
| `node-pty` | 终端伪终端支持 |
| `@vscode/spdlog` | 高性能日志 |
| `@vscode/sqlite3` | SQLite 数据库 |
| `@parcel/watcher` | 文件监视器 |
| `native-keymap` | 键盘映射 |
| `native-watchdog` | 进程看门狗 |
| `native-is-elevated` | 权限检查 |
| `kerberos` | Kerberos 认证 |
| `@vscode/policy-watcher` | 策略监视 |
| `@dp/cat-client` | CAT 监控客户端 (已有 build_linux) |

以下 Windows/macOS 专用模块会被移除：
- `@vscode/windows-mutex`
- `@vscode/windows-process-tree`
- `@vscode/windows-registry`
- `windows-foreground-love`

> 注：`@vscode/deviceid` 不再移除——它是纯 JS 模块，显式支持 Linux，`main.js` 启动时会动态导入它获取设备 ID。

## 目录结构

```
CatPaw-Linux-Build/
├── build.ps1              # 一键构建入口 (Windows)
├── extract-dmg.ps1        # DMG 提取脚本 (Windows)
├── package.json           # 构建项目配置
├── README.md              # 本文档
├── resources/             # 构建资源
│   └── catpawai.png       # 应用图标 (可选)
└── scripts/
    ├── build-linux.sh     # 主构建脚本 (WSL2)
    ├── extracted/         # DMG 提取结果 (自动生成)
    ├── downloads/         # Electron 下载缓存 (自动生成)
    ├── build/             # 构建中间产物 (自动生成)
    └── out/               # 最终输出 (自动生成)
```

## 已知限制

- `--no-sandbox` 参数是必需的，因为 Linux 上 chrome-sandbox 需要 root 权限设置
- SSO 登录功能可能需要额外的网络配置
- 部分依赖 macOS 特有 API 的扩展可能无法正常工作
- 自动更新功能在 Linux 上不可用

## 技术细节

- **Electron**: 35.5.1
- **VS Code 基础版本**: 1.101.0
- **CatPaw 版本**: 2026.2.3
- **Bundle ID**: com.catpaw.ide
- **应用代码位置**: `Contents/Resources/app/` (非 asar 打包)
- **原生模块**: 通过 `@electron/rebuild` + `npm install` 重新编译
