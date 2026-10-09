# 预览版发布流程

目标：每个验收通过的阶段提供新的 GitHub Release 安装包；预览版与正式公证发布分开标记。

## 版本与门槛

- `MARKETING_VERSION` 是 `主.次.修订`，`CURRENT_PROJECT_VERSION` 是递增的数字构建号；预览标签为 `v<MARKETING_VERSION>-preview.<CURRENT_PROJECT_VERSION>`。
- 用户要求的 `v1.0.0` 在验收门槛未齐时仅作为 GitHub prerelease/WIP 使用；包名必须标明 `unnotarized`，发布说明不得称为正式稳定版。
- 每次发布前确认 `Docs/DAILY_REVIEW.md`、`TASKS.md`、`HANDOFF.md`、`Docs/TEST_MATRIX.md` 中本阶段证据一致。测试、Release 构建、真机 UI、沙箱和发布验证分别记录；任一门槛未过时不得称为正式版本。
- 本机没有 Developer ID Application 证书时，只能创建明确标为 **unnotarized preview** 的包。不得把 Apple Development 或 ad-hoc 签名写成已公证。
- 公开仓库、选择许可证或启用自动更新均是独立决定，不由打包脚本改变。

## 每个阶段的操作

1. 在 Xcode 项目的 Direct Debug/Release 配置同时更新版本与构建号，README 区分已发布版与开发候选，并提交待发布源码；**未创建 Release 前不要把下载链接指向候选包**。打包只接受干净工作区。不要复用已有预览标签或构建号。
2. 先运行 `./script/validate_background.sh`，它只做 Core、Direct/Store Release 静态分析和 UI 目标编译，不启动 App 或 Runner。Direct bootstrap 会启动 App，应在用户允许的时段以 `LAUNCHICON_ALLOW_VISIBLE_TESTS=1 ./script/test_direct_bootstrap.sh` 运行。用户目前已允许后续持续可见测试，不必逐次询问；遇到新的系统敏感权限提示仍须按具体提示处理，不把未完成的授权当成测试通过。检查 Release 构建、签名、实际启动和隔离布局；记录仍未覆盖的验收项。
   - GitHub Actions 的 `macOS validation` 工作流可从 Actions 页面手动触发；它运行 `check_no_network_apis.sh`、Core、Direct/Store Release 静态分析和 UI target `build-for-testing`，不启动 UI Runner，不验证 Apple Developer ID 签名、公证或真实 UI。静态网络 API denylist 不等同于运行时零出站证明。当前仓库私有，因此没有 push/PR 自动触发。
3. 用 `./script/package_preview.sh <输出目录>` 从该提交构建 ad-hoc 预览 DMG。脚本把完整 Git SHA 写入 App 的 `LaunchIconSourceCommit`，并核对生成的 `Info.plist`；还会生成同名 `.sha256` 文件、严格验签并校验 DMG。随后运行 `./script/verify_preview_package.sh <本地DMG> <打包源码提交号>`，确认包内源码号、版本、SHA-256、签名、双架构，并拒绝产品源码、资源、Xcode 工程或打包脚本与当前工作区不一致的旧包；仅测试和文档提交不使包过期。常规阶段还须在隔离目录从 DMG 复制 App 并实际启动一次；校验命令不替代冷启动。
4. 推送该源码提交，再在**同一提交**创建同名 Git 标签和 GitHub **prerelease**，上传本地校验通过的同一份 DMG 与 `.sha256`，在 Release notes 写变更、对应提交、系统要求、签名状态和已知限制。若用户要求完全静默、冷启动无法保证不弹窗，可仅作为明确的 **WIP 试用包**发布：Release notes、README 和交接记录必须注明未冷启动、未完成 UI 验收；不得称此阶段为已验收或把静态包校验当作可启动证明。打包后的验证记录可在后续文档提交补充，不改变标签所指向的源码提交。
5. 从 Release 页面重新下载 DMG 与 `.sha256` 到独立目录，先 `git fetch origin tag <预览标签>`，再运行 `./script/verify_preview_package.sh <本地已验证DMG> <预览标签> <回下载DMG>`。此命令要求标签提交、包内 `LaunchIconSourceCommit`、App 版本与包名一致，且回下载的两个附件与本地逐字节相同；任何不一致都停止发布验收。通过后才将 README 下载链接改为新 Release，并注明包内源码提交。安装后仍可用 `/usr/libexec/PlistBuddy -c 'Print :LaunchIconSourceCommit' /Applications/LaunchIcon.app/Contents/Info.plist` 核对。不要将未公证的预览版标为稳定版或 1.0。

取得 Developer ID Application 和公证凭据后，应改用 `script/distribution_preflight.sh --archive-and-notarize` 的正式路径，并通过 `--verify`、干净环境安装及所有 1.0 门槛，再另定稳定版发布流程。
