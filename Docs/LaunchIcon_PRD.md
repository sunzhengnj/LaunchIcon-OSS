# LaunchIcon — PRD 与技术规格（v1.0）

> 本文是 LaunchIcon 1.0 的产品、设计与工程单一事实源。除非系统公开 API、审核规则或安全约束冲突，开发不得偏离本文；冲突必须记录在 `DECISIONS.md`，说明影响与替代方案。

| 项目 | 定义 |
| --- | --- |
| 产品名 | LaunchIcon |
| 产品类型 | 轻量级 macOS 应用启动器（经典图标网格体验） |
| 首发平台 | macOS 26+；最低兼容版本可在实现启动时单独评估 |
| 技术栈 | Swift 6、AppKit、Core Animation、Swift Concurrency、SQLite/JSON 持久化 |
| 分发 | Developer ID 签名 + Notarized DMG；随后 Mac App Store 变体 |
| 网络/账户 | 1.0 无账户、无服务端、无遥测上传、默认离线可用 |

---

## 1. 产品定位

### 1.1 一句话

LaunchIcon 为 Mac 提供一个熟悉、安静、全屏的应用浏览、整理与启动空间：用户按快捷键，看见图标，点击启动。

### 1.2 目标与非目标

**目标**

- 让用户在 300 ms 内呼出启动界面，在视觉上立即理解当前可启动内容。
- 支持应用网格、分页、文件夹、拖拽排序、搜索与键盘关闭。
- 保持“原生 Mac 工具”的克制感：没有帐户、广告、推荐流、工作流市场或学习成本。
- 使用 Apple Public API，避免 Private API 与对系统桌面/Launchpad 数据库的写入。

**明确非目标（1.x 不做）**

- 替代 Spotlight、Raycast、Alfred 或 Finder。
- 搜索文件、网页、剪贴板、命令、AI、终端或自动化工作流。
- 云同步、团队协作、插件、应用商店、应用内购买与使用分析。
- 复制或声称复刻已移除的系统功能；不得使用 Apple 商标、私有图标、私有壁纸或私有 API。

### 1.3 用户与核心场景

| 用户 | 需求 | 成功表现 |
| --- | --- | --- |
| 习惯图标启动的 Mac 用户 | 快速看到和启动常用 App | 快捷键后一次点击启动 |
| 应用很多的用户 | 按自己的空间记忆整理应用 | 拖拽排序/创建文件夹后下次保持一致 |
| 注重隐私的用户 | 不希望应用清单被上传 | 无登录、无网络依赖、隐私说明清晰 |

**核心用户旅程**：启动或登录后，LaunchIcon 在后台就绪 → 用户按全局快捷键 → 全屏玻璃层淡入 → 浏览、翻页或键入搜索 → 点击应用 → App 启动且 LaunchIcon 收起。

---

## 2. 产品范围与完整功能 PRD

### 2.1 应用清单

1. 首次启动扫描标准应用位置：`/Applications`、`/System/Applications`、`~/Applications`；递归扫描需排除 `.app` 包内部、别名循环、隐藏路径与不可访问位置。
2. 扫描结果以 `URL`、bundle identifier（存在时）、显示名、图标、路径、最近发现时间组成候选记录。
3. 同一 bundle identifier 或解析到同一规范化 URL 的项目去重；优先用户目录与 `/Applications` 的可执行副本，规则必须可测试。
4. 系统工作区变更、前台启动、用户手动“重新扫描”可触发增量刷新；扫描不阻塞界面首次展示。
5. 若无读取权限、应用损坏或图标读取失败，仍显示可用的降级图标，并在调试日志记录原因；不得弹出干扰用户的错误框。

### 2.2 启动

- 单击图标：产生按压反馈，调用公开 `NSWorkspace.openApplication`（或等价公开 API）。
- 成功发起后，界面在 120 ms 后开始退出；不能把“启动请求已提交”等同于目标 App 已完全 ready。
- 无法启动时保持界面可见，显示非阻塞 toast：“无法打开〈名称〉”；日志含 NSError 域与码。
- 按住 Option 单击可在 Direct 版作为“在 Finder 中显示”的候选扩展；1.0 默认不暴露该手势，保留路由能力即可。

