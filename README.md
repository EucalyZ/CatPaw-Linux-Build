# CatPawAI Linux Build

将 macOS DMG 版本的 CatPawAI 转换为 Linux 可运行的应用包。

## 概述

CatPawAI 是美团基于 VS Code (1.101.0) 开发的 AI IDE，使用 Electron 35.5.1。
本构建系统从 macOS DMG 中提取应用资源，替换原生模块为 Linux 版本，生成可在 Linux 上运行的 tar.gz / deb / pacman 包。

### 工作原理

```
macOS DMG                         Linux (原生 or WSL2)
┌─────────────┐                   ┌──────────────────────────┐
│ CatPawAI.app│  ──7zip 解压──→   │ extracted/app/           │
│  Resources/ │                   │                          │
│    app/     │                   │   ┌── Electron Linux ──┐ │
└─────────────┘                   │   │ + app/             │ │
                                  │   │ + Linux natives    │ │
                                  │   └────────────────────┘ │
                                  │   → tar.gz / .deb / .pkg │
                                  └──────────────────────────┘
```

1. **提取** - 使用 7-Zip (p7zip) 从 DMG 中提取 `Contents/Resources/app/` 目录
2. **下载** - 下载 Electron 35.5.1 Linux 版本
3. **重建** - 重新编译所有原生模块（.node 文件）为 Linux 版本
4. **组装** - 将 Electron 运行时 + 应用代码 + Linux 原生模块组装为完整应用
5. **打包** - 生成 tar.gz、.deb 安装包，以及 Arch pacman 包 (.pkg.tar.zst)

## 前置要求

### Linux（原生，推荐）

- **7-Zip** (`sudo apt install p7zip-full` / `pacman -S p7zip` / `dnf install p7zip`)
- **Node.js 22+**
- **build-essential** (gcc, g++, make) / Python 3
- **zstd** + **libarchive** (提供 `bsdtar`，用于打 pacman 包；Debian 系为 `zstd` + `libarchive-tools`)
- 构建脚本会在首次运行时自动安装其余依赖（libkrb5-dev、libxkbfile-dev 等）

> 也支持在 WSL2 中运行：进入 WSL2 后照下面的 Linux 流程跑 `build-linux.sh` 即可，首次运行会自动安装同样的依赖。

## 使用方法

### 一键构建

```bash
cd CatPaw-Linux-Build
bash scripts/build-linux.sh
```

脚本会依次完成：提取 DMG → 下载 Electron → 重建原生模块 → 组装应用 → 打包 tar.gz / deb / pacman 三种包。

### 指定架构

```bash
bash scripts/build-linux.sh --arch x64     # 默认，适用于大多数 Linux
bash scripts/build-linux.sh --arch arm64   # ARM64 设备
```

### 跳过已完成的步骤

```bash
# 跳过 DMG 提取（使用已提取的资源）
bash scripts/build-linux.sh --skip-extract

# 跳过 Electron 下载（使用已下载的）
bash scripts/build-linux.sh --skip-download
```

### 单独生成 Arch pacman 包

`build-linux.sh` 默认已经产出 pacman 包。如果只有 tar.gz 想转成 pacman 包，可单独调用：

```bash
bash scripts/make-arch-pkg.sh scripts/out/CatPawAI-linux-x64-2026.2.3.tar.gz scripts/out/
```

也可直接传入已解压的 stage 目录：

```bash
bash scripts/make-arch-pkg.sh /path/to/stage scripts/out/
```

## 输出

构建产物位于 `scripts/out/`：

| 文件 | 说明 |
|------|------|
| `CatPawAI-linux-x64-2026.2.3.tar.gz` | 便携版，解压即用 |
| `CatPawAI-linux-x64-2026.2.3.deb` | Debian/Ubuntu 安装包 |
| `catpawai-2026.2.3-1-x86_64.pkg.tar.zst` | Arch Linux pacman 包 |

## 安装

### Arch Linux (pacman)

```bash
sudo pacman -U catpawai-2026.2.3-1-x86_64.pkg.tar.zst

# 运行（从应用菜单或终端）
catpawai
```

pacman 包会安装到 `/usr/share/catpawai`，并在 `/usr/bin/catpawai` 创建符号链接到启动脚本。启动脚本会解析 symlink 自身位置，因此从 PATH 调用也能正确找到 Electron 二进制。

### tar.gz 方式

```bash
# 解压到 /opt
sudo tar xzf CatPawAI-linux-x64-2026.2.3.tar.gz -C /opt/

# 创建快捷方式
sudo ln -sf /opt/CatPawAI-linux-x64/bin/catpawai /usr/local/bin/catpawai

# 运行
catpawai
```

### deb 方式

```bash
sudo dpkg -i CatPawAI-linux-x64-2026.2.3.deb

# 运行（从应用菜单或终端）
catpawai
```

> 三种安装方式都不需要 `--no-sandbox` 参数——启动脚本会自动加上。
> 如果 Linux 上 `chrome-sandbox` 没有 setuid 权限，脚本会改用 `ELECTRON_DISABLE_SANDBOX=1`。

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

此外，`mt-idekit.mt-idekit-code` 扩展内置了一个预编译的 `sqlite3` 原生模块（`out/build/Release/node_sqlite3.node`），用于聊天历史记录服务。该文件在 macOS DMG 中是 Mach-O 格式，构建脚本 Phase 4f 会自动检测并替换为 Linux ELF 版本（基于 N-API，ABI 稳定，兼容 Electron）。

