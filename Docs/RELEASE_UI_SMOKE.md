# DMG 内 Release App 的隔离 UI 冒烟（M4）

此用例直接启动下载 DMG 内的 Release 二进制，而不是 Xcode 的 Debug App；测搜索、可选的 70 项滚动搜索首行、两 App 合并与文件夹连续开合 10 次，不代表完整 UI、实体指针或公证验收。运行前确认桌面可占用，且只在健康仓库中操作。不要把包复制到 `/Applications`，不要使用用户正式布局。

以 preview.55 为例；每个新版替换 DMG 路径和标签。`verify_preview_package.sh` 要求 DMG 旁有同名 `.sha256`。运行前确认磁盘有足够空间供 Xcode 编译与结果包使用。

```bash
SMOKE_DMG=/private/tmp/LaunchIcon-search-overflow-20261003/LaunchIcon-v0.1.0-preview.55-macOS-unnotarized.dmg
SMOKE_TAG=v0.1.0-preview.55
SMOKE_DIR="$(mktemp -d /private/tmp/LaunchIcon-release-smoke.XXXXXX)"
SMOKE_MOUNT="$(mktemp -d /private/tmp/LaunchIcon-release-mount.XXXXXX)"
./script/verify_preview_package.sh "$SMOKE_DMG" "$SMOKE_TAG"
hdiutil attach -readonly -nobrowse -mountpoint "$SMOKE_MOUNT" "$SMOKE_DMG"
ditto "$SMOKE_MOUNT/LaunchIcon.app" "$SMOKE_DIR/LaunchIcon.app"
hdiutil detach "$SMOKE_MOUNT"
rmdir "$SMOKE_MOUNT"
codesign --verify --strict "$SMOKE_DIR/LaunchIcon.app"
mkdir -p "$SMOKE_DIR/Fixture/Applications"
ln -s /System/Applications/Calculator.app "$SMOKE_DIR/Fixture/Applications/Calculator.app"
ln -s /System/Applications/Clock.app "$SMOKE_DIR/Fixture/Applications/Clock.app"
for index in $(seq 1 70); do
  name="$(printf 'Fixture %02d' "$index")"
  info="$SMOKE_DIR/Fixture/Applications/$name.app/Contents/Info.plist"
  mkdir -p "$(dirname "$info")"
  plutil -create xml1 "$info"
  plutil -insert CFBundleIdentifier -string "com.sunzheng.LaunchIcon.UITest.Fixture$index" "$info"
  plutil -insert CFBundleName -string "$name" "$info"
  plutil -insert CFBundlePackageType -string APPL "$info"
done
xcodebuild build-for-testing -project LaunchIcon.xcodeproj -scheme LaunchIconUITests -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$SMOKE_DIR/DerivedData" -parallel-testing-enabled NO -quiet
SMOKE_RUN="$(find "$SMOKE_DIR/DerivedData/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
cp "$SMOKE_RUN" "$SMOKE_DIR/DerivedData/Build/Products/LaunchIconUITests_ReleasePackage.xctestrun"
SMOKE_RUN="$SMOKE_DIR/DerivedData/Build/Products/LaunchIconUITests_ReleasePackage.xctestrun"
/usr/libexec/PlistBuddy -c "Set :TestConfigurations:0:TestTargets:0:UITargetAppPath $SMOKE_DIR/LaunchIcon.app" "$SMOKE_RUN"
/usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:EnvironmentVariables:LAUNCHICON_UI_APP_PATH string $SMOKE_DIR/LaunchIcon.app" "$SMOKE_RUN"
/usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:EnvironmentVariables:LAUNCHICON_UI_FIXTURE_ROOT string $SMOKE_DIR/Fixture" "$SMOKE_RUN"
/usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:EnvironmentVariables:LAUNCHICON_UI_EXPECT_DENSE_SEARCH string 1" "$SMOKE_RUN"
xcodebuild test-without-building -xctestrun "$SMOKE_RUN" -destination 'platform=macOS,arch=arm64' -resultBundlePath "$SMOKE_DIR/ExternalSmoke.xcresult" -parallel-testing-enabled NO -only-testing:LaunchIconUITests/LauncherDragUITests/testExternalReleasePackageSearchAndFolderSmoke -quiet
xcrun xcresulttool get test-results summary --path "$SMOKE_DIR/ExternalSmoke.xcresult" --format json
```

验收时同时确认 `summary` 为 1/1、0 失败/跳过，`activities` 含 `Release package app: <SMOKE_DIR>/LaunchIcon.app` 与 `Fixture 07`，且该 App 的 `LaunchIconSourceCommit` 与标签提交一致。若冒烟失败，保留 `.xcresult`、检查夹具目录是否由主机预置；不要把 Runner 容器夹具读不到或 Runner 拒写 `/private/tmp` 直接归因于产品。Release 全套与实体输入另列验收，不以这一项替代。

要复测**已有布局**的文件夹，先由主机把布局复制到独立临时目录，不要把正式布局路径传给 App 或 Runner。沿用上面的 DMG App 与 `build-for-testing` 结果，另复制一份 `.xctestrun`，设置 `LAUNCHICON_UI_APP_PATH`、`LAUNCHICON_UI_EXISTING_LAYOUT_COPY_PATH`（指向副本）和 `LAUNCHICON_UI_EXISTING_FOLDER_LABEL`（例如 `文件夹 名称`）；只运行 `testExternalReleasePackageExistingFolderOpenClose`。此用例不设置扫描根，会读取本机应用目录；原件与副本的 SHA 应在测试前后分别核对。若 Runner 在 Automation Mode 初始化超时、产品方法 0 项，不得称文件夹回归已通过。