### 2.3 网格、分页与空间记忆

- 逻辑每页固定 **7 列 × 5 行 = 35 个槽位**。实际窗口可根据可用尺寸等比缩放图标与间距，但不改变列/行语义。
- 全新布局首次扫描先展示系统应用，再展示第三方应用；已有自定义顺序及后续新发现应用的追加位置不重排。
- 空位不渲染占位卡；排列数组决定视觉顺序。
- 底部显示页数圆点，最多同时展示 7 个；超过时用窗口式省略并保证当前页可见。
- 左右热区/箭头在多页时可用；键盘 Left/Right 与水平滚轮（阈值 40 px）翻页。
- 页面切换后焦点仍停在同一相对位置，若目标槽为空则移至本页最后一个可用项目。
- 全屏启动器顶部提供可见、可由键盘和辅助功能操作的“设置”入口，不依赖隐藏的菜单栏。

### 2.4 搜索

- 唤起界面时不自动获得搜索焦点；用户直接键入可进入搜索，`⌘F` 明确聚焦。
- 按显示名、bundle identifier 与用户自定义别名做不区分大小写、变音符号不敏感的包含匹配；1.0 不做网络搜索。
- 中文显示名、应用包名与自定义别名支持拼音全拼（可连续输入、不必输入音调或空格）及拼音首字母包含匹配；多音字沿用 Apple Foundation 的系统转写结果，不引入联网词库或第三方依赖。
- 结果在单一网格中重新流式排列，隐藏分页控件；空结果显示简短说明和 Esc 清除提示。
- `Esc` 优先级：关闭文件夹 → 清空搜索 → 收起 LaunchIcon。搜索框 Clear 按钮等价清空。
- 搜索结果点击启动；拖拽排序和建文件夹在搜索模式禁用，避免“结果集排序”歧义。

### 2.5 拖拽整理与文件夹

1. 长按/拖动应用进入整理态，其他图标让位，目标图标获得可访问的视觉状态。
2. 放在同页另一图标的**中心 56% 区域**：若二者均不是文件夹，创建含两者的新文件夹；若目标是文件夹，加入该文件夹。
3. 放在图标边缘区域或空槽：重排；使用稳定的 `rank` 计算而非整数索引连锁重写。
4. 文件夹最多 25 个成员；满时拒绝放入并给轻触觉/视觉反馈。嵌套文件夹不允许。
5. 打开文件夹：居中展开为 5 × 5 内部网格（1.0 上限 25；产品选择：新建最多 25，而网格页最多 35）。文件夹内拖出到背景可还原为顶层；成员只剩 1 个时自动解散文件夹并保持剩余 App 原位。
6. 所有整理变更做 300 ms debounce 持久化；App 正在退出时立即 flush。

### 2.6 快捷键、菜单栏与设置

- 默认全局快捷键：`⌥ Space`。若注册冲突，首次提示用户在设置中选择其他组合；不得监听或记录按键内容。
- 菜单栏状态项仅提供：显示/隐藏、重新扫描、设置、退出。可以在设置中关闭状态项，但全局快捷键必须仍可用。
- 设置 1.0：快捷键、开机登录、状态项显示、启动后自动隐藏、减少动态效果。其他配置不进入 1.0。
- 开机登录使用公开 ServiceManagement API；失败给出可理解的系统设置指引。

### 2.7 空状态与异常状态

| 状态 | 表现 | 可操作项 |
| --- | --- | --- |
| 首次扫描 | 网格 skeleton，文本“正在准备应用…” | 可取消并进入上次缓存 |
| 无可用应用 | 简洁空态 | 重新扫描、打开设置说明 |
| 无搜索结果 | 网格区域显示“未找到匹配的应用” | Esc 清除搜索 |
| 扫描部分失败 | 不打断用户 | 调试日志；设置中可重新扫描 |
| 启动失败 | 原地 toast，界面不关闭 | 关闭 toast 或重试 |

---

## 3. 信息架构、页面与视觉规格

### 3.1 页面/状态树

