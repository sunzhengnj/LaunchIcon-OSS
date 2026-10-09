# API 与权限 Spike 记录

## 2026-09-26 — XCTest 自动化模式的本机身份验证

- **复现环境与步骤：** macOS 27.0（26A428）、Apple Silicon、Xcode 27.0；在隔离 DerivedData 运行 `LaunchIconUITests/LauncherDragUITests/testBlankBackgroundClickHidesLauncherWithoutQuitting`，结果包 `/tmp/LaunchIcon-UITest926/AfterAuthorization.xcresult`。`testmanagerd` 记录测试 runner 请求 automation mode。
- **结果：** XCTest 在任何测试方法开始前约 60 秒报 `Timed out while enabling automation mode`。桌面截图 `/tmp/LaunchIcon-UITest926/automation-auth-screen.png` 显示系统对话框“XCTest 正在尝试 Enable UI Automation”，要求输入当前 Mac 账户密码；仅口头确认“已授权”没有完成这一步。对话框未由开发者代理填写或绕过。
- **限制与公开路径：** 这只定位 UI 测试基础设施的本机身份验证门槛，不证明 LaunchIcon 业务 UI 通过或失败。应由设备用户在 macOS 对话框完成身份验证，然后使用原生 Xcode/XCTest 重新运行 UI 套件；无需私有 API、修改 TCC 数据库或关闭系统保护。Core-only 的 `script/test_core.sh` 可先 `build-for-testing`，再直接运行 Xcode 的 `xctest`，当前 43/43 通过，不需要 UI 自动化模式，也不能替代 UI/实体测试。Direct bootstrap 已独立通过。

## 2026-09-26 — Store Release 沙箱启动与旧 Bundle ID 对照

- **复现环境：** macOS 27.0（26A428）、Apple Silicon，`main` @ `65778e9`。`LaunchIconStoreSpike` Release 以 `CODE_SIGN_STYLE=Manual` 和现有 Apple Development 身份构建；App 与 `LaunchIconCore.framework` 均通过 `codesign --verify --deep --strict`，App 权利含 `app-sandbox=true` 与开发用 `get-task-allow=true`。默认 Xcode Release 构建是 ad-hoc 签名，不能当作开发者签名证据。
- **步骤与结果：** 原 `com.sunzheng.LaunchIcon.StoreSpike` 的开发签名包启动后有进程但无窗口；主线程采样停在 `_libsecinit_appsandbox → _xpc_pipe_routine → mach_msg2_trap`，两次启动的 Computer Use 窗口读取均超时。相同原 ID 的 ad-hoc 沙箱包也停在该阶段。只在隔离构建中去掉 sandbox entitlement 的对照包正常显示窗口，发现 104 candidates/0 skipped、本地化“时钟”和首图标可读。再以全新 `com.sunzheng.LaunchIcon.StoreFresh926` 构建开发签名沙箱包，严格签名通过，真实窗口同样显示 104/0、“时钟”、首图标可读及 `Option + Space: registered`。之后重启原 ID 的开发签名包仍无窗口并超时。
- **结论与限制：** 当前机器上的异常与原 Bundle ID 关联的本机沙箱/容器状态相关；仅凭这些对照不能确定是容器内容、TCC 还是系统服务哪一层。未重置或读取受保护的旧容器，未改项目源码。新 ID 的 Release 沙箱可运行，但只验证扫描、图标和热键注册返回值；未点显式启动、未按物理热键，不等于 App Store 分发或审核。全部隔离测试进程已停止；新 ID 产生的独立沙箱容器保留。

## 2026-09-26 — 当前 Store Spike 沙箱运行复验

- **复现环境：** macOS 27.0（26A428）、Apple Silicon，当前 `main` 的 `LaunchIconStoreSpike` Debug/Release 在 `/tmp/LaunchIcon-StoreAudit926` 构建，两个包均通过 `codesign --verify --deep --strict`。Debug 签名含 `app-sandbox=true` 与仅供开发的 `get-task-allow=true`；运行的是 Debug 包 `com.sunzheng.LaunchIcon.StoreSpike`，不是 App Store 分发包。
- **步骤与结果：** 启动前系统计算器未运行。真实窗口显示 `Option + Space: registered`、`Discovery: 104 candidates; skipped: 0`、`Clock display name: 时钟`、`Icon read for first candidate: true`，无自动启动记录。点击窗口内明确标注的“启动系统计算器（测试）”后新增 `Launch requested: 计算器`、`Launch request submitted`，并出现新的计算器进程和真实窗口。容器 `Data/Library/Preferences/...plist` 的 `M0SpikeEvidence` 最后七条与容器诊断日志最后七条一致；测试后探针及计算器进程均已停止。
- **公开 API 与限制：** 扫描/元数据、图标与显式启动仍使用 Core 中的公开 `FileManager`/CoreServices/`NSWorkspace` 路径；元数据不可用时回退包声明名称。本次只证明当前设备的一次 Debug 沙箱启动与一个系统 App 的显式打开，`registered` 仅是注册返回值，不证明物理 `⌥ Space` 回调；也不证明所有第三方 App、App Store archive/审核、Developer ID 或公证。Release 仅构建/验签，未运行。测试使用既有 Spike 容器并追加诊断，不清理来源不明的数据。

