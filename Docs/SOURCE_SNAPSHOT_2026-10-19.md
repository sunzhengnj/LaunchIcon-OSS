# preview.82 public source snapshot (WIP) / 公开源码快照

This public snapshot contains LaunchIcon 1.0.0 build 82 product source, resources, tests, and build scripts from the private development milestone. The maintainer signing Team ID is removed. Public history, Apache-2.0/NOTICE, community documents, bilingual README, and existing demo media remain intact. Internal task, handoff, review, user-layout, credential, and local-capture files are excluded.

本次公开同步 1.0.0 build 82 的产品源码、资源、测试和构建脚本，移除维护者签名 Team ID，保留公开仓历史、许可证、社区文档、双语首页与既有演示。内部任务、交接、审阅、用户布局、凭据与本地截图不公开。

Since preview.78: settings sections and keyboard behavior, multi-select organization, layout sort/export/import/restore, optional hot-corner invocation, search/folder result polish, app uninstall safeguards, and broader Reduce Motion snapping. Paging geometry/direction/timing has been revised. These changes correspond to the existing P0-3/P0-4/M3 work and recorded paging and polish bugs.

相对 preview.78：设置分区及键盘行为、多选整理、布局重排/导出/导入/恢复、可选热角呼出、搜索与文件夹结果抛光、卸载保护、更完整的“减少动态效果”即时落位；分页几何、方向和时间曲线也已调整。热角可能与 macOS Mission Control 等系统热角冲突，可在设置中关闭。

**Validation boundary / 验证边界:** The public checkout's background gate is recorded in [TEST_MATRIX](TEST_MATRIX.md). The source sync and installer do not establish a full UI suite, continuous physical-input paging feel, Store distribution, Developer ID signing, or notarization pass. The public package is an ad-hoc signed, unnotarized WIP preview, built from its public source commit. No private build artifact is reused.
