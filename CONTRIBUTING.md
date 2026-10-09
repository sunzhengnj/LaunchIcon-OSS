# 参与 LaunchIcon 开发

感谢关注 LaunchIcon。本仓库以 **Apache-2.0** 开源。提交代码前请阅读 [AGENTS.md](AGENTS.md)（尤其是 AI / 编程助手）与 [Docs/LaunchIcon_PRD.md](Docs/LaunchIcon_PRD.md)。

## 反馈问题

1. 确认运行的是 [Releases](https://github.com/sunzhengnj/LaunchIcon-OSS/releases) 中的安装包，或你本地构建的明确提交。
2. 使用 [问题反馈表单](https://github.com/sunzhengnj/LaunchIcon-OSS/issues/new?template=bug_report.yml)。
3. 提供：安装包版本 / 构建号、macOS 版本、芯片、复现步骤、实际与预期结果。
4. 崩溃信息请脱敏：不要上传完整 `.ips`、布局、偏好或含个人路径的诊断日志。

安全漏洞请走 [SECURITY.md](SECURITY.md)，不要开公开 Issue。

## 开发环境

- macOS 26+
- Xcode 27（及对应 macOS SDK）
- 克隆本仓库后，在 Xcode 中为签名目标填写你自己的 `DEVELOPMENT_TEAM`

## 本地验证

默认先跑**不打开窗口**的质量门：

```bash
./script/validate_background.sh
```

它覆盖：网络 API 静态守卫、Core 测试、Direct / StoreSpike Release `analyze`、UI 测试目标编译。  
**编译通过 ≠ 真实界面通过。**

可见 UI / UI Runner / Direct bootstrap 会占用桌面，必须同时满足：

```bash
export LAUNCHICON_ALLOW_VISIBLE_TESTS=1
```

且**使用该电脑的人明确同意**当前时段可以抢占桌面。测试应使用隔离扫描根、布局与偏好，不触碰正式用户数据。

## Pull Request 规则

- 改动聚焦：对应 PRD 的 **P / M** 编号，或可复现的 bug
- 只用 **Apple Public API**；不读系统 Launchpad 数据库；不复制其他产品的商标、图片或专有资源
- Direct 与 Store 共享 **Core**；共用逻辑不要只修在单一渠道
- 保持 diff 可读；避免顺手大重构
- PR 描述写清：动机、成功标准、你跑过的验证（分开写 Core / analyze / UI / 安装包）
- 不要把本地未签名开发包称为「GitHub 下载版」

### 提交信息建议

- `fix:` / `feat:` / `test:` / `docs:` / `chore:` 前缀
- 正文说明「为什么」，必要时引用 Issue 编号

## AI / 编程助手（重要）

若你是 Cursor、Claude、Codex、Grok 或其他 coding agent，**必须先读 [AGENTS.md](AGENTS.md)**，并遵守：

1. **单写入者**：同一分支同一时刻只有一个写入者；改之前 `git fetch` + `git pull --ff-only`
2. **先验证再宣称完成**：至少跑 `./script/validate_background.sh`；没有 `xcodebuild` UI 结果时，**禁止**声称 UI 通过或「全绿」
3. **分开汇报**：Core、Release analyze、真实 UI、沙箱、安装包 / 签名，不得混写
4. **禁止**：把签名 / 公证凭据写入仓库；对 `main` force-push；覆盖来源不明的未提交改动；在未获桌面主人同意时启动可见 UI 测试
5. **WIP 必须标明**：未通过验证的提交或 PR 须标 `WIP`，不得称为里程碑完成
6. 公开仓更新节奏见 [Docs/SYNC_FROM_PRIVATE.md](Docs/SYNC_FROM_PRIVATE.md)；不要假设私有 WIP 都会出现在这里

## 行为准则

参与即表示同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
