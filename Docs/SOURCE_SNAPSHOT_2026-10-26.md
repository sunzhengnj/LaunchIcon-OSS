# preview.84 public source snapshot (WIP) / 公开源码快照

This public snapshot contains LaunchIcon 1.0.0 build 84 product source, resources, tests, and build scripts from the private development milestone (`a6caf34`). The maintainer signing Team ID is removed. Public history, Apache-2.0/NOTICE, community documents, bilingual README, and existing demo media remain intact. Internal task, handoff, review, user-layout, credential, and local-capture files are excluded.

本次公开同步 1.0.0 build 84 的产品源码、资源、测试和构建脚本（私有 tip `a6caf34`），移除维护者签名 Team ID，保留公开仓历史、许可证、社区文档、双语首页与既有演示。内部任务、交接、审阅、用户布局、凭据与本地截图不公开。

Since preview.82: denser Settings Form, menu-bar click gestures and optional F4 summon, folder date sort and Page Up/Down list scroll, in-grid arrow walk (no paging rewrite), Dock drag file links, grid geometry preferences (persisted, not yet wired into Direct paging), custom app-root limits, and related AX/copy polish.

相对 preview.82：更密的设置 Form、菜单栏点击与可选 F4 呼出、文件夹按时间排与 Page 键滚列表、格内方向键走动（不重写翻页）、Dock 拖出文件链接、网格行列偏好（已落盘，尚未接入 Direct 翻页）、自定义应用目录上限，以及相关 AX/文案抛光。

**Validation boundary / 验证边界:** The public checkout's background gate is recorded in [TEST_MATRIX](TEST_MATRIX.md). The source sync and installer do not establish a full UI suite, continuous physical-input paging feel, Store distribution, Developer ID signing, or notarization pass. The public package is an ad-hoc signed, unnotarized WIP preview, built from its public source commit. No private build artifact is reused.
