<p align="center">
  <img src="Resources/Assets.xcassets/LaunchIconBrand.imageset/Brand-Light@2x.png" width="112" alt="LaunchIcon">
</p>

<h1 align="center">LaunchIcon</h1>

<p align="center">
  <strong>Lightweight macOS app launcher</strong> — grid, folders, search, local layout.<br>
  把常用 App 放回熟悉的位置。为 macOS 制作的轻量启动器。
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="Apache-2.0"></a>
  <a href="https://github.com/sunzhengnj/LaunchIcon-OSS/releases"><img src="https://img.shields.io/github/v/release/sunzhengnj/LaunchIcon-OSS?include_prereleases&label=release" alt="GitHub release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-AppKit-orange" alt="Swift AppKit">
</p>

<p align="center">
  <a href="https://github.com/sunzhengnj/LaunchIcon-OSS/releases/tag/v1.0.0">Download</a> ·
  <a href="#功能">Features</a> ·
  <a href="#从源码构建">Build</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="LICENSE">License</a>
</p>

## 状态

本仓库以 **1.0.0** 里程碑开源（Apache-2.0）。源码来自维护者确认较稳的一版；**安装包仍为 ad-hoc 签名、尚未 Developer ID / 公证**。

已知限制（详见 [Docs/RELEASE_NOTES_1.0.0.md](Docs/RELEASE_NOTES_1.0.0.md)）：

- 扫描不完整时，点击「使用上次应用列表」可能无效
- 完整 UI 自动化套件尚未全绿（此前记录约 47 通过 / 5 失败 / 2 跳过）；打包时 Core **128/128** 与后台质量门通过
- 实体输入、VoiceOver、Store 沙箱等场景仍在验证中

日常开发在维护者私有仓继续；公开仓按里程碑同步，见 [Docs/SYNC_FROM_PRIVATE.md](Docs/SYNC_FROM_PRIVATE.md)。

## 功能

| 浏览 | 整理 | 快速找到 |
| --- | --- | --- |
| 7 × 5 应用网格、分页与键盘翻页 | 拖拽排序、创建和重命名文件夹 | 应用名 / 别名支持汉字、拼音全拼与首字母搜索* |
| 系统应用优先出现在新布局首页 | 整理结果保存在本机，重启后继续使用 | 默认 `⌥ Space` 快捷键，也可从菜单栏打开 |

LaunchIcon **借鉴** macOS 启动器一类产品的有用交互，但使用**自己的视觉与交互语言**：不读取系统 Launchpad 数据库，也不复制其他产品的商标或资源。应用清单、别名和布局默认保存在本机，不提供账号或云同步。

\*拼音转写由 Foundation 提供，多音字遵循系统默认结果。

文件夹打开 / 关闭有轻微展开与收拢过渡；系统或应用内「减少动态效果」开启时改为短淡入淡出。

## 安装

1. 打开 [Releases · v1.0.0](https://github.com/sunzhengnj/LaunchIcon-OSS/releases/tag/v1.0.0)，下载 `LaunchIcon-v1.0.0-macOS-unnotarized.dmg`，可用同页 `.sha256` 核对完整性。
2. 打开 DMG，将 `LaunchIcon.app` 拖入「应用程序」。若已有旧版，先退出再替换；布局与偏好在用户目录，不随 App 覆盖。
3. 启动 LaunchIcon（默认后台就绪），按 `⌥ Space` 或点击菜单栏图标呼出。

### 关于 macOS 安全提示

此安装包为 **ad-hoc 签名**，**没有 Developer ID 签名或 Apple 公证**，首次打开可能被系统阻止。仅在确认文件来自本仓库 Release 且你信任该来源时，再到「系统设置 → 隐私与安全性」选择「仍要打开」。不要关闭 Gatekeeper，也不要运行来源不明的解除隔离命令。参见 [Apple 的安全说明](https://support.apple.com/102445)。

读取已安装 App 版本：

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/LaunchIcon.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/LaunchIcon.app/Contents/Info.plist
```

## 从源码构建

需要 **macOS 26+**、**Xcode 27** 与对应 SDK。克隆后先跑不打开窗口的质量门：

```bash
./script/validate_background.sh
```

该脚本运行网络静态检查、Core 测试、Direct / StoreSpike Release `analyze`，以及 UI 测试目标 `build-for-testing`。**它不会启动 LaunchIcon 或 UI Runner，也不能用来宣称完整 UI 通过。**

真实窗口验证只应在桌面主人明确同意的时段运行：

```bash
LAUNCHICON_ALLOW_VISIBLE_TESTS=1 ./script/test_direct_bootstrap.sh
```

在 Xcode 中打开 `LaunchIcon.xcodeproj`。`DEVELOPMENT_TEAM` 已留空，请填入你自己的 Apple Team。打包预览 DMG 可用 `./script/package_preview.sh`；正式签名 / 公证入口为 `./script/distribution_preflight.sh`（需要你自己的证书与 notary 配置，**切勿把凭据写进仓库**）。

## 架构概览

| 目标 | 作用 |
| --- | --- |
| **Core** | 共享模型：扫描、布局、搜索、文件夹逻辑；可单测 |
| **Direct** | 直接分发渠道的 AppKit 壳 |
| **StoreSpike** | 沙箱可行性探测，**不是** App Store 正式版 |

主线程只做 UI；扫描、图标与布局 I/O 必须可取消、可测试。渠道差异留在 target 配置、entitlements 与 Platform adapter。

更多产品范围见 [Docs/LaunchIcon_PRD.md](Docs/LaunchIcon_PRD.md)，测试证据见 [Docs/TEST_MATRIX.md](Docs/TEST_MATRIX.md)。

## 参与贡献

欢迎 Issue 与 Pull Request。请先阅读：

- [CONTRIBUTING.md](CONTRIBUTING.md) — 环境、验证门、PR 规则
- [AGENTS.md](AGENTS.md) — **给 AI / 编程助手的开发流程**（请先读再改代码）
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

反馈问题时使用 [bug report 表单](https://github.com/sunzhengnj/LaunchIcon-OSS/issues/new?template=bug_report.yml)。分享日志前请脱敏，不要上传完整布局或偏好文件。

## 许可证与商标

源码以 [Apache License 2.0](LICENSE) 授权，参见 [NOTICE](NOTICE)。

**LaunchIcon** 名称与品牌图样仍为项目标识。许可证覆盖代码与文档的使用 / 再分发条件，**不**自动授予商标使用权。请勿将本项目表述为 Apple Launchpad 的克隆，也请勿复制其他启动器产品的 UI 或资源。