## 2026-09-25 — 缓存回退、取消空态与诊断刷盘

- **复现环境：** macOS 27.0（26A428）、Apple M4、Xcode 27.0。隔离 Debug bundle `com.sunzheng.LaunchIcon.CacheUI925`，1024×768 测试窗口，临时布局、临时偏好和两个自造 `.app`。Debug 配置现含 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`；在此之前 `#if DEBUG` 挂钩不会进入二进制。
- **步骤与结果：** 第一次完整扫描写出 `catalog-v1.json` 和布局。第二次用 `LAUNCHICON_TEST_SCAN_HOLD_FILE` 停在准备态，窗口出现“使用上次应用列表”。`LAUNCHICON_TEST_BUTTON_SCRIPT` 写入按钮标题后，应用对可见按钮执行 `performClick`。缓存视图显示 CacheAlpha/CacheBeta 和只读说明；布局与缓存 SHA-256 不变。删除暂停文件后再按“重新扫描”，日志为 `Discovery: 2 candidates; skipped: 0`，布局身份不变。另一次空目录加 `LAUNCHICON_TEST_CANCEL_SCAN_WITHOUT_RETRY=1`，窗口显示“扫描已取消”和“重新扫描”；重扫后回到“未找到可用的应用”，没有新的缓存文件。干净退出后 `defaults read` 仍有 `M0SpikeEvidence`，对应诊断日志也在。这些测试变量只在 Debug 且已经指定 `LAUNCHICON_TEST_LAYOUT_PATH` 时生效。
- **公开 API 与限制：** 缓存仍是布局旁边的本机 JSON，扫描和按钮动作都在现有 Core/AppKit 路径上。外部 `CGEvent` 能移动光标，但没有打进这个无边框浮动面板；辅助功能窗口列表在本会话也没有给出面板里的按钮。因此按钮证据是进程内 `performClick` 加截图，不是实体鼠标。`NSPanel.hidesOnDeactivate = false` 避免失活时绕过 `hide()`。没有调用私有 API。Store 沙箱、实体拖拽、VoiceOver 和 Developer ID 未在本轮复验。钥匙串只有 Apple Development，`distribution_preflight.sh --preflight` 拒绝继续，未向 Apple 提交。

## 2026-09-24 — Direct 不接受旧自动启动变量

- **复现环境与步骤：** macOS 27.0（26A428），独立 `com.sunzheng.LaunchIcon.BootstrapTest…` Debug 包，临时扫描根和布局；运行 `./script/test_direct_bootstrap.sh` 时同时传入旧 `LAUNCHICON_SPIKE_LAUNCH_PATH`，但不点击任何应用。
- **结果与边界：** 进程只记录 1 个候选的发现，布局写出 Calculator；诊断无 `Launch requested`、`Launch request submitted` 或 `Launch failed`。Direct 已删除该环境变量分支，启动请求仍只由用户操作 tile 进入共享 `WorkspaceAppLauncher`。Store Spike 的显式按钮路径未变，本轮只重新构建/校验签名，没有再次运行其沙箱或测试 App Store 分发。

## 2026-09-23 — Store 沙箱本地化、发现、图标与显式启动

- **复现环境：** macOS 27.0（26A428），当前 `com.sunzheng.LaunchIcon.StoreSpike` Debug 包严格嵌套签名通过；entitlements 仅有 `app-sandbox=true` 与开发用 `get-task-allow=true`。启动前系统计算器主进程未运行。`LaunchIconStoreSpike` unsigned Release 也完成编译，但未作为运行/分发产物测试。
- **步骤与结果：** 当前构建刻意带旧 `LAUNCHICON_SPIKE_LAUNCH_PATH=/System/Applications/Calculator.app` 环境变量启动，窗口只记录 `Option + Space: registered`、`Discovery: 104 candidates; skipped: 0`、`Clock display name: 时钟` 与 `Icon read for first candidate: true`，没有启动记录或计算器主进程。随后通过 Computer Use 点击明确标注的“启动系统计算器（测试）”，窗口才记录 `Launch requested: 计算器`、`Launch request submitted`；系统出现 `/System/Applications/Calculator.app/Contents/MacOS/Calculator` 进程及可读取的“计算器”主窗口。容器内 `M0SpikeEvidence` 和 `LocalDiagnostics` 的最后七条与窗口一致。测试后两个主进程均已停止。
- **公开 API 与限制：** 发现与本地化使用 `FileManager`、CoreServices `MDItemCopyAttribute`，图标读取使用 `NSWorkspace.icon(forFile:)`，启动使用 `NSWorkspace.open(_:)`；元数据缺失时回退 `Info.plist` 名称。这里只验证一个系统 App 的 Debug 沙箱请求及实际打开，不代表所有第三方 App、物理 `⌥ Space` 回调、App Store archive/审核或正式分发签名可用。此前容器外 diagnostics 路径被拒绝的沙箱边界仍成立。

