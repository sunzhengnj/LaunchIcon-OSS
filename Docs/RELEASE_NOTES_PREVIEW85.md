# LaunchIcon preview.85 — 自定义根安全 / Dock 与状态栏 / 搜索网格打字（preview.84 之后）

私有 WIP/prerelease。相对 preview.84：截断/缺失自定义根不再误删布局；Launchpad 导入文案对齐；状态菜单可非指针打开；Dock 仅屏幕边缘显现；Shift 方向键范围选、捏合打字不关、重开时间戳、日期重排隐藏；拖出 `.fileURL` 延后附着；搜索网格打字 / 焦点框 / 单元格露出与字段编辑器提交；UI-RUNNER T5 覆盖扩充。Ad-hoc 签名，未公证。

## 相对 preview.84

本轮变更均在 preview.84（标签 `v1.0.0-preview.84`）之后入库（打包 tip 见标签提交）：

1. **自定义根安全**：扫描被截断时保留文件夹槽位；根目录不可见时不把 reconcile 结果落盘缓存；截断根下已删应用可正确丢掉。
2. **Launchpad 导入文案**：AGENTS / README 与只读导入行为对齐。
3. **状态菜单 / Dock 显现**：状态项菜单可不依赖鼠标事件打开；Dock 仅在指针到屏幕边缘时显现。
4. **键盘与手势切片**：网格内 Shift+方向键扩展选区（不改翻页路径）；打字中捏合不关闭启动器；关闭时只盖一次 home-reset 时间戳；隐藏后丢掉延期的日期重排。
5. **UI-RUNNER T5**：补 reopen home、文件夹页键、边缘箭头覆盖；去掉重复 HANDOFF 标题。
6. **拖出 Dock 文件链接（DRAG-FILE-URL-LATE-01）**：整理拖拽真实 `.app` 时，等指针离开窗口后再附着 `.fileURL`。**已知风险**：生产窗口常为全屏，指针可能无法离开窗口，Dock 投放可能失效（小窗测试测不出）。
7. **搜索网格打字**：字母经文本输入系统路由；编辑器不收下的字母写入字段编辑器（`replaceCharacters` + `validateEditing`）；搜索/编辑器屏幕坐标焦点框；无边框启动器公布位置与尺寸；文件夹/搜索整格焦点露出与滚动。
8. **其它**：目录监视器测试在断言前排空 writer；日报 `2026-10-27` / `2026-10-28`。

## 已知未闭环

- 完整 UI Runner **未全绿**（上次全绿约 `23c5967`，60/0/2；tip 附近约 28 通过 / 33 失败，根因未查清；勿当作本包门槛）
- 全屏下 Dock `.fileURL` 延后附着可能导致拖到 Dock 失败
- 网格行列偏好尚未接到 Direct / 设置 UI / 翻页几何（**未改翻页路径**）
- Developer ID 签名与公证未做
- 翻页手感仍单列验收红线

## 验证

`./script/validate_background.sh` 在本 tip 上通过（Core 用例随提交递增；**未声称完整 UI Runner 全绿**）。macOS 26+，arm64/x86_64。Ad-hoc，未 Developer ID / 未公证。私有 WIP/prerelease；请用本标签直链（`/releases/latest` 仍可指向更早版本）。
