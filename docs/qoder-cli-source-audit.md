# Qoder CLI 官方软件源调查报告

调查日期：2026-11-25。仅查阅 Qoder 官方网站、官方文档和官方安装源；未使用第三方 Bucket。官方安装脚本以源码方式下载检查，未执行。

## 结论

存在可用于 Scoop 的官方原生 Windows 包：版本化 ZIP 内只有 `qodercli.exe`，官方 channel 同时提供 URL 和 SHA256。当前 channel 版本为 `1.1.98`。可以安全地将版本化 ZIP 作为 Scoop 下载对象，并对下载内容独立校验。

## 证据与发现

| 项目 | 调查结果 |
|---|---|
| 产品类型 | 官方文档称安装脚本安装 native standalone executable；CLI 安装说明列出 Windows。 |
| Windows x64 | 官方安装要求列出 `amd64`，Windows 安装文档要求 x86_64；支持。 |
| Windows ARM64 | 安装脚本当前读取到 ARM64 原生候选，channel 当前也发布 `windows/arm64` ZIP；但 CLI 安装文档和排错文档仍写着 Windows ARM64 当前不支持。此处上游信息相互矛盾，Bucket 暂只启用文档明确支持的 x64。 |
| 安装脚本源 | `https://qoder.com/install.ps1` 当前脚本使用 `https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli` 作为基础地址。 |
| 版本接口 | `.../qodercli/channels/manifest.json` 返回 `latest`、发布时间、不同平台的文件 URL 和 SHA256；指定版本接口为 `.../channels/<version>/manifest.json`。 |
| 下载地址 | 版本化地址形如 `https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/releases/<version>/qodercli-windows-x64.zip`。对当前版本 HEAD 返回 HTTP 200，长度 111,228,104 bytes。 |
| 完整性 | 官方 channel 提供 SHA256；更新脚本另外对下载 ZIP 计算 SHA256 并逐字比较。当前 `1.1.98` x64 hash 为 `d1f84e1eed17b215e8aa3c0cc59e0764522f2b8a81e3266e2710ce2ece6979e6`，与下载文件实测一致。未在官方来源中发现独立签名或签名文件。 |
| ZIP 布局 | 当前 ZIP 实测只包含 `qodercli.exe`（242,082,800 bytes）。 |
| 安装行为 | 官方脚本获取 channel、按架构选择包、下载并校验 SHA256、解压后执行 `qodercli.exe install --force`。本 Bucket 不执行该脚本，而是让 Scoop 管理 ZIP 中的可执行文件并创建 `qoder` shim；该生命周期由隔离 Windows CI 验证。 |
| 更新 | 官方文档提供 `qoder update`；安装脚本也能升级。自动升级默认开启。官方支持在用户 `settings.json` 中设置 `general.enableAutoUpdate: false` 关闭；默认文件为 `~/.qoder/settings.json`。官方也明确支持用 `QODER_CONFIG_DIR` 覆盖用户配置目录，因此隔离测试可把该变量指向临时目录，并在其中写入关闭自动更新的设置。参见 [配置项参考](https://docs.qoder.com/cli/settings-reference)、[配置文件位置与优先级](https://docs.qoder.com/cli/settings) 和 [安装与升级说明](https://docs.qoder.com/cli/installation)。 |
| 卸载 | 官方文档对脚本安装的卸载说明是删除脚本放置的可执行文件并移除其 PATH 项。Scoop 管理文件和 shim；卸载不清理 `~/.qoder` 配置/会话数据。 |
| 静默安装器 | 没有传统 GUI 安装器；官方脚本有 `--version` 参数且最终调用二进制 `install --force`。Scoop 不调用安装器流程。 |
| 许可证 | CLI 是 Qoder 专有产品，使用受官方服务条款约束；Manifest 标为 `Proprietary`。 |

## 官方参考

- [Qoder CLI Installation and Upgrade](https://docs.qoder.com/cli/installation)
- [Qoder CLI Installation and Upgrade Issues](https://docs.qoder.com/cli/troubleshoot-install)
- [Qoder CLI commands](https://docs.qoder.com/cli/cli-reference)
- [Qoder CLI settings reference](https://docs.qoder.com/cli/settings-reference)
- [Windows Installation Guide](https://docs.qoder.com/qoder/install-windows)
- [Qoder official installer source](https://qoder.com/install.ps1)
- [Qoder official release channel](https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/channels/manifest.json)

## 限制

上游没有发现签名文件或签名校验流程，因此更新信任链仍依赖 Qoder 官方 HTTPS channel 对应的 SHA256 元数据。ARM64 文档与实际发布产物不一致，需等 Qoder 官方澄清后再纳入。Actions 工作流需要在仓库默认分支启用；自动 PR 还要求仓库允许 `GITHUB_TOKEN` 创建 PR。

## 测试隔离与 TEMP 缓存

`scripts/test-scoop.ps1` 将 Scoop 根目录、Bucket、下载缓存和 Qoder 用户配置放在唯一临时测试根目录中；清理逻辑只删除该精确测试根目录。Qoder 运行时还可能在 Windows TEMP 下生成 `qodercli-natives-*` 依赖缓存，该目录位于 Scoop 测试根目录之外。脚本不使用通配符清理该缓存，并将结果报告为 `CLEANUP=PARTIAL`，而不是声称整个 TEMP 已清理。GitHub 工作流使用 GitHub-hosted runner；每个 Job 使用新 VM，Job 完成后 VM 自动回收，参见 [GitHub-hosted runner 生命周期说明](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners)。

以上 Qoder 配置目录和自动更新设置依据 Qoder 官方文档确认；测试脚本已按此写入临时配置，但 CLI 对该隔离设置的运行时遵从情况仍需由 GitHub Windows 生命周期工作流验证。