## 2026-09-23 — 应用本地化显示名

- **复现环境：** macOS 27.0（26A428），系统首选语言 `zh-Hans-CN`；比较已安装 LaunchOS、独立 `com.sunzheng.LaunchIcon.UIAudit20260923` Debug 包及 `/System/Applications/Clock.app` 等。原始 `CFBundleDisplayName`、`Bundle.object(forInfoDictionaryKey:)`、URL localized name 均给出 `Clock`，公开 CoreServices `MDItemCopyAttribute(kMDItemDisplayName)` 给出“时钟”；`Calendar` 同理为“日历”。
- **结果：** Direct 扫描改用非空且区别于包文件名的元数据名称；独立真 UI 第二页的“时钟/日历/信息”及搜索 `Calendar`/“日历”同结果已验。未索引测试 `.app` 的元数据只给出包名，因此继续以 `Info.plist` 声明名作为回退。Core 37/37、Direct Release 构建及严格签名通过。
- **限制与公开替代：** Spotlight 可能缺失、关闭或未授权；此时沿用 `CFBundleDisplayName`、`CFBundleName` 和包名，不依赖 Launchpad 数据库。Store Spike 的沙箱读取后续已单独运行确认，见上节；该结果只覆盖当前系统和应用样本。

## 2026-09-22 — Store Spike 后台探测与诊断边界

- **复现环境：** macOS 27.0（26A428）、Xcode 27.0（27A266a）。当前 `LaunchIconStoreSpike` Debug target 以独立 DerivedData 构建；`codesign --verify --deep --strict` 通过，entitlements 是 `com.apple.security.app-sandbox=true` 与开发用 `com.apple.security.get-task-allow=true`。
- **实现与限制：** capability probe 由 window controller 持有且可取消；目录扫描走 Core actor，`NSWorkspace.icon(forFile:)` 的首图标探测走 utility detached task；结果只在未取消时回到 MainActor。UserDefaults evidence 与 `LocalDiagnostics` 写入走 utility 串行队列，不在 AppKit 主线程调用 `synchronize()`。为避免本轮改写已有 `M0SpikeEvidence`，未启动 spike UI；因此这只证明当前 target 能构建/签名，不证明沙箱运行时的发现、图标、启动或快捷键能力。

## 2026-09-22 — Store Spike 当前沙箱运行态

- **复现环境：** 使用唯一 bundle ID `com.sunzheng.LaunchIcon.StoreRuntimeAudit` 的隔离 Debug 包（`app-sandbox=true`、仅开发 `get-task-allow=true`），macOS 27.0（26A428）。未设置启动路径，未点击“启动第一个发现的应用”。
- **结果：** 窗口实际显示 `Option + Space: registered`、`Discovery: 104 candidates; skipped: 0` 与 `Icon read for first candidate: true`。容器内 `M0SpikeEvidence` 和 `Data/Library/Application Support/LaunchIcon/Diagnostics/...log` 均按相同顺序记录四条结果，没有任何 Launch requested/submitted/failed 记录。
- **沙箱边界：** 仅为测试指定容器外 `LAUNCHICON_DIAGNOSTICS_PATH=/tmp/...` 时，日志明确报无权限写入；移除该覆写后默认容器路径成功写入。这是 expected sandbox 边界，生产 Store 变体不能依赖外部测试路径。尚未验证：显式 `NSWorkspace` 启动、真实物理快捷键回调、App Store archive/审核或分发签名。

## 2026-09-22 — Direct 首次后台启动与 reopen

- **复现环境：** macOS 27.0（26A428），当前 Apple Development Debug 产物；以唯一测试偏好域、`/Applications` 测试扫描根目录和临时布局直接启动 app bundle 内可执行文件。进程稳定存活且 `lsappinfo` 显示为 Foreground。使用公开 `AXUIElementCopyAttributeValue` 读取该 PID：首次启动时 `kAXMainWindowAttribute` 与 `kAXFocusedWindowAttribute` 均为 `kAXErrorAttributeUnsupported`（-25212），没有可见 launcher window；对同一 app bundle 发送标准 reopen 事件后，两项均返回成功且有 window，Computer Use 读取到完整启动器 Accessibility tree。
- **结论与限制：** `DirectAppDelegate` 没有在 bootstrap 自动 `show()`，`applicationShouldHandleReopen` 可恢复 launcher，符合 P0-1 的“不抢屏 → 用户显式重开”路径。该证据不验证物理 `⌥ Space`、菜单栏点击、Dock 像素或不同账户；整个测试实例及偏好/临时布局均在验收后清理。