```text
App Shell
├── 关闭态（后台常驻）
├── Launcher 主界面
│   ├── 正常网格 / page n
│   ├── 搜索结果
│   ├── 拖拽整理态
│   ├── 文件夹展开层
│   ├── 扫描中 / 空状态
│   └── 非阻塞错误 toast
└── 设置窗口（独立、非全屏）
```

### 3.2 主界面布局

| 区域 | 规格 |
| --- | --- |
| 根窗口 | 全屏无标题栏、非激活时不截取键盘；可在所有 Space 显示由设置决定 |
| 背景 | 用户当前壁纸的低成本模糊采样**或**产品自有抽象渐变；不可读取/缓存用户壁纸文件用于上传 |
| 玻璃层 | `NSVisualEffectView`，material 选与当前系统匹配的公开 material；叠加 14–22% 深色/浅色对比层确保文字可读 |
| 安全边距 | 横向 `max(60pt, 5vw)`；顶部至少 72pt；底部至少 56pt |
| 搜索 | 居中，宽 360–520pt，高 42pt；圆角 21pt；仅搜索状态显示光标与 clear 按钮 |
| 网格 | 宽度不超过可用内容区；图标核心 72pt（紧凑 60、宽屏 84），名称 12pt / 16pt |
| 应用单元 | 按可用视口均分；典型高度 120–136pt，768pt 高屏幕可收缩至约 105pt，但不能裁掉第 5 行；图标与文字整体点击热区不小于 44 × 44pt |
| 分页 | 底部中央，圆点 6pt，当前 7pt，间距 9pt；不使用数字页码 |
| 操作提示 | 与页码同一行、保持底部 56pt 安全边距且不压缩网格；主网格显示可用的拖拽整理/左右键翻页与 Esc 返回提示，搜索状态显示 Esc 清除搜索；只读状态不得提示拖拽 |
| 翻页控制 | 页面左右 32pt 内热区；仅 hover/键盘操作时显现圆形半透明箭头 |

### 3.3 字体、色彩和图标

- 字体：系统 `SF Pro`（通过系统字体自动取得），不得内嵌 Apple 字体文件。标题 20pt medium，应用名 12pt regular，辅助文案 13pt regular。
- 主文字使用 `labelColor`；在深背景上的浮层文本至少维持 WCAG 对比度 4.5:1。不要写死纯白/纯黑来破坏辅助功能主题。
- 应用图标优先 `NSWorkspace.icon(forFile:)`，以圆角矩形裁切/阴影包装，不重绘第三方品牌图标。
- 产品图标与示例原型使用 LaunchIcon 自有的蓝、紫、粉、黄四格几何标记；不得使用 Apple、Finder、Launchpad 或系统 App 图标资产。

### 3.4 文件夹规格

- 主背景网格缩放到 0.96、透明度 0.45、轻微模糊；不可交互。
- 文件夹 panel 宽 680–900pt，最大高 70vh；顶部名称可重命名（1.0 允许），右上角明确关闭按钮。
- 背景点击或 Esc 关闭；打开文件夹不改变主页面码。
- 在减少动态效果模式下，只做 120 ms opacity transition，不做 scale/blur 动画。

---

## 4. 交互与动画规格

### 4.1 动画令牌

| Token | 参数 | 用途 |
| --- | --- | --- |
| `motion.fast` | 120 ms, ease-out | 点击、toast、搜索显隐 |
| `motion.standard` | 220 ms, cubic-bezier(0.2, 0.8, 0.2, 1) | 主界面、文件夹展开 |
| `motion.page` | 280 ms, spring damping 0.86 / response 0.42 | 页面横移 |
| `motion.reorder` | 180 ms, ease-out | 拖拽让位 |
| `motion.drop` | 260 ms, spring damping 0.72 / response 0.34 | 建文件夹与落位 |
| `motion.reduce` | ≤120 ms, linear/ease-out | 减少动态效果替代 |

### 4.2 状态转场

