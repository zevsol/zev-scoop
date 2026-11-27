# Zev Scoop

**Zev Scoop 是一个个人维护的 Windows 软件 Bucket（Personal Windows Software Bucket）。**它通过 Scoop Manifest 管理软件的安装、升级、版本和卸载。Qoder CLI 是当前首个接入的软件包。

## 项目目标

把常用的开发与效率软件维护在一个可审查、可重复安装的个人软件仓库中。每个 Manifest 描述官方来源、架构、下载校验和及 Scoop 生命周期行为；版本变化通过自动检查和 Pull Request 审核。

长期计划覆盖 AI 命令行与桌面应用、开发工具、运行时和 Windows 实用工具。是否纳入一个软件，取决于它是否有可核实的官方分发来源及可维护的安装、更新和卸载流程。

Scoop 将应用安装到用户目录并通过 shim 管理命令，便于不依赖传统系统级安装器地安装和更新软件。具体行为仍由每个软件的 Manifest 决定。

## 软件目录

| Package | Category | Platform | Status |
|---|---|---|---|
| [Qoder CLI](docs/packages/qoder-cli.md) (`qoder-cli`) | AI / CLI | Windows x64 | Implemented；GitHub-hosted Windows 生命周期测试通过 |
| [Qoder CN CLI](docs/packages/qoder-cn-cli.md) (`qoder-cn-cli`) | AI / CLI | Windows x64 | 本地安装、命令、卸载和重装 PASS；GitHub Runner 验收待运行 |
| [Antigravity CLI](docs/packages/antigravity-cli.md) (`antigravity-cli`) | AI / CLI | Windows x64 / ARM64 | 本地 x64 安装、命令、卸载和重装 PASS；ARM64 与 GitHub Runner 验收待验证 |
| [Antigravity IDE (Standalone)](docs/packages/antigravity-ide.md) | AI / Desktop | Windows x64 / ARM64 | BLOCKED；官方安装器已静态核实，但 Scoop 可控的静默、卸载和自更新生命周期尚未验证，未提供 Manifest |
| Qoder IDE (`qoder-ide`) | AI / Desktop | Windows | Planned，尚未调查 |
| Codex CLI (`codex-cli`) | AI / CLI | Windows | Planned，尚未调查 |
| Gemini CLI (`gemini-cli`) | AI / CLI | Windows | Planned，尚未调查 |

目录中的 Planned 项目仅用于展示方向，并不代表已有 Manifest 或安装支持。Antigravity IDE Standalone 的官方安装包和签名已经静态调查；在 Scoop 能可靠控制安装、卸载和自动更新之前不纳入 Bucket。

## 快速开始

先安装 [Scoop](https://scoop.sh/)，再添加 Bucket：

```powershell
scoop bucket add zev https://github.com/zevsol/zev-scoop
```

安装当前已实现的软件包：

```powershell
scoop install zev/qoder-cli
scoop install zev/qoder-cn-cli
scoop install zev/antigravity-cli
```

更新或卸载：

```powershell
scoop update
scoop update qoder-cli
scoop update qoder-cn-cli
scoop update antigravity-cli
scoop uninstall qoder-cli
scoop uninstall qoder-cn-cli
scoop uninstall antigravity-cli
```

## 软件类别

- **CLI Applications**：通常从解压后的命令行程序创建 Scoop shim，并验证命令参数和退出状态。
- **Desktop Applications**：可能需要静默安装/卸载器、快捷方式及应用目录管理。
- **Portable Applications**：通常解压到 Scoop 应用目录，并按需配置快捷方式和持久化数据。
- **Runtimes**：需明确运行时依赖、架构、并行版本及环境变量行为。
- **Developer Tools**：按工具实际的 CLI、GUI 或服务生命周期选择 Manifest 字段。
- **Utilities**：确认是否会修改系统设置、服务或用户数据，再决定是否适合 Scoop 管理。

不同类别使用的 Manifest 字段和测试不同；新增软件前应先完成官方来源调查。

## 自动维护架构

```text
Official Software Sources
        ↓
Version Detection
        ↓
Download & SHA256
        ↓
Manifest Generation
        ↓
Schema Validation
        ↓
Windows Installation Tests
        ↓
GitHub Pull Request
        ↓
Manual Review & Merge
```

**已实现：**Qoder CLI、Qoder CN CLI 和 Antigravity CLI 各自独立的官方版本检测/校验适配器、Manifest 更新及 Windows runner 生命周期测试入口。更新工作流只在候选包校验和安装测试通过后创建 PR，保留人工审核，不自动合并。

**当前适用范围：**版本发现和 Manifest 更新代码按软件包分别实现；这些适配器不是可供任意软件直接使用的通用更新引擎。桌面应用的安装/卸载方式也须逐包核实，Antigravity IDE Standalone 当前未进入 Bucket。

**验证状态：**Qoder CLI 已有本地及 GitHub-hosted Windows 生命周期验证。Qoder CN CLI 已在本地隔离 Scoop 环境完成安装、版本/帮助命令、配置隔离、卸载和重装；Antigravity CLI 已在本地隔离环境完成 x64 安装、版本/帮助命令、配置隔离、卸载和重装。两者的 GitHub-hosted Windows CI 尚未运行。Antigravity IDE Standalone 已做官方安装包静态调查，没有 Manifest，也没有执行安装器。各包的证据和限制见对应包文档。

## 仓库结构

```text
bucket/                  Scoop manifests
scripts/                 版本维护、Manifest 检查及 Windows 测试脚本
tests/                   Python 本地测试
docs/packages/           单个软件包的使用与实现说明
docs/                    来源调查和维护设计文档
.github/workflows/       校验、版本更新和 Windows 测试工作流
```

## 参与维护

新增软件时，先核实官方分发渠道、架构、版本接口、哈希/签名、许可及完整安装卸载行为，再添加 Manifest 和适配测试。按类别的调查清单及本地命令见 [CONTRIBUTING.md](CONTRIBUTING.md)。