## 2026-09-22 — Direct 发布签名与公证预检

- **复现环境：** macOS 27.0（26A428）、Xcode 27.0（27A266a）。当前 Direct Release 是 Apple Development 签名，Hardened Runtime 已启用，但 entitlement 中仍有 `com.apple.security.get-task-allow=true`；本机钥匙串没有 Developer ID Application 身份。
- **结论：** 这是发布签名前置条件缺失，不是编译或嵌套签名损坏。`script/distribution_preflight.sh --preflight` 现在会在缺 Developer ID 身份时以明确错误失败；`--verify` 会拒绝非 Developer ID、无 Hardened Runtime、带 `get-task-allow` 或无 staple 的 app；`--archive-and-notarize` 只在显式提供 Developer ID 身份和 notarytool 钥匙串 profile 后 archive、提交、staple。当前没有提交任何包到 Apple，也不宣称已公证。

## 2026-09-21 — 设置窗口的登录项接口

- **复现环境：** macOS 27.0（26A428）、Xcode 27.0（27A266a），Direct Apple Development Debug 包；隔离测试偏好与临时布局。打开“设置…”时，在 utility 任务读取 `SMAppService.mainApp.status`，窗口显示“开机登录”未启用，未出现额外权限提示。没有点击启用/停用，也没有修改系统登录项。
- **依据与限制：** Apple 公开文档明确 `mainApp` 对应主 App 登录项，`register()` 后可能需用户批准，`status` 可返回 `requiresApproval`；公开替代路径为 `openSystemSettingsLoginItems()` 引导用户处理。当前证据只证明状态读取与窗口接线，不证明注册、审批、重启登录后启动或沙箱/公证包可行性。[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)、[mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)、[register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29)。

| 能力 | Direct | App Sandbox | 证据状态 | 公开 API / 说明 |
| --- | --- | --- | --- | --- |
| 标准 Applications 路径发现 | 当前 104 candidates | 当前 104 candidates / 0 skipped | 已在 macOS 27 本机运行；历史 M0 数字因目录内容变化不再代表当前状态 | `FileManager` + `Bundle` |
| 图标读取 | 首个候选 `isValid == true` | 首个候选 `isValid == true` | 已在 macOS 27 本机运行 | `NSWorkspace.icon(forFile:)` |
| 显式应用启动 | Activity Monitor 请求已提交 | 当前 Calculator 请求已提交且真实窗口已打开 | 已在 macOS 27 本机运行；Direct TextEdit pending 与删除后陈旧注册回归已验证 | 后台路径存续检查 + `NSWorkspace.open(_:)`；以同步 Bool 判断系统是否接受请求，目标 App ready 另以实际窗口验证 |
| `Option + Space` | 注册成功 | 注册成功 | 注册已验证；物理按键回调待验 | Carbon `RegisterEventHotKey`；不监听键入内容 |
| 当前显示器壁纸背景 | 成功读取并在 launcher 内显示 | 未验证 | macOS 27 Direct Debug 真实 UI | `NSWorkspace.desktopImageURL(for:)` + ImageIO 下采样；不缓存、不上传，不使用屏幕录制 |

## M0 实测环境与限制

- 环境：macOS 27.0（26A428）、Xcode 27.0（27A266a）、Swift 6.4，2026-09-16。
- Direct target：Apple Development Debug 签名，Hardened Runtime 启用；实际显示 launcher shell，Computer Use 可读取其文本；按 Esc 后 LLDB 确认窗口 `isVisible == NO`。
- Store spike：Debug 包带 `com.apple.security.app-sandbox = true`，`codesign --verify --deep --strict` 通过。它是“Sign to Run Locally”本机调试包，不等同于 App Store provisioning、archive 或审核批准。
- 未验证：全局快捷键物理触发、不同用户/干净机器、发布签名和 notarization。
- 壁纸限制：2026-09-20 在当前显示器复现通过；每次显示时检查壁纸 URL，动态壁纸同一路径内的帧变化不会实时同步。URL 不可读时退回产品自有深色背景，不申请额外权限。

## 执行规则

- 使用真实 macOS 设备和 Debug/Release target 分别记录结果。
- 启动测试仅由用户点击 spike 界面中的明确按钮触发；“请求提交”不等于目标 App 已 ready。
- 任一项在沙箱失败时，记录错误域/码和可行替代方案；不得以 Direct 结果推断 Store 可行。