以下 Windows/macOS 专用模块会被移除：

- `@vscode/windows-mutex`
- `@vscode/windows-process-tree`
- `@vscode/windows-registry`
- `windows-foreground-love`

> 注：`@vscode/deviceid` 不再移除——它是纯 JS 模块，显式支持 Linux，`main.js` 启动时会动态导入它获取设备 ID。

## 目录结构

```
CatPaw-Linux-Build/
├── package.json           # 构建项目配置
├── README.md              # 本文档
├── resources/             # 构建资源
│   └── catpawai.png       # 应用图标 (可选)
└── scripts/
    ├── build-linux.sh     # 主构建脚本 (Linux 原生 / WSL2)
    ├── make-arch-pkg.sh   # 重新打包为 Arch pacman 包
    ├── discover-dmg-url.sh # 自动发现最新 DMG 下载地址
    ├── extracted/         # DMG 提取结果 (自动生成)
    ├── downloads/         # Electron 下载缓存 (自动生成)
    ├── build/             # 构建中间产物 (自动生成)
    └── out/               # 最终输出 (自动生成)
```

## 输入法 (IME) 支持

启动器自动处理 CJK 输入法（中文、日文、韩文）：

- **Wayland**：自动添加 `--enable-wayland-ime` 启用 Wayland text-input-v3 协议，fcitx5 / ibus 可正常连接输入框。设置 `CATPAWAI_DISABLE_WAYLAND_IME=1` 可关闭。
- **X11**：自动检测 fcitx5 / ibus 进程，若 `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS` 未设置则自动补齐。

> 这是 Electron on Wayland 经典的「打不出中文」问题的修复——不加 `--enable-wayland-ime`，Chromium 不会激活 text-input-v3 协议，输入法无法连接到编辑器输入框。

## 已知限制

- `chrome-sandbox` 需要 setuid 才能用，否则启动脚本会自动切换到 `ELECTRON_DISABLE_SANDBOX=1`
- SSO 登录功能可能需要额外的网络配置
- 部分依赖 macOS 特有 API 的扩展可能无法正常工作
- 自动更新功能在 Linux 上不可用

## Auto-Run 补丁 (Phase 5h)

CatPaw Agent 的 Auto-Run 功能在执行终端命令前会调用 `shouldAskApprovalForCommand()` 判断是否需要用户手动确认。除了用户可配置的 `commandAllowlist` / `commandDenylist` 外，还有一个 **硬编码的 `OFFICIAL_DENY_LIST`**：

```
rm, rmdir, mv, kill, shutdown, reboot,
pip uninstall, npm uninstall, strace, make clean,
dd, chmod 777, chown, su, sudo
```

这些命令即使开启了 Auto-Run 也必须手动确认，无法通过 UI 绕过。

构建脚本 Phase 5h 会在移植阶段自动 patch 这两个 `shouldAskApprovalForCommand` 函数，使其直接返回 `false`（永不询问），从而让所有命令（包括 `OFFICIAL_DENY_LIST` 中的）都能自动执行。由于整个函数体被替换，`commandDenylist`、`deleteFileProtection` 等所有检查均被跳过——即 **所有命令无条件自动执行**。

> **注意**：此补丁仅修改构建产物中的 minified JS，不修改原始 DMG 中的文件。如果 CatPaw 版本更新导致 minified 函数签名变化，patch 会打印 WARN 但不会中断构建。

## 自动重试补丁 (Phase 5i)

CatPaw Agent 的流式接口在网络中断时会抛出 `TypeError("network error")`，触发 `StreamNetWorkError` 错误。正常模式下，错误显示后等待用户手动点击"继续对话"或"重试对话"。

CatPaw 内部有一个 `evaluationModeEnabled` 状态（评测模式），开启后会在流式错误时 **自动重试，最多 3 次，间隔 3 秒**。但此模式仅对 TestAgent（单测生成）场景自动激活，正常对话无法通过 UI 开启。

构建脚本 Phase 5i 会 patch hook 函数中的 `useState(!1)` 初始化，将 `evaluationModeEnabled` 的默认值从 `false` 改为 `true`，使所有对话都获得自动重试能力。

patch 通过以下步骤精确定位（不依赖 minified 变量名）：
1. 从 hook 返回对象中提取 `evaluationModeEnabled:VAR` 的变量名
2. 用正则匹配 `[VAR,X]=(0,r.useState)(!1),SETTER=(0,r.useCallback)(e=>{X(e)},[])`
3. 将 `!1`（false）替换为 `!0`（true）

| 效果 | 说明 |
|---|---|
| 自动重试 | 流式网络错误后自动重试 3 次，间隔 3 秒 |
| 加载状态 | 重试期间 UI 保持加载状态，不显示错误 |
| 工具审批跳过 | 与 Phase 5h 冗余（已通过 Auto-Run patch 处理） |

## 技术细节

- **Electron**: 35.5.1
- **VS Code 基础版本**: 1.101.0
- **CatPaw 版本**: 2026.2.3
- **Bundle ID**: com.catpaw.ide
- **应用代码位置**: `Contents/Resources/app/` (非 asar 打包)
- **原生模块**: 通过 `@electron/rebuild` + `npm install` 重新编译