| 事件 | 动画 | 完成条件 |
| --- | --- | --- |
| 呼出 | 背景 opacity 0→1，网格上移 8pt→0 | 首帧 ≤300 ms，完成 ≤220 ms |
| 收起 | 网格下沉 4pt + fade | 交互立即禁用，窗口 orderOut 于 120–180 ms |
| 翻页 | 旧页 x 0→±18%、opacity 1→0；新页反向进入 | 新页完成后更新无障碍焦点 |
| 点击 App | scale 1→0.93→1，90 ms | 仅一轮，避免双启动 |
| 拖拽 | 原单元 scale 1.06、影子 18%，其他单元占位滑动 | 鼠标/触控板结束恢复 |
| 文件夹 | 拖入新建或已有文件夹时，图标 340 ms 飞向目标，文件夹落位缩放 0.68→1 | 先提交布局，动画只负责可中断的视觉反馈 |

动画必须：可中断、不会阻塞输入、不以计时器驱动数据真相、在 `accessibilityDisplayShouldReduceMotion` 下切换到 reduce 版本。仅用 Core Animation/NSAnimationContext；禁止私有框架和基于屏幕录制的动画方案。

---

## 5. 技术架构

### 5.1 分层

```text
LaunchIconApp (SwiftUI 仅可作设置壳；主启动器为 AppKit)
├── AppDelegate / LifecycleCoordinator
├── LauncherFeature
│   ├── LauncherWindowController
│   ├── LauncherViewController
│   ├── GridView / AppTileView / FolderView
│   ├── SearchController / KeyboardRouter / DragCoordinator
│   └── LauncherViewModel (@MainActor)
├── Domain
│   ├── AppItem, Folder, LauncherPage, LauncherLayout
│   ├── LauncherCommand, SearchQuery, LaunchResult
│   └── protocols: AppCataloging, LayoutStoring, AppLaunching
├── Data
│   ├── AppCatalogScanner (NSFileManager + NSWorkspace)
│   ├── IconProvider (NSWorkspace / NSImage cache)
│   ├── LayoutStore (SQLite 或 versioned JSON)
│   └── PreferencesStore (UserDefaults)
└── Platform
    ├── HotKeyService (Carbon/公开 EventHotKey 或确认后的公开替代)
    ├── LoginItemService (ServiceManagement)
    ├── AccessibilityService
    └── Diagnostics
```

**依赖方向**：UI → Feature/Domain protocols → Data/Platform implementations。Domain 不导入 AppKit；视图不直接扫描磁盘、写偏好或启动应用。

### 5.2 AppKit/Core Animation 方案

- 全屏窗口：`NSPanel` 或无边框 `NSWindow`，`collectionBehavior` 使用公开 full-screen auxiliary/canJoinAllSpaces 组合；不模拟系统 Dock/菜单栏。
- 视觉模糊：`NSVisualEffectView` 承担材质与活跃状态；自有渐变/抽象壁纸使用 `CAGradientLayer` 与若干 `CALayer`，不使用截图权限。
- 网格：优先 `NSCollectionView` + compositional/custom layout 以获得虚拟化、键盘与拖拽；小数据量仍保持可预测的 diffable datasource。
- 图标：`NSImageView` 在后台解码、主线程绑定；`NSCache` 按 URL + modification date 缓存，收到内存警告时清除。
- 动画：布局变更用 `NSAnimationContext.runAnimationGroup`，图层只承载视觉过渡；model layer 和数据源必须先/后保持一致，禁止把显示层作为状态来源。

### 5.3 并发与线程策略

- `LauncherViewModel`、所有 AppKit 调用、焦点管理在 `@MainActor`。
- 目录扫描、图标预热、JSON/SQLite I/O 在 actor 或明确后台 executor；每批（最多 20）结果回主线程更新。
- 取消规则：关闭界面不会取消目录扫描（可继续刷新缓存）；手动重新扫描取消旧任务；App 退出取消所有任务并 flush store。
- 不使用未受控 `DispatchQueue.global()`；每个 Task 要有所有者和取消时机。

---

## 6. 数据模型与持久化

### 6.1 领域模型（示意）

```swift
struct AppItem: Codable, Hashable, Identifiable {
  let id: UUID
  var bundleIdentifier: String?
  var displayName: String
  var urlBookmark: Data?       // 安全作用域场景可用；普通路径不强依赖
  var canonicalPath: String
  var iconRevision: Date?
  var aliases: [String]
  var discoveredAt: Date
}

struct Folder: Codable, Hashable, Identifiable {
  let id: UUID
  var name: String
  var itemIDs: [UUID]          // 无嵌套；最大 25
  var createdAt: Date
}

enum LauncherEntry: Codable, Hashable, Identifiable {
  case app(UUID)
  case folder(UUID)
}

struct LayoutState: Codable {
  var schemaVersion: Int
  var orderedEntries: [LauncherEntry]
  var hiddenAppKeys: Set<String>
  var updatedAt: Date
}
```

