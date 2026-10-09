# LaunchIcon — AI / Agent 开发规范

本文给 **AI 编程助手与自动化代理** 使用。人类贡献者也可对照。更细的协作约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 产品方向

- 功能上对齐「网格启动器」一类产品的**有用行为**：网格、文件夹、搜索、分页、拖拽整理、热键等，目标是接近可用。
- **禁止完整抄袭**：不要像素级仿制 Apple Launchpad 或其他商业启动器；不要复制对方 proprietary 资源 / 商标外观。交互与视觉必须形成 **LaunchIcon 自有风格**。
- 工程上只用 **Apple Public API**；不读系统 Launchpad 数据库、不用私有框架、不做屏幕录制 / 键盘监听绕过。

## 建议阅读顺序

1. [README.md](README.md)
2. 本文 `AGENTS.md`
3. [CONTRIBUTING.md](CONTRIBUTING.md)
4. [Docs/LaunchIcon_PRD.md](Docs/LaunchIcon_PRD.md)
5. [Docs/TEST_MATRIX.md](Docs/TEST_MATRIX.md)
6. [Docs/RELEASE_NOTES_1.0.0.md](Docs/RELEASE_NOTES_1.0.0.md)
7. 需要时再读 [Docs/API_AND_PERMISSION_NOTES.md](Docs/API_AND_PERMISSION_NOTES.md)、[Docs/RELEASE_PROCESS.md](Docs/RELEASE_PROCESS.md)

## 单写入者纪律

- 同一分支、同一时刻，只应有一个代理 / 人在改工作区。
- 开始前：`git fetch` 与 `git pull --ff-only`（无法快进时先停下来处理，绝不覆盖未知改动）。
- 完成**已验证**的改动后提交；推送到你的 fork / 分支，再开 PR。
- 未通过验证的 checkpoint 必须在提交说明或 PR 标题标 `WIP`。
- 不要对 `main` 做 force-push；不要改写已推送的公开历史。

## 工程约束

- Direct 与 StoreSpike **共享 Core**；渠道差异只留在 target、entitlements、Platform adapter。
- **主线程只做 AppKit UI**。扫描、图标预热、布局 I/O 必须可取消、可测试、有明确所有者。
- 每项改动对应 PRD 的 **P / M** 编号或已记录 bug；禁止顺手大范围重构。
- 不要提交：密钥、证书、notary profile、`.p12`、含 token 的 env、真实用户布局 / 偏好。
- `DEVELOPMENT_TEAM` 由本地开发者自行填写；不要把维护者 Team ID 或签名材料写回仓库。

## 验证与汇报矩阵

| 层级 | 如何证明 | 不能声称的内容 |
| --- | --- | --- |
| 后台质量门 | `./script/validate_background.sh` 退出 0 | 「UI 全绿」「用户可接受」 |
| Core | `xcodebuild` / `script/test_core.sh` 的实际结果 | 真实窗口行为 |
| 渠道静态分析 | Direct / StoreSpike Release `analyze` | 运行时沙箱通过 |
| UI 目标编译 | `build-for-testing` | UI 用例通过 |
| 真实 UI | 有 `LAUNCHICON_ALLOW_VISIBLE_TESTS=1` 且桌面主人同意；附 `xcodebuild` / xcresult 数字 | 在无结果时「感觉过了」 |
| 安装包 | 脚本输出 + codesign / 镜像检查记录 | 未跑公证却写「已公证」 |

**禁止**：用 Computer Use、手工点击观感或「我编译过了」代替 UI 测试结果。

## 禁止事项（硬规则）

- 私有框架、系统 Launchpad DB、未授权的辅助功能滥用
- 复制 LaunchOS / 其他产品的 UI、图标、文案资源
- 在仓库中存放或打印签名 / 公证 / API 凭据
- 未获同意启动会抢桌面的可见 UI 套件
- 宣称完整 UI suite 通过，却拿不出当次 `xcodebuild` 统计
- 把拖拽边缘自动翻页、捏合、热角、多选、Launchpad 布局导入等**未立项**能力当默认范围（以 PRD 为准）

## 公开仓与私有开发

维护者在私有仓持续开发；本公开仓在里程碑时接收清理后的导出。详见 [Docs/SYNC_FROM_PRIVATE.md](Docs/SYNC_FROM_PRIVATE.md)。

- 社区 PR 请对本仓库开
- 不要期望每一个私有 WIP 提交都出现在这里
- 内部交接文档（HANDOFF / TASKS / 每日审阅等）不会进入本仓

## 完成一轮改动时的检查清单

- [ ] 已 pull，工作区无未知他人改动被覆盖
- [ ] 改动可追溯到 P/M 或 bug
- [ ] `./script/validate_background.sh` 已跑（或说明为何无法在当前环境跑，且未虚假宣称通过）
- [ ] 汇报中 Core / UI / 包装分开书写
- [ ] 无密钥、无私人路径日志、无强制推送 `main`
