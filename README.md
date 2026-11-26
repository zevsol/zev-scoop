# Zev Scoop

**Zev Scoop 是一个个人维护的 Windows 软件 Bucket（Personal Windows Software Bucket）。**它通过 Scoop Manifest 管理软件的安装、升级、版本和卸载。Qoder CLI 是当前首个接入的软件包。

## 项目目标

把常用的开发与效率软件维护在一个可审查、可重复安装的个人软件仓库中。每个 Manifest 描述官方来源、架构、下载校验和及 Scoop 生命周期行为；版本变化通过自动检查和 Pull Request 审核。

长期计划覆盖 AI 命令行与桌面应用、开发工具、运行时和 Windows 实用工具。是否纳入一个软件，取决于它是否有可核实的官方分发来源及可维护的安装、更新和卸载流程。

Scoop 将应用安装到用户目录并通过 shim 管理命令，便于不依赖传统系统级安装器地安装和更新软件。具体行为仍由每个软件的 Manifest 决定。

## 软件目录

| Package | Category | Platform | Status |
|---|---|---|---|
| [Qoder CLI](docs/packages/qoder-cli.md) (`qoder-cli`) | AI / CLI | Windows x64 | Manifest 已实现；本地验证和 GitHub 安装生命周期验证通过 |
| Qoder IDE (`qoder-ide`) | AI / Desktop | Windows | Planned，尚未调查 |
| Codex CLI (`codex-cli`) | AI / CLI | Windows | Planned，尚未调查 |
| Gemini CLI (`gemini-cli`) | AI / CLI | Windows | Planned，尚未调查 |

目录中的 Planned 项目仅用于展示方向，并不代表已有 Manifest 或安装支持。

## 快速开始

先安装 [Scoop](https://scoop.sh/)，再添加 Bucket：

```powershell
scoop bucket add zev https://github.com/zevsol/zev-scoop
```

安装当前实现的软件：

```powershell
scoop install zev/qoder-cli
```

更新或卸载：

```powershell
scoop update
scoop update qoder-cli
scoop uninstall qoder-cli
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

**已实现：**Qoder CLI 的官方版本检测、下载与 SHA256 校验、Manifest 更新、格式/规则验证，以及隔离 Windows runner 上的生命周期测试入口。更新工作流只有在候选版本和测试通过后才创建 PR，保留人工审核，不自动合并。

**当前适用范围：**版本发现和 Manifest 更新代码是 Qoder CLI 专用适配器，不是可供任意软件直接使用的通用更新引擎。其他软件将根据各自官方发布机制增加独立适配逻辑；共用的通用框架尚未实现。

**验证状态：**本地 Manifest、官方 x64 下载及 SHA256 已验证；PowerShell 5.1/7.7 下 JSON（18 项）、Junction 清理和环境隔离测试通过。最新 GitHub Actions 中 Validate bucket manifests 与 Windows 当前版本生命周期测试均通过，覆盖安装、SHA256、命令、Shim 路径和卸载；因无不同历史版本，升级测试跳过。隔离 Scoop 根目录已清理；Qoder 可能在 Runner TEMP 外创建的原生依赖缓存未单独清理，Job 使用的 GitHub-hosted Runner 会在任务结束后回收。详见 [Qoder CLI 包说明](docs/packages/qoder-cli.md) 和 [来源调查报告](docs/qoder-cli-source-audit.md)。

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
