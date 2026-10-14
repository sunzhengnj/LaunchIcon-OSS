# preview.78 source sync (WIP) / 源码同步

This reviewed public snapshot matches the product source for preview.78 (App 1.0.0, build 78), with the maintainer signing Team ID removed. It retains the public repository history, Apache-2.0/NOTICE, community documents, bilingual README and existing demo media. Internal handoff, daily reviews, private paths, user layouts, captures and signing credentials are excluded.

本次同步 preview.78 产品源码，移除维护者签名 Team ID，保留公开历史、Apache-2.0/NOTICE、社区文档、双语首页及既有演示素材。不公开内部交接、每日审阅、用户布局、截图和签名凭据。

Changes since the October 9 snapshot / 自10月9日快照的变化：

- P0-1: launch requests use `/usr/bin/open`, with bundle prechecks, in-place launch feedback and asynchronous failure reporting.
- P0-4/M3: folder open/close/merge/dissolve and drag landing continuity, reduced-motion handling, borderless tile feedback, and folder title accessibility aligned with animation hit testing.
- M4: expanded Core tests and windowless animation cleanup/readiness checks; Debug-only merge completion diagnostics and a corresponding UI assertion.

Validation boundaries / 验证边界：

Previous development evidence: Core194/194, windowless cleanup33/33; the last full UI batch on preview.77 product code was55 passed/1 failed/2 skipped with56 main-thread warnings. The intermittent alias-search failure after restart is unresolved. The new merge cleanup UI assertion was compiled but not run; preview.78 had no fresh cold-start/UI run. These historical results do not claim a new public UI pass.

历史开发证据：Core194/194、无窗口清理33/33；最近完整UI为55通过/1失败/2跳过，保留56条主线程警告。重启后别名搜索间歇失败尚未定位，新合并结束态UI断言只编译未运行，78未有新的冷启动/UI运行。不将历史证据描述成新的公开UI通过。

The current public checkout's background gate and CI results are recorded in TEST_MATRIX. Continuous rendered motion, physical input/IME, VoiceOver, multiple displays, Store distribution and notarization remain open. No visible tests are launched by this synchronization.

The public repository’s directory-watcher noise-test timing/cleanup fix is retained; it is a test-only difference from the development snapshot. / 保留公开仓目录监听噪声测试的时序与进程清理修复，该差异仅涉及测试。
