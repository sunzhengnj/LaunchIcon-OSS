# LaunchIcon 1.0.0

- 标签：`v1.0.0`
- 要求 macOS 26 或更新，支持 Apple Silicon 与 Intel
- 默认呼出快捷键：**Option＋空格（⌥ Space）**。安装后须先启动 LaunchIcon；它默认在后台运行
- 包含网格、文件夹、搜索（汉字 / 拼音）、分页、拖拽整理，以及跨页拖拽时悬停左右箭头翻页等能力

## 验证与已知限制

- 打包时 **Core 128/128**、Direct/Store Release `analyze`、UI 测试目标编译与网络静态检查已通过
- **完整 UI 套件尚未全绿**：此前记录为 47 通过 / 5 失败 / 2 跳过。已知问题包括：扫描不完整时点击「使用上次应用列表」可能无效果；全角输入相关 XCTest 合成可能超时
- 安装包为 **ad-hoc 签名**，**没有 Developer ID 签名或 Apple 公证**。仅在信任本仓库 Release 来源时安装；首次打开若被 macOS 阻止，请在「系统设置 → 隐私与安全性」中选择「仍要打开」
- 实体输入、VoiceOver、Store 沙箱与部分边界场景仍待继续验证

本公开仓以 1.0.0 里程碑源码开源；后续功能由维护者在里程碑时同步，见 [Docs/SYNC_FROM_PRIVATE.md](SYNC_FROM_PRIVATE.md)。
