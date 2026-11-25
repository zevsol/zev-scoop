# 贡献与软件包维护

Zev Scoop 当前只有 Qoder CLI 一个包。新增软件时，请先完成软件源调查和生命周期设计，再加入 `bucket/<package-name>.json`。不要从第三方 Bucket 复制来源并将其描述为官方来源，也不要仅凭一个可下载 URL 就推断软件可安全安装。

## 所有软件包都要调查

提交 Manifest 前，记录并验证：

1. 官方产品页、下载页、安装文档和使用许可。
2. 官方支持的 Windows 版本及 CPU 架构。
3. 官方安装实际使用的文件和可长期维护的下载 URL。
4. 版本发现机制：官方 API、Feed、发布页或其他可重复查询来源。
5. 官方 SHA256、签名或校验文件；若无独立校验，说明信任边界。
6. 下载包内目录结构、入口程序和运行时依赖。
7. 静默安装参数、升级行为、卸载方式及卸载后的遗留文件。
8. 软件自更新、服务、环境变量、快捷方式、持久化数据和用户配置的影响。
9. 安装失败和升级失败时的退出码与回滚行为。

不得通过 Manifest 执行未经审查的远程安装脚本。对于用户数据和配置，默认保留；除非软件官方卸载流程明确要求且已评估影响，不应主动清理。

## 按类别设计 Manifest 和测试

### CLI

- 确认真实的命令入口、shim 别名和架构专用二进制。
- 用官方的版本及帮助参数验证命令和退出码。
- 调查 CLI 自更新是否会绕过 Scoop 管理。

### GUI Desktop Application

- 确认用户级或系统级安装范围、静默参数、管理员需求及安装器副作用。
- 核对卸载器位置和参数，并验证快捷方式、启动项、服务等变更。
- 不要将普通 GUI 安装器假定为便携软件。

### Portable Application

- 确认解压后的主程序路径及文件完整性。
- 仅在确有需要时添加快捷方式或 `persist`；说明持久化数据在升级/卸载时的行为。
- 检查程序是否将配置或缓存写到应用目录之外。

### Runtime

- 核实官方架构、系统要求和依赖关系。
- 说明并测试 PATH、环境变量、并行版本和全局配置策略。
- 不要在安装时替用户选择或覆盖全局默认版本。

### Developer Tool

- 判断它属于 CLI、桌面应用、服务或多组件软件，再分别设计 Manifest 生命周期。
- 验证工具目录、插件/组件路径、更新器和卸载时对项目数据的影响。
- 将需要下载的依赖全部纳入来源及校验审查。

### Utilities

- 确认是否需要管理员权限，是否修改注册表、系统设置、计划任务或服务。
- 验证这些变更能否由 Scoop 卸载完整撤销；无法安全撤销时，不应伪装成便携安装。

## 命名和目录

Manifest 文件名就是 Scoop 包名，使用简洁、稳定、可区分产品的 kebab-case，例如 `qoder-cli.json`。命令 Shim 可保留软件习惯用法，例如包名 `qoder-cli` 仍可提供 `qoder` 命令。不同产品不应共用含糊的包名。

单包文档放在 `docs/packages/<package-name>.md`。来源调查证据应保留在对应的调查报告中。

## 本地检查

当前 Qoder CLI 维护器可运行：

```powershell
python scripts/update-qoder.py --check
python scripts/update-qoder.py
python scripts/validate-manifest.py --check-url
python -m unittest discover -s tests -v
```

更新器当前只适用于 Qoder CLI。它从 Qoder 官方 channel 发现版本、验证主机与路径、下载并计算 SHA256、检查 ZIP 内容，最后原子更新 `bucket/qoder-cli.json`。不要将它描述为通用更新器。

Windows 生命周期测试入口：

```powershell
./scripts/test-scoop.ps1 -Mode Install
```

该入口由 GitHub-hosted Windows runner 执行；不要在日常 Windows 环境运行，因为它会安装 Scoop 并操作临时测试目录。它安装当前检出版本、检查命令、版本、帮助和文件路径，再卸载并检查清理情况。真实升级测试单独使用不同的历史 Manifest：

```powershell
./scripts/test-scoop.ps1 -Mode Upgrade -PreviousManifestPath <历史Manifest路径>
```

缺少不同的历史版本时，升级测试明确标记为 skipped；同版本重装或更新不算升级测试。GitHub Actions 的 `Test Qoder CLI` 工作流在 PR/Push 上测试当前检出 Manifest，自动尝试取得历史版本；`Update Qoder CLI` 仅在新版本的实际升级测试通过后创建 PR。

## Pull Request

PR 应包含官方来源证据、架构与许可依据、Manifest 变更、哈希验证结果，以及真实执行过的本地/Windows 测试结果。未运行的测试必须标为未运行。不要自动合并更新 PR。

仓库当前实现和目录状态见 [README](README.md)；Qoder CLI 的软件专属细节见 [包说明](docs/packages/qoder-cli.md) 与 [官方来源调查报告](docs/qoder-cli-source-audit.md)。