### 6.2 存储要求

- 首版可选 versioned JSON（`Application Support/LaunchIcon/layout-v1.json`）以缩小复杂度；若需要并发查询/迁移再切 SQLite。二者通过 `LayoutStoring` 隔离。
- 原子写：写入临时同目录文件、fsync/replace；任何解析失败保留损坏文件副本并用最后有效备份恢复。
- 不存储用户壁纸、按键序列、应用使用时长、窗口标题或网络身份。路径与排序仅留本机。
- schema migration 显式单元测试；未知字段容忍，未知 schema 只读备份后重新初始化并提示用户。

---

## 7. 权限、隐私与安全策略

| 能力 | 1.0 策略 | 说明 |
| --- | --- | --- |
| 文件读取 | 仅扫描标准 Applications 路径 | 不申请 Full Disk Access；访问失败即跳过 |
| 启动 App | NSWorkspace 公开 API | 用户明确点击触发 |
| 全局快捷键 | 使用公开/允许的注册机制 | 不监听、不记录键入内容；若需要 Input Monitoring 必须先重新评估产品路线 |
| 开机登录 | ServiceManagement | 由用户在设置中启用 |
| 通知 | 不需要 | 1.0 不发通知 |
| 网络 | 默认零网络请求 | URLSession 在主 target 不应有业务调用 |
| 分析 | 不接入 | 崩溃报告若后续加入必须 opt-in 并单独隐私审查 |

应用对外隐私声明必须明确：本地读取应用位置以构建启动列表；数据不离开设备。不得把“无法读取所有安装 App”伪装成已完整扫描。

---

## 8. Direct 与 Mac App Store 双版本架构

### 8.1 原则

共享 90%+ 的 Domain、Data、UI 与测试。分发差异只能出现在 `Platform` adapters、entitlements、Info.plist 与构建配置；不得 fork 两套业务代码。

```text
Targets/
├── LaunchIconCore            # 共享 domain/data/feature
├── LaunchIconDirect          # Developer ID, hardened runtime
├── LaunchIconAppStore        # Sandbox, App Store entitlements
└── LaunchIconTests / UITests
```

### 8.2 差异表

| 能力 | Direct 版 | Mac App Store 版 |
| --- | --- | --- |
| 扫描系统目录 | 在用户权限范围内按公开 API | 受 Sandbox 限制；先验证可行性，必要时改为用户选择目录或仅展示可解析项目 |
| 外部 App 启动 | `NSWorkspace` 公开 API | 需以沙箱与审核允许范围实测；失败时功能降级必须对用户诚实 |
| 全局快捷键 | 公开机制 + 明确隐私说明 | 以实际审核可接受 API 验证；不得依赖私有/绕过式 hook |
| 自动更新 | Sparkle 可作为 Direct 候选（单独审计） | App Store 管理，不能自更新 |
| 安装 | Notarized DMG | App Store 上架包 |

**关键 Gate**：在投入完整 Store 适配前，建立最小 sandbox spike，验证“发现应用 + 显示图标 + 启动目标 + 快捷键”是否通过公开权限路径。若关键能力不成立，App Store 版本必须明确降级为“用户添加的启动集合”，不可暗中扩大权限或使用私有 API。

---

## 9. 工程目录结构

```text
LaunchIcon/
├── LaunchIcon.xcodeproj
├── README.md
├── CODEX_GOAL.md
├── DECISIONS.md
├── Docs/
│   ├── LaunchIcon_PRD.md
│   ├── API_AND_PERMISSION_NOTES.md
│   └── TEST_MATRIX.md
├── Sources/
│   ├── App/
│   ├── LauncherFeature/
│   │   ├── Views/
│   │   ├── ViewModels/
│   │   ├── Coordinators/
│   │   └── Animation/
│   ├── Domain/
│   ├── Data/
│   ├── Platform/
│   └── SharedUI/
├── Resources/
│   ├── Assets.xcassets
│   └── Localizable.xcstrings
├── Tests/
│   ├── DomainTests/
│   ├── DataTests/
│   └── FeatureTests/
└── UITests/
```

