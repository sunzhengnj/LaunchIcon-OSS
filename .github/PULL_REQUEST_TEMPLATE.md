## 摘要

<!-- 用几句话说明改了什么、为什么。对应的 PRD P/M 或 Issue： -->

## 验证

- [ ] `./script/validate_background.sh`（或说明跳过原因）
- [ ] Core：`__ / __`（填写实际数字；未跑写「未跑」）
- [ ] Direct / StoreSpike Release `analyze`：
- [ ] UI：未跑 / 仅 `build-for-testing` / 有 xcresult（**禁止无证据声称通过**）
- [ ] 可见 UI 已获桌面主人同意（若适用）

## 检查

- [ ] 仅 Apple Public API；未读 Launchpad DB；未复制其他产品资源
- [ ] 无密钥 / 证书 / Team 凭据进入 diff
- [ ] WIP 已在标题标明（若尚未验证完毕）
