<p align="center"><img src="Resources/Assets.xcassets/LaunchIconBrand.imageset/Brand-Light@2x.png" width="112" alt="LaunchIcon four-color icon"></p>

<h1 align="center">LaunchIcon</h1>

<p align="center">把常用 App 放回熟悉的位置。<br><strong>A lightweight, local-first app launcher for macOS.</strong></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-4069c7" alt="Apache-2.0 license"></a>
  <a href="https://github.com/sunzhengnj/LaunchIcon-OSS/releases"><img src="https://img.shields.io/github/v/release/sunzhengnj/LaunchIcon-OSS?label=download" alt="Latest GitHub release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-1d2330" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-AppKit-ee8149" alt="Swift and AppKit">
</p>

<p align="center">
  <a href="https://github.com/sunzhengnj/LaunchIcon-OSS/releases/tag/v1.0.0">下载安装包 / Download</a> ·
  <a href="#功能--features">功能 / Features</a> ·
  <a href="#快速开始--quick-start">快速开始 / Quick start</a> ·
  <a href="CONTRIBUTING.md">参与贡献 / Contribute</a>
</p>

> [!IMPORTANT]
> **源码与安装包版本不同。** `main` 现包含更新的 **WIP 开发源码快照**；[v1.0.0 Release](https://github.com/sunzhengnj/LaunchIcon-OSS/releases/tag/v1.0.0) 仍是较早的安装包，未包含这些源码更新。当前快照尚未完成完整 UI 和实体拖拽验收，也没有对应的新公开安装包。请看[本次源码更新说明](Docs/SOURCE_SNAPSHOT_2026-10-09.md)。
>
> **Source and download differ.** `main` contains a newer work-in-progress source snapshot. The v1.0.0 installer was built from an earlier revision.

## 功能 · Features

| 浏览 Browse | 整理 Organize | 查找 Find |
| :--- | :--- | :--- |
| 7 × 5 网格、分页和键盘翻页 | 拖拽排序、文件夹、重命名 | 应用名、别名、汉字、拼音全拼和首字母搜索 |
| 本机扫描已安装 App | 布局与偏好仅保存在本机 | `⌥ Space` 快捷键与菜单栏入口 |
| 中英双语界面源码 | 隐藏与恢复应用图标 | 遵循“减少动态效果”偏好 |

LaunchIcon 只使用 Apple 公开 API，不读取系统 Launchpad 数据库，也不复制其他产品的商标或资源。没有账号或云同步。The UI follows the system's Chinese or English app language setting; pinyin transliteration uses Foundation's default result.

### 当前源码的更新 · In this source snapshot

- 应用启动等待最长 10 秒后给出提示；启动器打开时默认显示主界面。
- 拖拽到左右边缘可悬停翻页；文件夹不再限制 25 个成员，封面最多显示 3 × 3 图标。
- 合并时的图标过渡从松手位置开始；Direct 界面加入中英文文案。

这些改动仍有待真实窗口与实体输入验证。Dock / 访达的深色模式 App 图标**尚未接入**；普通品牌图片的深色变体不会自动改变 AppIcon。详见[验证与限制](Docs/SOURCE_SNAPSHOT_2026-10-09.md)。

## 快速开始 · Quick start

### 安装已发布版本 · Install the released build

1. 从 [v1.0.0 Release](https://github.com/sunzhengnj/LaunchIcon-OSS/releases/tag/v1.0.0) 下载 `LaunchIcon-v1.0.0-macOS-unnotarized.dmg`，用同页 `.sha256` 文件核对完整性。
2. 打开 DMG，把 `LaunchIcon.app` 拖进“应用程序”。如已有旧版，先退出再替换；布局与偏好不会随 App 覆盖。
3. 该 **v1.0.0 安装包**启动后默认在后台就绪。按 `⌥ Space` 或点击菜单栏图标呼出。当前 `main` 源码的启动行为已更新，见上方版本说明。

此安装包为 **ad-hoc 签名，尚未使用 Developer ID 签名或 Apple 公证**。首次打开若被系统阻止，仅在确认来源并信任本项目后，到“系统设置 → 隐私与安全性”选择“仍要打开”。不要关闭 Gatekeeper 或运行来源不明的解除隔离命令。[Apple 安全说明](https://support.apple.com/102445)。

### 从最新源码构建 · Build from source

需要 macOS 26+、Xcode 27 和相应 SDK。克隆后先运行不打开窗口的质量门：

```bash
./script/validate_background.sh
```

它运行网络 API 静态守卫、Core 测试、Direct / StoreSpike Release `analyze` 和 UI 测试目标 `build-for-testing`。**这不代表完整 UI 测试通过。**在 Xcode 中打开 `LaunchIcon.xcodeproj`，按自己的开发环境配置签名；项目未包含维护者的 Team ID 或证书。

真实窗口测试会占用桌面，仅在使用该电脑的人同意后运行：

```bash
LAUNCHICON_ALLOW_VISIBLE_TESTS=1 ./script/test_direct_bootstrap.sh
```

`LaunchIconStoreSpike` 用于沙箱可行性验证，不是 App Store 正式版。打包预览版可用 `./script/package_preview.sh`；正式签名及公证入口见 `./script/distribution_preflight.sh`。不要将证书、notary profile 或 token 写入仓库。

## 项目结构 · Project structure

| 路径 | 内容 |
| --- | --- |
| `Sources/Core` | 扫描、布局、搜索、文件夹逻辑与持久化 |
| `Sources/Direct` | 直接分发的 AppKit 应用 |
| `Sources/StoreSpike` | Store 沙箱验证原型 |
| `Tests` | Core 与 UI 测试 |
| `Docs` | [产品范围](Docs/LaunchIcon_PRD.md)、[测试矩阵](Docs/TEST_MATRIX.md)、[源码同步规则](Docs/SYNC_FROM_PRIVATE.md) |

日常开发在维护者私有仓进行，公开仓接收经过清理的源码。社区 Issue 与 Pull Request 请提交到本仓。开始贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [AGENTS.md](AGENTS.md)；反馈问题时请提供版本、macOS 版本、芯片和复现步骤，不上传完整布局、偏好或未脱敏日志。

## 许可证与品牌 · License and brand

代码与文档以 [Apache License 2.0](LICENSE) 授权，参见 [NOTICE](NOTICE)。**LaunchIcon** 名称与品牌图样仍是项目标识；Apache-2.0 不自动授予商标使用权。本项目不是 Apple Launchpad 的克隆。