命名：类型以职责命名；每个文件一个主要类型；不建立无收益的 `Utils`、`Manager`、万能 `Service`。资源、字符串、快捷键与版本迁移不得散落硬编码在视图里。

---

## 10. 开发优先级、里程碑与交付物

### P0：1.0 必须完成

| 编号 | 能力 | 验收 |
| --- | --- | --- |
| P0-1 | AppKit 全屏 launcher shell | 快捷键呼出/收起，Esc 规则正确，无闪屏 |
| P0-2 | 标准目录扫描、图标与启动 | 50+ 样本 App 中正确去重、显示、可启动 |
| P0-3 | 7×5 网格、分页、搜索 | 鼠标/键盘/触控板核心路径通过 |
| P0-4 | 拖拽重排、建/开/解散文件夹 | 重启后布局准确恢复 |
| P0-5 | 减少动态效果、VoiceOver 基础语义 | 不依赖动画、可发现控件 |
| P0-6 | Direct 版签名、notarization CI 预检 | `codesign --verify` 与 stapler 验证通过 |
| P0-7 | 测试、性能、隐私文档 | 达到第 11–12 节门槛 |

### P1：紧随 1.0

- 设置窗口（快捷键、登录项、状态项、自动隐藏）完整化。
- 可编辑文件夹名、应用别名、隐藏/恢复应用。
- 增量目录监听与图标缓存调优。
- Mac App Store spike 与明确的差异决定。

### P2：仅在用户研究证明必要时

- iCloud 同步（端到端隐私设计后再谈）。
- 多套布局/工作模式。
- 用户壁纸的授权式本地取样。
- 更丰富的无障碍/多语言自定义。

### 里程碑

1. **M0 架构决策（1–2 天）**：创建项目、决定窗口/快捷键 API、写 `DECISIONS.md`，跑 Store sandbox spike。  
2. **M1 可启动纵切（3–5 天）**：应用发现 → 网格 → 点击启动 → Esc 收起；真机演示。  
3. **M2 整理体验（3–5 天）**：分页、搜索、拖拽、文件夹、持久化与迁移。  
4. **M3 可靠性与无障碍（3–4 天）**：错误、性能、VoiceOver、减少动态效果、国际化长度。  
5. **M4 发布候选（2–3 天）**：签名、公证、clean machine 安装、回归矩阵、已知限制。  

每个里程碑必须有可运行构建、测试结果、截图/录屏证据与不通过项；未达到验收不得把下一里程碑宣称完成。

---

## 11. 测试矩阵

| 维度 | 最小覆盖 | 关键断言 |
| --- | --- | --- |
| Domain unit | 排序、去重、搜索、文件夹规则、迁移 | 永不丢失 entry；无嵌套；最多 25 文件夹成员 |
| Data unit | 扫描 fixture、不可读目录、重复 bundle、坏 JSON | 可恢复，错误可诊断 |
| Feature/UI | 呼出、Esc 优先级、搜索、翻页、拖放 | 状态、焦点、可见性正确 |
| Integration | 真机标准目录发现并启动测试 App | 真实 `NSWorkspace` 请求成功 |
| Accessibility | VoiceOver 标签/顺序、键盘路径、减少动态效果 | 不以颜色或动画作为唯一信息 |
| Compatibility | 当前首发 macOS、下一 beta（若可） | 全屏 Space、深浅外观、缩放显示器 |
| Distribution | Direct 签名/公证、Store sandbox spike | 按渠道分别验证，不能互相替代 |
| Regression | 固定 10 个核心情景 | 每次发布候选必须全绿 |

核心 UI 测试情景：首次扫描、缓存启动、35/36/70 个项目分页、空搜索、带变音名称搜索、文件夹满、文件夹剩一个、拖拽取消、启动失败、减少动态效果、快捷键冲突。

---

## 12. 性能与质量目标

