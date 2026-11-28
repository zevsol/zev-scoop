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
| [Qoder CN CLI](docs/packages/qoder-cn-cli.md) (`qoder-cn-cli`) | AI / CLI | Windows x64 | Implemented；本地与 GitHub-hosted Windows x64 生命周期测试通过 |
| [Antigravity CLI](docs/packages/antigravity-cli.md) (`antigravity-cli`) | AI / CLI | Windows x64 / ARM64 | Implemented；本地与 GitHub-hosted Windows x64 生命周期测试通过；ARM64 仅核实元数据/URL |
| [Antigravity IDE (Standalone)](docs/packages/antigravity-ide.md) (`antigravity-ide`) | AI / Desktop | Windows x64 / ARM64 | Implemented（`innosetup: true` 解包）；GitHub-hosted Windows x64 生命周期测试通过；ARM64 仅核实元数据/签名 |
| Qoder IDE (`qoder-ide`) | AI / Desktop | Windows | Planned，尚未调查 |
| Codex CLI (`codex-cli`) | AI / CLI | Windows | Planned，尚未调查 |
| Gemini CLI (`gemini-cli`) | AI / CLI | Windows | Planned，尚未调查 |

目录中的 Planned 项目仅用于展示方向，并不代表已有 Manifest 或安装支持。Antigravity IDE Standalone 采用 Scoop 的 `innosetup: true`（`extract_dir: "{code_GetDestDir}"`）由 `innounp` 直接解包应用文件，不执行官方安装器 UI 及注册表副作用；使用前建议先安装 `innounp`（`scoop install innounp`），并在 IDE 设置中将 `update.mode` 设为 `none`。各包的证据和限制见对应包文档。

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
scoop install innounp zev/antigravity-ide
```

更新或卸载：

```powershell
scoop update
scoop update qoder-cli
scoop update qoder-cn-cli
scoop update antigravity-cli
scoop update antigravity-ide
scoop uninstall qoder-cli
scoop uninstall qoder-cn-cli
scoop uninstall antigravity-cli
scoop uninstall antigravity-ide
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

**已实现：**Qoder CLI、Qoder CN CLI、Antigravity CLI 和 Antigravity IDE 各自独立的官方版本检测/校验适配器、Manifest 更新及 Windows runner 生命周期测试入口。更新工作流只在候选包校验和安装测试通过后创建 PR，保留人工审核，不自动合并。

**当前适用范围：**版本发现和 Manifest 更新代码按软件包分别实现；这些适配器不是可供任意软件直接使用的通用更新引擎。桌面应用的安装/卸载方式须逐包核实；Antigravity IDE Standalone 使用 Scoop 的 `innosetup` + `extract_dir` 解包策略绕过安装器副作用。

**验证状态：**`qoder-cli`（Run `46002830105`）、`qoder-cn-cli`、`antigravity-cli` 和 `antigravity-ide`（Run `46002829984`）均已通过 GitHub-hosted Windows x64 生命周期 CI；ARM64 架构目前仅完成官方元数据、URL 与校验和/签名核实，尚未在 ARM64 Runner 实机运行；真实升级测试在版本变更时触发。各包的证据和限制见对应包文档。

## 仓库结构

```text
bucket/                  Scoop manifests
scripts/                 版本维护、Manifest 检查及 Windows 测试脚本
tests/                   Python 本地测试
docs/packages/           单个软件包的使用与实现说明
docs/                    来源调查和维护设计文档
.github/workflows/       校验、版本更新和 Windows 测试工作流
AGENTS.md                AI 代理协作与分支/PR 硬性规范
```

## 参与维护

所有手动修改与自动更新均应基于独立分支向默认分支 `main` 提交 Pull Request，待 CI 校验通过后再人工审核合并，禁止直接向 `main` 推送。新增软件时，先核实官方分发渠道、架构、版本接口、哈希/签名、许可及完整安装卸载行为，再添加 Manifest 和适配测试。按类别的调查清单、分支/PR 规范及本地命令见 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [AGENTS.md](AGENTS.md)。