| 指标 | 目标 | 测量方式 |
| --- | --- | --- |
| 冷启动至可交互壳 | P50 < 700 ms，P95 < 1.2 s | Instruments signpost，真机 release build |
| 快捷键至首帧 | P95 < 300 ms | signpost + 60fps 屏幕录制抽样 |
| 100 个应用首次扫描 | UI 不阻塞；首批图标 < 800 ms | 真机 fixture/目录 |
| 翻页/打开文件夹帧率 | 常规设备 ≥55 fps | Core Animation FPS/Instruments |
| 常驻空闲内存 | <120 MB（100 App 图标缓存后） | Activity Monitor + Instruments |
| 布局写入 | 300 ms debounce 后 <80 ms | 单元/性能测试 |
| 崩溃 | 发布候选阻断级 crash = 0 | 手工与自动化回归 |

性能目标是 release build、真实硬件、非模拟数据下的要求。若达不到，先用 Instruments 找到瓶颈；不得盲目降低图标质量或移除可访问性。

---

## 13. 1.0 验收标准（Definition of Done）

只有同时满足以下条件才可称为 LaunchIcon 1.0：

1. P0 全部完成，且所有能力均有真机证据，不以静态 mock 或 unit test 代替。
2. 可从标准路径发现、去重、显示并启动用户可访问的应用；失败路径可理解且不崩溃。
3. 7×5 网格、分页、搜索、Esc、拖拽重排、创建/打开/解散文件夹与重启持久化均通过矩阵。
4. 不使用 Private API、屏幕录制技巧、系统数据库写入或未声明权限；网络监测确认默认无业务出站请求。
5. VoiceOver、键盘、减少动态效果、深/浅外观、不同显示缩放均通过基本验收。
6. 性能门槛达到或每一项有经产品负责人批准的、可量化的例外记录。
7. Direct 产物完成签名、公证、staple 与干净环境安装验证；Store 变体至少完成可行性 spike 和差异文档。
8. `README.md`、`DECISIONS.md`、测试结果、已知限制与隐私文本是最新的。

---

## 14. 给 Codex 的开发约束

- 先阅读本文、`CODEX_GOAL.md`、当前仓库 `AGENTS.md` 和 `DECISIONS.md`，再修改代码；先检查工作区状态，绝不覆盖用户未提交变更。
- 每次变更必须可追溯到 P0/P1/P2 编号或已记录的 bug；不做顺手重构、视觉炫技、AI/云功能或未要求的设置项。
- 先实现可验证的最小纵切，再增加细节。面对 API 不确定性，先做 30–90 分钟 spike，不要依据记忆虚构可行性。
- 坚持 public API。任何可能触及私有框架、受限 entitlements、系统数据库或键盘监听的方案必须停止并记录，等待决策。
- 主线程只做 UI；不要在 AppKit view 中做 I/O、扫描或持久化。所有异步任务可取消、有 owner、有错误路径。
- 新增业务规则必须有 unit test；用户可见交互必须有 UI/手工验收步骤。构建绿不等于完成。
- 修改后依次运行最小相关测试、完整测试（可行时）、release build、真机/模拟 UI 验收；报告命令、结果和尚未验证的边界。
- 每个里程碑在独立、可审阅提交中完成。提交前查看 diff，确保没有密钥、生成垃圾、无关格式化或用户文件。
- 若需求、审核合规、渠道权限或安全范围冲突，停止扩展实现，提出 2–3 个公开 API 方案及代价；不静默选择高风险路径。

---

## 15. 决策待办（开工第一天必须关闭）

- [ ] 将最低 macOS 版本从产品假设转成已验证的 Xcode/SDK 可支持版本。
- [ ] 验证 `⌥ Space` 的全局快捷键实现、沙箱行为与冲突 UX。
- [ ] 用最小 Store target 验证发现/图标/启动能力；写明能与不能做的事情。
- [ ] 确定 JSON vs SQLite，并写 schema/备份/迁移策略。
- [ ] 决定启动后是否默认自动收起（建议是）以及多 Space 策略。
- [ ] 确定 Direct 更新机制是否进入 1.0（建议不阻塞核心版）。

本文件随实施更新版本号和变更记录；任何改变 P0 行为、权限范围或渠道能力的修改都必须经过显式产品决策。
