import AppKit
import XCTest

final class LauncherDragUITests: XCTestCase {
    @MainActor
    func testBlankBackgroundClickHidesLauncherWithoutQuitting() throws {
        try withFixture { app, _ in
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            let search = app.searchFields["搜索应用"]
            search.click()
            XCTAssertTrue(window.exists)

            window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).click()
            let hidden = expectation(
                for: NSPredicate(format: "exists == NO"),
                evaluatedWith: window,
                handler: nil
            )
            wait(for: [hidden], timeout: 3)
            XCTAssertNotEqual(app.state, .notRunning)
        }
    }

    @MainActor
    func testSecondHotkeyDuringDismissalReopensLauncher() throws {
        try withFixture(dismissDelayMS: 1_200) { app, _ in
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            app.typeKey(" ", modifierFlags: [.option])
            Thread.sleep(forTimeInterval: 0.25)
            app.typeKey(" ", modifierFlags: [.option])
            Thread.sleep(forTimeInterval: 1.25)
            XCTAssertTrue(window.exists)
            XCTAssertTrue(app.searchFields["搜索应用"].exists)
        }
    }

    @MainActor
    func testDraggingOneAppOntoAnotherCreatesFolder() throws {
        try withFixture(mergeDiagnostics: true) { app, layout in
            dragCalculatorOntoClock(in: app)
            let immediateFrame = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            immediateFrame.name = "Merge immediate frame"
            immediateFrame.lifetime = .keepAlways
            add(immediateFrame)
            Thread.sleep(forTimeInterval: 0.18)
            let inFlightFrame = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            inFlightFrame.name = "Merge in-flight frame"
            inFlightFrame.lifetime = .keepAlways
            add(inFlightFrame)
            Thread.sleep(forTimeInterval: 0.4)
            let settledFrame = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            settledFrame.name = "Merge settled frame"
            settledFrame.lifetime = .keepAlways
            add(settledFrame)
            let saved = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [saved], timeout: 5)
            let diagnosticLog = layout.deletingLastPathComponent().appendingPathComponent("diagnostics.log")
            assertMergeVisualsStarted(at: diagnosticLog, reducedMotion: false)
            let cleaned = expectation(
                for: NSPredicate { _, _ in
                    let text = (try? String(contentsOf: diagnosticLog, encoding: .utf8)) ?? ""
                    return text.contains("Merge cleanup: flyers=2 remaining=0 detached=true plateReady=true")
                },
                evaluatedWith: diagnosticLog,
                handler: nil
            )
            wait(for: [cleaned], timeout: 5)
            XCTAssertTrue(app.windows.firstMatch.exists)
        }
    }

    @MainActor
    func testReducedMotionFolderMergeCreatesOpenableFolder() throws {
        try withFixture(mergeDiagnostics: true) { app, layout in
            enableReducedMotion(in: app)

            dragCalculatorOntoClock(in: app)
            let saved = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [saved], timeout: 5)
            assertMergeVisualsStarted(at: layout.deletingLastPathComponent().appendingPathComponent("diagnostics.log"), reducedMotion: true)

            let folder = app.buttons["文件夹 新建文件夹"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.click()
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["时钟"].exists)

            let diagnosticLog = layout.deletingLastPathComponent().appendingPathComponent("diagnostics.log")
            app.typeKey(.escape, modifierFlags: [])
            // Reduced motion still routes through commitFolderPreviewGlyphFlight; assert end-state.
            let glyphCleaned = expectation(
                for: NSPredicate { _, _ in
                    let text = (try? String(contentsOf: diagnosticLog, encoding: .utf8)) ?? ""
                    return text.contains("Folder glyph cleanup:")
                        && text.contains("remaining=0")
                        && text.contains("detached=true")
                },
                evaluatedWith: diagnosticLog,
                handler: nil
            )
            wait(for: [glyphCleaned], timeout: 5)
            XCTAssertTrue(folder.exists, "Folder tile should remain after open/close")
        }
    }

    @MainActor
    func testDraggingThirdAppIntoFolderAddsMember() throws {
        try withFixture(systemApps: ["Calculator", "Clock", "TextEdit"]) { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            let folder = app.buttons["文件夹 新建文件夹"]
            let textEdit = app.buttons["文本编辑"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            XCTAssertTrue(textEdit.exists)
            textEdit.click(forDuration: 0.3, thenDragTo: folder)

            let expanded = expectation(
                for: NSPredicate(format: "isTrue == YES"),
                evaluatedWith: LayoutHasFolder(layout, expectedItemCount: 3),
                handler: nil
            )
            wait(for: [expanded], timeout: 5)
            folder.click()
            let panel = app.groups["文件夹 新建文件夹"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(panel.frame.width, 500)
            let member = app.buttons["文本编辑"]
            XCTAssertTrue(member.waitForExistence(timeout: 5))
            XCTAssertTrue(member.isEnabled)
            let window = app.windows.firstMatch
            XCTAssertTrue(window.exists)
            let outsidePanel = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            member.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: outsidePanel)

            let restored = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [restored], timeout: 5)
            XCTAssertTrue(app.groups["打开的文件夹 新建文件夹"].exists)
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertTrue(app.buttons["时钟"].exists)
            XCTAssertFalse(app.buttons["文本编辑"].exists)
            XCTAssertLessThanOrEqual(panel.frame.width, 500)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["文件夹 新建文件夹"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["文本编辑"].exists)
        }
    }

    @MainActor
    func testFolderAcceptsAnotherAppBeyondTwentyFiveMembers() throws {
        try withFixture(additionalApps: 24) { app, layout in
            app.terminate()
            try seedTwentyFiveMemberFolder(in: layout)
            app.launch()

            let folder = app.buttons["文件夹 满员测试"]
            let extra = app.buttons["Fixture 24"]
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            XCTAssertTrue(extra.exists)
            extra.click(forDuration: 0.3, thenDragTo: folder)

            let added = expectation(
                for: NSPredicate(format: "isTrue == YES"),
                evaluatedWith: LayoutHasFolder(layout, expectedItemCount: 26),
                handler: nil
            )
            wait(for: [added], timeout: 5)
            app.terminate()
            let saved = try LayoutSnapshot.load(from: layout)
            XCTAssertEqual(saved.folders.values.first?.itemIDs.count, 26)
            XCTAssertEqual(saved.orderedEntries.count, 1)
        }
    }

    @MainActor
    func testKeyboardFocusRevealsLastMemberOfFullFolder() throws {
        try withFixture(additionalApps: 24) { app, layout in
            app.terminate()
            try seedTwentyFiveMemberFolder(in: layout)
            app.launch()

            let folder = app.buttons["文件夹 满员测试"]
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            folder.click()

            let panel = app.groups["文件夹 满员测试"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(panel.frame.width, 780)

            let title = app.textFields["文件夹名称"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.click()
            for _ in 0..<26 {
                app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
            }

            let lastMember = app.buttons["Fixture 23"]
            XCTAssertTrue(lastMember.isHittable)
            let viewport = app.groups["打开的文件夹 满员测试"].scrollViews.firstMatch.frame
            XCTAssertTrue(viewport.contains(lastMember.frame), "viewport=\(viewport), last=\(lastMember.frame)")
        }
    }

    @MainActor
    func testNestedFolderDropShowsExplanationAndKeepsLayout() throws {
        try withFixture(additionalApps: 2) { app, layout in
            app.terminate()
            try seedTwoFolders(in: layout)
            let original = try LayoutSnapshot.load(from: layout)
            app.launch()

            let source = app.buttons["文件夹 测试 A"]
            let target = app.buttons["文件夹 测试 B"]
            XCTAssertTrue(source.waitForExistence(timeout: 15))
            XCTAssertTrue(target.exists)
            source.click(forDuration: 0.3, thenDragTo: target)

            XCTAssertTrue(app.groups["不能将文件夹放入另一个文件夹"].waitForExistence(timeout: 3))
            app.terminate()
            let saved = try LayoutSnapshot.load(from: layout)
            XCTAssertEqual(saved.folders.mapValues(\.name), original.folders.mapValues(\.name))
            XCTAssertEqual(saved.folders.mapValues(\.itemIDs), original.folders.mapValues(\.itemIDs))
            XCTAssertEqual(saved.orderedEntries.map(\.id), original.orderedEntries.map(\.id))
            XCTAssertEqual(saved.appKeys, original.appKeys)
        }
    }

    @MainActor
    func testFolderRenamePersistsAfterRestart() throws {
        try withFixture { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            app.buttons["文件夹 新建文件夹"].click()
            let title = app.textFields["文件夹名称"]
            beginFolderRename(title)
            // Begin-edit already selects all (folderTitleSelectsAllOnBeginEditing).
            // app.typeKey(⌘A) under UI Automation can miss the field editor.
            title.typeText("日常工具")
            title.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

            let renamed = expectation(
                for: NSPredicate(format: "isNamed == YES"),
                evaluatedWith: LayoutHasFolderName(layout, expectedName: "日常工具"),
                handler: nil
            )
            wait(for: [renamed], timeout: 5)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["文件夹 日常工具"].waitForExistence(timeout: 5))

            app.terminate()
            app.launch()
            let savedFolder = app.buttons["文件夹 日常工具"]
            XCTAssertTrue(savedFolder.waitForExistence(timeout: 15))
            savedFolder.click()
            XCTAssertEqual(app.textFields["文件夹名称"].value as? String, "日常工具")
        }
    }

    @MainActor
    func testDraggingOutOfTwoItemFolderDissolvesIt() throws {
        try withFixture(mergeDiagnostics: true) { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            let folder = app.buttons["文件夹 新建文件夹"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.click()
            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 5))
            let window = app.windows.firstMatch
            XCTAssertTrue(window.exists)
            XCTAssertFalse(window.frame.isEmpty)
            let outsidePanel = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            calculator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: outsidePanel)

            let immediateFrame = XCTAttachment(screenshot: window.screenshot())
            immediateFrame.name = "Folder dissolve immediate frame"
            immediateFrame.lifetime = .keepAlways
            add(immediateFrame)
            Thread.sleep(forTimeInterval: 0.5)
            let settledFrame = XCTAttachment(screenshot: window.screenshot())
            settledFrame.name = "Folder dissolve settled frame"
            settledFrame.lifetime = .keepAlways
            add(settledFrame)

            let dissolved = expectation(for: NSPredicate(format: "isDissolved == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [dissolved], timeout: 5)
            assertFolderCloses(app.groups["打开的文件夹 新建文件夹"])
            XCTAssertTrue(window.exists)
            XCTAssertTrue(calculator.waitForExistence(timeout: 5))
            XCTAssertTrue(calculator.isHittable)
            let clock = app.buttons["时钟"]
            XCTAssertTrue(clock.waitForExistence(timeout: 5))
            XCTAssertTrue(clock.isHittable)

            let diagnosticLog = layout.deletingLastPathComponent().appendingPathComponent("diagnostics.log")
            let scatterCleaned = expectation(
                for: NSPredicate { _, _ in
                    let text = (try? String(contentsOf: diagnosticLog, encoding: .utf8)) ?? ""
                    return text.contains("Scatter cleanup:")
                        && text.contains("remaining=0")
                        && text.contains("detached=true")
                        && text.contains("destinationsReady=true")
                },
                evaluatedWith: diagnosticLog,
                handler: nil
            )
            wait(for: [scatterCleaned], timeout: 5)

            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["时钟"].exists)
            XCTAssertFalse(app.buttons["文件夹 新建文件夹"].exists)
        }
    }

    @MainActor
    func testDraggingToTileEdgeReordersApps() throws {
        try withFixture(mergeDiagnostics: true) { app, layout in
            let calculator = app.buttons["计算器"]
            let clock = app.buttons["时钟"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            XCTAssertTrue(clock.exists)
            let original = try LayoutSnapshot.load(from: layout)
            let originalIDs = original.orderedEntries.compactMap(\.app?._0)
            XCTAssertEqual(originalIDs.count, 2)
            XCTAssertEqual(original.appKeys[originalIDs[0]], "bundle:com.apple.calculator")
            XCTAssertEqual(original.appKeys[originalIDs[1]], "bundle:com.apple.clock")
            XCTAssertLessThan(calculator.frame.minX, clock.frame.minX)

            let beforeCalculator = calculator.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            clock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: beforeCalculator)

            let reordered = expectation(
                for: NSPredicate(format: "isReordered == YES"),
                evaluatedWith: LayoutHasOrder(layout, expectedIDs: Array(originalIDs.reversed())),
                handler: nil
            )
            wait(for: [reordered], timeout: 5)
            XCTAssertTrue(calculator.isHittable)
            XCTAssertTrue(clock.isHittable)

            let diagnosticLog = layout.deletingLastPathComponent().appendingPathComponent("diagnostics.log")
            let dropCleaned = expectation(
                for: NSPredicate { _, _ in
                    let text = (try? String(contentsOf: diagnosticLog, encoding: .utf8)) ?? ""
                    return text.contains("Drop cleanup: flyerDetached=true")
                        && text.contains("pendingCleared=true")
                        && text.contains("itemCleared=true")
                },
                evaluatedWith: diagnosticLog,
                handler: nil
            )
            wait(for: [dropCleaned], timeout: 5)
        }
    }

    @MainActor
    func testDraggingIntoEmptyGridSlotMovesAppToEnd() throws {
        try withFixture { app, layout in
            let calculator = app.buttons["计算器"]
            let clock = app.buttons["时钟"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            XCTAssertTrue(clock.exists)
            let original = try LayoutSnapshot.load(from: layout)
            let originalIDs = original.orderedEntries.compactMap(\.app?._0)
            XCTAssertEqual(originalIDs.count, 2)

            let emptySlot = clock.coordinate(withNormalizedOffset: CGVector(dx: 1.5, dy: 0.5))
            calculator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: emptySlot)

            let reordered = expectation(
                for: NSPredicate(format: "isReordered == YES"),
                evaluatedWith: LayoutHasOrder(layout, expectedIDs: Array(originalIDs.reversed())),
                handler: nil
            )
            wait(for: [reordered], timeout: 5)
        }

        try withFixture(additionalApps: 35) { app, layout in
            let original = try LayoutSnapshot.load(from: layout)
            let originalIDs = original.orderedEntries.compactMap(\.app?._0)
            XCTAssertEqual(originalIDs.count, 37)
            app.buttons["第 2 页"].click()
            let first = app.buttons["Fixture 34"]
            let second = app.buttons["Fixture 35"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            XCTAssertTrue(second.exists)
            let emptySlot = second.coordinate(withNormalizedOffset: CGVector(dx: 1.5, dy: 0.5))
            first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: emptySlot)

            var expected = originalIDs
            expected.swapAt(35, 36)
            let reordered = expectation(
                for: NSPredicate(format: "isReordered == YES"),
                evaluatedWith: LayoutHasOrder(layout, expectedIDs: expected),
                handler: nil
            )
            wait(for: [reordered], timeout: 5)
        }
    }

    @MainActor
    func testDraggingOverPageArrowsTurnsAcrossMultiplePages() throws {
        try withFixture(additionalApps: 70) { app, layout in
            let original = try Data(contentsOf: layout)
            let calculator = app.buttons["计算器"]
            let nextPage = app.buttons["下一页"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            XCTAssertTrue(nextPage.exists)
            calculator.click(forDuration: 0.3, thenDragTo: nextPage, withVelocity: .slow, thenHoldForDuration: 1.7)
            let thirdPageApp = app.buttons["Fixture 70"]
            XCTAssertTrue(thirdPageApp.waitForExistence(timeout: 5))

            let previousPage = app.buttons["上一页"]
            XCTAssertTrue(previousPage.exists)
            thirdPageApp.click(forDuration: 0.3, thenDragTo: previousPage, withVelocity: .slow, thenHoldForDuration: 1.7)
            XCTAssertTrue(calculator.waitForExistence(timeout: 5))
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testSameTileDragKeepsLayoutAndAccessibilityOrder() throws {
        try withFixture { app, layout in
            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            let original = try Data(contentsOf: layout)
            calculator.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: calculator.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.5)))

            let appLabels = app.buttons.allElementsBoundByIndex.map(\.label)
                .filter { $0 == "计算器" || $0 == "时钟" }
            XCTAssertEqual(appLabels, ["计算器", "时钟"])
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testDraggingBeforeNextTileDoesNotRewriteLayout() throws {
        try withFixture { app, layout in
            let calculator = app.buttons["计算器"]
            let clock = app.buttons["时钟"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            XCTAssertTrue(clock.exists)
            let original = try Data(contentsOf: layout)
            calculator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: clock.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))

            XCTAssertTrue(calculator.isHittable)
            XCTAssertTrue(clock.isHittable)
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testDroppingOutsideLauncherCancelsDragWithoutChangingLayout() throws {
        try withFixture { app, layout in
            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            let original = try Data(contentsOf: layout)
            let window = app.windows.firstMatch
            XCTAssertTrue(window.exists)
            let outsideWindow = window.coordinate(withNormalizedOffset: CGVector(dx: -0.02, dy: 0.5))
            calculator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: outsideWindow)

            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testIncompleteScanRejectsDragWithoutChangingLayout() throws {
        try withFixture { app, layout in
            let original = try Data(contentsOf: layout)
            app.terminate()
            let brokenApp = layout.deletingLastPathComponent()
                .appendingPathComponent("Applications/Broken.app")
            try FileManager.default.createSymbolicLink(
                at: brokenApp,
                withDestinationURL: layout.deletingLastPathComponent()
                    .appendingPathComponent("Applications/Missing.app")
            )
            app.launch()

            let explanation = app.staticTexts["应用扫描不完整，暂时无法整理；请重新扫描"]
            XCTAssertTrue(explanation.waitForExistence(timeout: 15))
            let calculator = app.buttons["计算器"]
            let clock = app.buttons["时钟"]
            XCTAssertTrue(calculator.exists)
            XCTAssertTrue(clock.exists)
            let beforeCalculator = calculator.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
            clock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.3, thenDragTo: beforeCalculator)

            XCTAssertEqual(try Data(contentsOf: layout), original)
            XCTAssertFalse(app.buttons["文件夹 新建文件夹"].exists)
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testUninstallMenuDisablesForSystemProtectedApp() throws {
        // Fixture Calculator.app is a symlink into /System/Applications, so
        // eligibility disables uninstall while still offering hide/alias.
        try withFixture { app, layout in
            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            calculator.rightClick()
            let uninstall = app.menuItems["卸载应用…"]
            XCTAssertTrue(uninstall.waitForExistence(timeout: 5), "Uninstall item should appear while editing")
            XCTAssertFalse(uninstall.isEnabled, "System-protected apps must not enable uninstall")
            let hide = app.menuItems["隐藏应用"]
            XCTAssertTrue(hide.exists)
            XCTAssertTrue(hide.isEnabled)
            // Dismiss menu without choosing an item.
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    @MainActor
    func testUninstallMenuHiddenWhenScanIncomplete() throws {
        try withFixture { app, layout in
            app.terminate()
            let brokenApp = layout.deletingLastPathComponent()
                .appendingPathComponent("Applications/Broken.app")
            try FileManager.default.createSymbolicLink(
                at: brokenApp,
                withDestinationURL: layout.deletingLastPathComponent()
                    .appendingPathComponent("Applications/Missing.app")
            )
            app.launch()

            XCTAssertTrue(
                app.staticTexts["应用扫描不完整，暂时无法整理；请重新扫描"].waitForExistence(timeout: 15)
            )
            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            calculator.rightClick()
            // Since 4d59235 the item stays (disabled, with the read-only
            // reason as help) so VoiceOver can explain why it is unavailable.
            let uninstall = app.menuItems["卸载应用…"]
            if uninstall.waitForExistence(timeout: 1) {
                XCTAssertFalse(uninstall.isEnabled, "Read-only incomplete scan must not enable uninstall")
            }
            XCTAssertFalse(app.menuItems["设置别名…"].exists)
            XCTAssertFalse(app.menuItems["隐藏应用"].exists)
        }
    }

    @MainActor
    func testEmptyScanCanRestoreLastCompleteCatalogReadOnly() throws {
        try withFixture(mergeDiagnostics: true) { app, layout in
            let applications = layout.deletingLastPathComponent().appendingPathComponent("Applications")
            let snapshot = layout.deletingLastPathComponent().appendingPathComponent("catalog-v1.json")
            let originalLayout = try Data(contentsOf: layout)
            let originalSnapshot = try Data(contentsOf: snapshot)
            app.terminate()
            try FileManager.default.removeItem(at: applications.appendingPathComponent("Calculator.app"))
            try FileManager.default.removeItem(at: applications.appendingPathComponent("Clock.app"))
            app.launch()

            XCTAssertTrue(app.staticTexts["未找到可用的应用"].waitForExistence(timeout: 15))
            let restore = app.buttons["cachedCatalog.empty"]
            XCTAssertTrue(restore.waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["计算器"].exists)
            restore.click()
            XCTAssertTrue(app.windows.firstMatch.exists)
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["时钟"].exists)
            XCTAssertTrue(app.staticTexts["正在显示上次应用列表；重新扫描后可整理"].exists)
            let completedBefore = catalogReloadCompletionCount(beside: layout)
            app.buttons["重新扫描"].click()
            waitForCatalogReload(after: completedBefore, beside: layout)
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["时钟"].exists)
            XCTAssertTrue(app.staticTexts["正在显示上次应用列表；重新扫描后可整理"].exists)
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), originalLayout)
            XCTAssertEqual(try Data(contentsOf: snapshot), originalSnapshot)
        }
    }

    @MainActor
    func testIncompleteScanCanRestoreLastCompleteCatalogReadOnly() throws {
        try withFixture(mergeDiagnostics: true) { app, layout in
            let applications = layout.deletingLastPathComponent().appendingPathComponent("Applications")
            let snapshot = layout.deletingLastPathComponent().appendingPathComponent("catalog-v1.json")
            let originalLayout = try Data(contentsOf: layout)
            let originalSnapshot = try Data(contentsOf: snapshot)
            app.terminate()
            try FileManager.default.removeItem(at: applications.appendingPathComponent("Clock.app"))
            try FileManager.default.createSymbolicLink(
                at: applications.appendingPathComponent("Broken.app"),
                withDestinationURL: applications.appendingPathComponent("Missing.app")
            )
            app.launch()

            XCTAssertTrue(app.staticTexts["应用扫描不完整，暂时无法整理；请重新扫描"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertFalse(app.buttons["时钟"].exists)
            let restore = app.buttons["cachedCatalog.readOnly"]
            XCTAssertTrue(restore.waitForExistence(timeout: 5))
            restore.click()
            XCTAssertTrue(app.windows.firstMatch.exists)
            XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["正在显示上次应用列表；重新扫描后可整理"].exists)
            let completedBefore = catalogReloadCompletionCount(beside: layout)
            app.buttons["重新扫描"].click()
            waitForCatalogReload(after: completedBefore, beside: layout)
            XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["正在显示上次应用列表；重新扫描后可整理"].exists)
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), originalLayout)
            XCTAssertEqual(try Data(contentsOf: snapshot), originalSnapshot)
        }
    }

    @MainActor
    func testSearchResultsRejectDragWithoutChangingLayout() throws {
        try withFixture { app, layout in
            let original = try Data(contentsOf: layout)
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            search.click()
            search.typeText("c")

            let calculator = app.buttons["计算器"]
            let clock = app.buttons["时钟"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 5))
            XCTAssertTrue(clock.exists)
            let searchResultsReady = expectation(
                for: NSPredicate(format: "hittable == YES"),
                evaluatedWith: calculator,
                handler: nil
            )
            wait(for: [searchResultsReady], timeout: 5)
            calculator.click(forDuration: 0.3, thenDragTo: clock)

            XCTAssertEqual(try Data(contentsOf: layout), original)
            XCTAssertFalse(app.buttons["文件夹 新建文件夹"].exists)
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testClickingSearchResultLaunchesVisibleItem() throws {
        try withFixture(additionalApps: 1) { app, _ in
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            search.click()
            search.typeText("Fixture 01")

            let result = app.buttons["Fixture 01"]
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            let searchResultReady = expectation(
                for: NSPredicate(format: "hittable == YES"),
                evaluatedWith: result,
                handler: nil
            )
            wait(for: [searchResultReady], timeout: 5)
            result.click()
            XCTAssertTrue(app.groups["无法打开“Fixture 01”"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testLayoutSaveFailureShowsVisibleExplanation() throws {
        try withFixture { app, layout in
            let preserved = layout.deletingLastPathComponent().appendingPathComponent("layout-before-failure.json")
            try FileManager.default.moveItem(at: layout, to: preserved)
            try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: false)

            dragCalculatorOntoClock(in: app)
            XCTAssertTrue(app.groups["布局未保存，请检查磁盘空间或文件权限"].waitForExistence(timeout: 5))
            XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: layout.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)

            try FileManager.default.removeItem(at: layout)
            try FileManager.default.moveItem(at: preserved, to: layout)
            app.buttons["文件夹 新建文件夹"].click()
            let title = app.textFields["文件夹名称"]
            beginFolderRename(title)
            // Begin-edit already selects all (folderTitleSelectsAllOnBeginEditing).
            // app.typeKey(⌘A) under UI Automation can miss the field editor.
            title.typeText("恢复测试")
            title.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            let saved = expectation(
                for: NSPredicate(format: "isNamed == YES"),
                evaluatedWith: LayoutHasFolderName(layout, expectedName: "恢复测试"),
                handler: nil
            )
            wait(for: [saved], timeout: 5)
            let dismissed = expectation(
                for: NSPredicate(format: "exists == NO"),
                evaluatedWith: app.groups["布局未保存，请检查磁盘空间或文件权限"],
                handler: nil
            )
            wait(for: [dismissed], timeout: 3)
            XCTAssertFalse(app.staticTexts["布局未保存，请检查磁盘空间或文件权限"].exists)
        }
    }

    @MainActor
    func testLayoutSaveWarningSurvivesAnotherToast() throws {
        try withFixture(additionalApps: 1) { app, layout in
            let preserved = layout.deletingLastPathComponent().appendingPathComponent("layout-before-failure.json")
            try FileManager.default.moveItem(at: layout, to: preserved)
            try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: false)

            dragCalculatorOntoClock(in: app)
            XCTAssertTrue(app.groups["布局未保存，请检查磁盘空间或文件权限"].waitForExistence(timeout: 5))
            app.buttons["Fixture 01"].click()
            XCTAssertTrue(app.groups["无法打开“Fixture 01”"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["布局未保存，请检查磁盘空间或文件权限"].exists)
        }
    }

    @MainActor
    func testOpenFolderExposesOnlyModalAccessibilityControls() throws {
        try withFixture { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            let folder = app.buttons["文件夹 新建文件夹"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.click()

            let modal = app.groups["打开的文件夹 新建文件夹"]
            XCTAssertTrue(modal.waitForExistence(timeout: 5))
            XCTAssertTrue(modal.isEnabled)
            let folderScrollView = modal.scrollViews.firstMatch
            XCTAssertTrue(folderScrollView.exists)
            XCTAssertTrue(folderScrollView.isEnabled)
            XCTAssertEqual(folderScrollView.buttons.allElementsBoundByIndex.map(\.label), ["时钟", "计算器"])
            app.typeKey(XCUIKeyboardKey.tab, modifierFlags: .shift)
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            assertFolderCloses(modal)
            folder.click()
            XCTAssertTrue(modal.waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["文件夹名称"].exists)
            XCTAssertTrue(app.buttons["关闭文件夹"].exists)
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertTrue(app.buttons["时钟"].exists)
            XCTAssertTrue(app.buttons["计算器"].isEnabled)
            XCTAssertTrue(app.buttons["时钟"].isEnabled)
            XCTAssertFalse(app.buttons["设置"].exists)
            XCTAssertFalse(app.searchFields["搜索应用"].exists)
            XCTAssertFalse(folder.exists)

            app.typeText("Clock")
            app.typeKey("f", modifierFlags: .command)
            XCTAssertTrue(modal.exists)
            XCTAssertFalse(app.searchFields["搜索应用"].exists)
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertTrue(app.buttons["时钟"].exists)

            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            XCTAssertTrue(folder.isEnabled)
            XCTAssertTrue(app.buttons["设置"].exists)
            XCTAssertTrue(app.searchFields["搜索应用"].exists)
            assertFolderCloses(modal)

            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            XCTAssertTrue(modal.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testRepeatedFolderOpenCloseKeepsLayoutAndLauncherRunning() throws {
        try withFixture { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)
            let original = try LayoutSnapshot.load(from: layout)
            let folder = app.buttons["文件夹 新建文件夹"]
            let modal = app.groups["打开的文件夹 新建文件夹"]

            for _ in 0..<5 {
                XCTAssertTrue(folder.waitForExistence(timeout: 5))
                folder.click()
                XCTAssertTrue(modal.waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["计算器"].exists)
                XCTAssertTrue(app.buttons["时钟"].exists)
                app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
                assertFolderCloses(modal)
            }

            XCTAssertNotEqual(app.state, .notRunning)
            let saved = try LayoutSnapshot.load(from: layout)
            XCTAssertEqual(saved.orderedEntries.map(\.id), original.orderedEntries.map(\.id))
            XCTAssertEqual(saved.folders.values.first?.itemIDs, original.folders.values.first?.itemIDs)
            XCTAssertEqual(saved.appKeys, original.appKeys)
        }
    }

    @MainActor
    func testClosingUneditedFolderTitleDoesNotRewriteLayout() throws {
        try withFixture { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)
            app.terminate()
            app.launch()
            let folder = app.buttons["文件夹 新建文件夹"]
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            let original = try Data(contentsOf: layout)

            folder.click()
            let modal = app.groups["打开的文件夹 新建文件夹"]
            XCTAssertTrue(modal.waitForExistence(timeout: 5))
            app.buttons["关闭文件夹"].click()
            assertFolderCloses(modal)
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testRemovingAppWhileFolderIsOpenClosesDissolvedFolder() throws {
        try withFixture { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            let folder = app.buttons["文件夹 新建文件夹"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.click()
            let modal = app.groups["打开的文件夹 新建文件夹"]
            XCTAssertTrue(modal.waitForExistence(timeout: 5))

            let applications = layout.deletingLastPathComponent().appendingPathComponent("Applications")
            try FileManager.default.removeItem(at: applications.appendingPathComponent("Clock.app"))
            let dissolved = expectation(for: NSPredicate(format: "isDissolved == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [dissolved], timeout: 15)

            assertFolderCloses(modal)
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertTrue(app.searchFields["搜索应用"].isEnabled)
            XCTAssertNotEqual(app.state, .notRunning)
        }
    }

    @MainActor
    func testRemovingOneAppFromOpenThreeMemberFolderKeepsFolderOpen() throws {
        try withFixture(systemApps: ["Calculator", "Clock", "TextEdit"]) { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            let folder = app.buttons["文件夹 新建文件夹"]
            let textEdit = app.buttons["文本编辑"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            XCTAssertTrue(textEdit.exists)
            textEdit.click(forDuration: 0.3, thenDragTo: folder)
            let expanded = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout, expectedItemCount: 3), handler: nil)
            wait(for: [expanded], timeout: 5)

            folder.click()
            let modal = app.groups["打开的文件夹 新建文件夹"]
            XCTAssertTrue(modal.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["文本编辑"].exists)

            let applications = layout.deletingLastPathComponent().appendingPathComponent("Applications")
            try FileManager.default.removeItem(at: applications.appendingPathComponent("TextEdit.app"))
            let reduced = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [reduced], timeout: 15)

            XCTAssertTrue(modal.exists)
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertTrue(app.buttons["时钟"].exists)
            XCTAssertFalse(app.buttons["文本编辑"].exists)
            XCTAssertNotEqual(app.state, .notRunning)
        }
    }

    @MainActor
    func testFolderWithStaleMemberOpensAndKeepsValidApps() throws {
        try withFixture { app, layout in
            app.terminate()
            let validIDs = try seedFolderWithStaleMember(in: layout)
            app.launch()

            let folder = app.buttons["文件夹 失效成员"]
            let modal = app.groups["打开的文件夹 失效成员"]
            for _ in 0..<5 {
                XCTAssertTrue(folder.waitForExistence(timeout: 15))
                folder.click()
                XCTAssertTrue(modal.waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["计算器"].exists)
                XCTAssertTrue(app.buttons["时钟"].exists)
                app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
                assertFolderCloses(modal)
            }

            XCTAssertNotEqual(app.state, .notRunning)
            app.terminate()
            let saved = try LayoutSnapshot.load(from: layout)
            XCTAssertEqual(saved.folders.values.first?.itemIDs, validIDs)
            XCTAssertEqual(saved.orderedEntries.count, 1)
        }
    }

    @MainActor
    func testTwoItemFolderCentersItsMembers() throws {
        try withFixture { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            let folder = app.buttons["文件夹 新建文件夹"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.click()
            let panel = app.groups["文件夹 新建文件夹"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            let calculator = panel.buttons["计算器"]
            let clock = panel.buttons["时钟"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 5))
            XCTAssertTrue(clock.exists)
            XCTAssertLessThanOrEqual(panel.frame.width, 500)
            let membersCenter = (calculator.frame.midX + clock.frame.midX) / 2
            XCTAssertLessThan(abs(membersCenter - panel.frame.midX), 24)
            XCTAssertGreaterThan(abs(calculator.frame.midX - clock.frame.midX), 32)
        }
    }

    @MainActor
    func testFolderPanelStaysInsideNarrowWindow() throws {
        try withFixture(windowSize: "800x600") { app, layout in
            app.terminate()
            _ = try seedFolderWithStaleMember(in: layout)
            app.launch()

            let folder = app.buttons["文件夹 失效成员"]
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            folder.click()
            let panel = app.groups["文件夹 失效成员"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            let windowFrame = app.windows.firstMatch.frame
            XCTAssertGreaterThanOrEqual(panel.frame.minX, windowFrame.minX)
            XCTAssertLessThanOrEqual(panel.frame.maxX, windowFrame.maxX)
            XCTAssertLessThanOrEqual(panel.frame.width, 500)
            XCTAssertNotEqual(app.state, .notRunning)
        }
    }

    @MainActor
    func testFolderWithMismatchedRecordIDOpensAfterRecovery() throws {
        try withFixture { app, layout in
            app.terminate()
            let data = try Data(contentsOf: layout)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let entries = try XCTUnwrap(document["orderedEntries"] as? [[String: Any]])
            let memberIDs = try entries.map { entry in
                try XCTUnwrap((entry["app"] as? [String: String])?["_0"])
            }
            let folderID = UUID().uuidString
            document["orderedEntries"] = [["folder": ["_0": folderID]]]
            // UUID-keyed dictionaries use alternating key/value arrays in this layout JSON.
            document["folders"] = [folderID, [
                "id": UUID().uuidString,
                "name": "错位记录",
                "itemIDs": memberIDs,
                "createdAt": 0.0
            ]]
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: layout, options: .atomic)
            let seeded = try LayoutSnapshot.load(from: layout)
            let seededFolder = try XCTUnwrap(seeded.folders[try XCTUnwrap(UUID(uuidString: folderID))])
            XCTAssertNotEqual(seededFolder.id.uuidString, folderID)
            XCTAssertEqual(seededFolder.itemIDs.count, 2)
            app.launch()

            let folder = app.buttons["文件夹 错位记录"]
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            folder.click()
            XCTAssertTrue(app.groups["打开的文件夹 错位记录"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertTrue(app.buttons["时钟"].exists)
            app.terminate()
            let saved = try LayoutSnapshot.load(from: layout)
            XCTAssertEqual(saved.folders.values.first?.id.uuidString, folderID)
        }
    }

    @MainActor
    func testEscapeClosesFolderOpenedFromPinyinSearchAndKeepsQuery() throws {
        try withFixture { app, layout in
            app.terminate()
            try seedSearchableFolder(in: layout)
            app.launch()

            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            search.click()
            search.typeText("ceshi")

            let folder = app.buttons["文件夹 测试"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.click()
            XCTAssertTrue(app.groups["打开的文件夹 测试"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertTrue(app.buttons["时钟"].exists)

            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            XCTAssertEqual(search.value as? String, "ceshi")
            XCTAssertFalse(app.groups["打开的文件夹 测试"].exists)
            XCTAssertFalse(app.buttons["计算器"].exists)
            XCTAssertFalse(app.buttons["时钟"].exists)
        }
    }

    @MainActor
    func testPackageNameSearchSupportsSelectAllAndEscapeRestoresGrid() throws {
        try withFixture { app, _ in
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            search.click()
            search.typeText("Clock")
            XCTAssertEqual(search.value as? String, "Clock")

            let clock = app.buttons["时钟"]
            XCTAssertTrue(clock.waitForExistence(timeout: 5))
            XCTAssertTrue(clock.isEnabled)
            XCTAssertFalse(app.buttons["计算器"].exists)

            app.typeKey("a", modifierFlags: .command)
            search.typeText("Calculator")
            XCTAssertEqual(search.value as? String, "Calculator")
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertFalse(clock.exists)

            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["时钟"].exists)
        }
    }

    @MainActor
    func testSingleSearchResultIsCenteredBelowSearchField() throws {
        try withFixture { app, _ in
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            search.click()
            search.typeText("Calculator")

            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 5))
            XCTAssertEqual(calculator.frame.midX, search.frame.midX, accuracy: 24)
            XCTAssertFalse(app.buttons["时钟"].exists)
        }
    }

    @MainActor
    func testExternalReleasePackageSearchAndFolderSmoke() throws {
        guard let appPath = ProcessInfo.processInfo.environment["LAUNCHICON_UI_APP_PATH"],
              let fixturePath = ProcessInfo.processInfo.environment["LAUNCHICON_UI_FIXTURE_ROOT"] else {
            throw XCTSkip("Requires an externally prepared Release package fixture")
        }
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        XCTAssertNotNil(Bundle(url: appURL)?.object(forInfoDictionaryKey: "LaunchIconSourceCommit") as? String)
        XCTContext.runActivity(named: "Release package app: \(appURL.path)") { _ in }
        let app = XCUIApplication(url: appURL)
        let runID = UUID().uuidString
        let layoutURL = URL(fileURLWithPath: "\(fixturePath)/layout-v1-\(runID).json")
        app.launchEnvironment = [
            "LAUNCHICON_TEST_SCAN_ROOT": "\(fixturePath)/Applications",
            "LAUNCHICON_TEST_LAYOUT_PATH": layoutURL.path,
            "LAUNCHICON_TEST_PREFERENCES_SUITE": "com.sunzheng.LaunchIcon.UITests.\(UUID().uuidString)",
            "LAUNCHICON_TEST_WINDOW_SIZE": "1024x768",
            "LAUNCHICON_DIAGNOSTICS_PATH": "\(fixturePath)/diagnostics-\(runID).log",
            "LAUNCHICON_SHOW_ON_LAUNCH": "1"
        ]
        if ProcessInfo.processInfo.environment["LAUNCHICON_UI_INJECT_RPAC"] == "1" {
            app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = "/usr/lib/libRPAC.dylib"
            app.launchEnvironment["PERFC_ENABLE_EXTENDED_DIAGNOSTIC_FORMAT"] = "1"
            app.launchEnvironment["PERFC_ENABLE_PROFILE_MODE"] = "1"
            app.launchEnvironment["PERFC_SUPPRESS_SYSTEM_REPORTS"] = "1"
        }
        app.launch()
        defer { app.terminate() }

        let search = app.searchFields["搜索应用"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["时钟"].exists)
        search.click()
        search.typeText("Calculator")
        XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["时钟"].exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 5))

        if ProcessInfo.processInfo.environment["LAUNCHICON_UI_EXPECT_DENSE_SEARCH"] == "1" {
            search.click()
            search.typeText("Fixture")
            let first = app.buttons["Fixture 01"]
            let seventh = app.buttons["Fixture 07"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            XCTAssertTrue(seventh.waitForExistence(timeout: 5))
            XCTAssertEqual(first.frame.midY, seventh.frame.midY, accuracy: 2)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
        }

        dragCalculatorOntoClock(in: app)
        let immediateFrame = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        immediateFrame.name = "Release merge immediate frame"
        immediateFrame.lifetime = .keepAlways
        add(immediateFrame)
        Thread.sleep(forTimeInterval: 0.18)
        let inFlightFrame = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        inFlightFrame.name = "Release merge in-flight frame"
        inFlightFrame.lifetime = .keepAlways
        add(inFlightFrame)
        Thread.sleep(forTimeInterval: 0.4)
        let settledFrame = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        settledFrame.name = "Release merge settled frame"
        settledFrame.lifetime = .keepAlways
        add(settledFrame)
        let saved = expectation(
            for: NSPredicate(format: "isTrue == YES"),
            evaluatedWith: LayoutHasFolder(layoutURL),
            handler: nil
        )
        wait(for: [saved], timeout: 5)
        assertMergeVisualsStarted(at: URL(fileURLWithPath: "\(fixturePath)/diagnostics-\(runID).log"), reducedMotion: false)

        let folder = app.buttons["文件夹 新建文件夹"]
        let opened = app.groups["打开的文件夹 新建文件夹"]
        for _ in 0..<10 {
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.click()
            XCTAssertTrue(opened.waitForExistence(timeout: 5))
            app.buttons["关闭文件夹"].click()
            assertFolderCloses(opened)
            XCTAssertNotEqual(app.state, .notRunning)
        }

        folder.click()
        let title = app.textFields["文件夹名称"]
        beginFolderRename(title)
        // Begin-edit already selects all (folderTitleSelectsAllOnBeginEditing).
        // app.typeKey(⌘A) under UI Automation can miss the field editor.
        title.typeText("日常工具")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        app.buttons["关闭文件夹"].click()

        let renamed = app.buttons["文件夹 日常工具"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        renamed.click()
        beginFolderRename(title)
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
        XCTAssertEqual(title.value as? String, "日常工具")
        beginFolderRename(title)
        // Begin-edit already selects all (folderTitleSelectsAllOnBeginEditing).
        // app.typeKey(⌘A) under UI Automation can miss the field editor.
        title.typeText("DiscardReleaseDraft")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(title.value as? String, "日常工具")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))

        search.click()
        search.typeText("Calculator")
        XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["时钟"].exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(renamed.waitForExistence(timeout: 15))
        renamed.click()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "日常工具")
    }

    @MainActor
    func testExternalReleasePackageExistingFolderOpenClose() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let appPath = environment["LAUNCHICON_UI_APP_PATH"],
              let layoutPath = environment["LAUNCHICON_UI_EXISTING_LAYOUT_COPY_PATH"],
              let folderLabel = environment["LAUNCHICON_UI_EXISTING_FOLDER_LABEL"] else {
            throw XCTSkip("Requires a Release app and an externally prepared layout copy")
        }
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        XCTAssertNotNil(Bundle(url: appURL)?.object(forInfoDictionaryKey: "LaunchIconSourceCommit") as? String)
        XCTContext.runActivity(named: "Existing-layout Release package app: \(appURL.path)") { _ in }
        let app = XCUIApplication(url: appURL)
        app.launchEnvironment = [
            "LAUNCHICON_TEST_LAYOUT_PATH": layoutPath,
            "LAUNCHICON_TEST_PREFERENCES_SUITE": "com.sunzheng.LaunchIcon.UITests.\(UUID().uuidString)",
            "LAUNCHICON_TEST_WINDOW_SIZE": "1024x768",
            "LAUNCHICON_SHOW_ON_LAUNCH": "1"
        ]
        app.launch()
        defer { app.terminate() }

        let folder = app.buttons[folderLabel]
        let opened = app.groups["打开的\(folderLabel)"]
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        for _ in 0..<10 {
            folder.click()
            XCTAssertTrue(opened.waitForExistence(timeout: 5))
            app.buttons["关闭文件夹"].click()
            assertFolderCloses(opened)
            XCTAssertNotEqual(app.state, .notRunning)
        }
    }

    @MainActor
    func testDenseSearchKeepsSevenResultsOnFirstRow() throws {
        for windowSize in ["1024x768", "1920x1080"] {
            try withFixture(additionalApps: 70, windowSize: windowSize) { app, _ in
                let search = app.searchFields["搜索应用"]
                XCTAssertTrue(search.waitForExistence(timeout: 15))
                search.click()
                search.typeText("Fixture")

                let first = app.buttons["Fixture 01"]
                let seventh = app.buttons["Fixture 07"]
                XCTAssertTrue(first.waitForExistence(timeout: 5))
                XCTAssertTrue(seventh.waitForExistence(timeout: 5))
                XCTAssertEqual(first.frame.midY, seventh.frame.midY, accuracy: 2)
                if windowSize == "1920x1080" {
                    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                    screenshot.name = "Scrollable search stays seven columns"
                    screenshot.lifetime = .keepAlways
                    add(screenshot)
                }
            }
        }
    }

    @MainActor
    func testFooterHintsExposeGridAndSearchInteractions() throws {
        try withFixture(additionalApps: 34) { app, _ in
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["拖拽整理 · 悬停左右边缘跨页"].exists)
            XCTAssertTrue(app.staticTexts["← → 翻页 · Esc 返回"].exists)

            search.click()
            search.typeText("Calculator")
            XCTAssertTrue(app.staticTexts["按 Esc 清除搜索"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["拖拽整理 · 悬停左右边缘跨页"].exists)
            XCTAssertFalse(app.staticTexts["← → 翻页 · Esc 返回"].exists)
        }
    }

    @MainActor
    func testWhitespaceSearchPreservesPageAndTrimsMatchingQuery() throws {
        try withFixture(additionalApps: 34) { app, _ in
            let secondPage = app.buttons["第 2 页"]
            XCTAssertTrue(secondPage.waitForExistence(timeout: 15))
            secondPage.click()
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))

            let search = app.searchFields["搜索应用"]
            search.click()
            search.typeText("   ")
            XCTAssertTrue(secondPage.exists)
            XCTAssertTrue(app.buttons["Fixture 34"].exists)

            app.typeKey("a", modifierFlags: .command)
            app.typeText(" Calculator ")
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Fixture 34"].exists)
        }
    }

    @MainActor
    func testAliasSearchRefreshesAfterRenameAndRestart() throws {
        try withFixture { app, layout in
            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            calculator.rightClick()
            app.menuItems["设置别名…"].click()

            let alert = app.dialogs.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            let aliasField = alert.textFields["计算器 的别名"]
            XCTAssertGreaterThanOrEqual(aliasField.frame.width, 200)
            aliasField.click()
            pasteText("我的计算器", into: aliasField)
            alert.buttons["保存"].click()
            XCTAssertTrue(app.buttons["我的计算器"].waitForExistence(timeout: 5))

            let search = app.searchFields["搜索应用"]
            search.click()
            pasteText("我的", into: search)
            XCTAssertEqual(search.value as? String, "我的")
            XCTAssertTrue(app.buttons["我的计算器"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["时钟"].exists)

            app.terminate()
            XCTAssertTrue(try String(contentsOf: layout, encoding: .utf8).contains("我的计算器"))
            app.launch()
            XCTAssertTrue(app.buttons["我的计算器"].waitForExistence(timeout: 15))
            let searchAfterRestart = app.searchFields["搜索应用"]
            XCTAssertTrue(searchAfterRestart.waitForExistence(timeout: 15))
            searchAfterRestart.click()
            pasteText("我的", into: searchAfterRestart)
            let searchValueAfterRestart = (searchAfterRestart.value as? String) ?? "<missing>"
            let searchProbe = XCTAttachment(string: """
            searchValue=\(searchValueAfterRestart)
            searchExists=\(searchAfterRestart.exists)
            aliasButtonExists=\(app.buttons["我的计算器"].exists)
            clockExists=\(app.buttons["时钟"].exists)
            """)
            searchProbe.name = "Alias restart search probe"
            searchProbe.lifetime = .keepAlways
            add(searchProbe)
            XCTAssertEqual(searchValueAfterRestart, "我的")
            XCTAssertTrue(app.buttons["我的计算器"].waitForExistence(timeout: 5))
            let clockExistsAfterRestart = app.buttons["时钟"].exists
            if clockExistsAfterRestart {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Alias restart unexpected clock hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                let frame = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                frame.name = "Alias restart unexpected clock frame"
                frame.lifetime = .keepAlways
                add(frame)
            }
            XCTAssertFalse(clockExistsAfterRestart)
        }
    }

    @MainActor
    func testSavingUnchangedAliasDoesNotRewriteLayout() throws {
        try withFixture { app, layout in
            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            calculator.rightClick()
            app.menuItems["设置别名…"].click()
            let alert = app.dialogs.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            let aliasField = alert.textFields["计算器 的别名"]
            aliasField.click()
            pasteText("我的计算器", into: aliasField)
            alert.buttons["保存"].click()
            XCTAssertTrue(app.buttons["我的计算器"].waitForExistence(timeout: 5))
            app.terminate()
            app.launch()
            let original = try Data(contentsOf: layout)

            app.buttons["我的计算器"].rightClick()
            app.menuItems["设置别名…"].click()
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            alert.buttons["保存"].click()
            app.terminate()
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testTypingOnGridStartsSearchWithoutClickingField() throws {
        try withFixture { app, _ in
            let calculator = app.buttons["计算器"]
            XCTAssertTrue(calculator.waitForExistence(timeout: 15))
            app.typeText("Clock")
            XCTAssertEqual(app.searchFields["搜索应用"].value as? String, "Clock")
            XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 5))
            XCTAssertFalse(calculator.exists)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(calculator.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testEmptySearchFieldArrowsPageAndQueryArrowsStayInText() throws {
        try withFixture(additionalApps: 34) { app, _ in
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 15))
            search.click()
            XCTAssertEqual(search.value as? String, "")

            app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["计算器"].exists)
            XCTAssertEqual(search.value as? String, "")

            app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Fixture 34"].exists)

            search.typeText("Clock")
            XCTAssertEqual(search.value as? String, "Clock")
            XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 5))
            app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
            app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
            XCTAssertEqual(search.value as? String, "Clock")
            XCTAssertTrue(app.buttons["时钟"].exists)
            XCTAssertFalse(app.buttons["计算器"].exists)
            XCTAssertFalse(app.buttons["Fixture 34"].exists)
        }
    }

    @MainActor
    func testChromeBackspaceEditsQueryAndTypingAppends() throws {
        try withFixture { app, _ in
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            search.click()
            search.typeText("Clock")
            XCTAssertEqual(search.value as? String, "Clock")
            XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 5))

            app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
            app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
            XCTAssertEqual(search.value as? String, "Cloc")
            XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 5))

            app.typeText("k")
            XCTAssertEqual(search.value as? String, "Clock")
            XCTAssertTrue(app.buttons["时钟"].exists)
            XCTAssertFalse(app.buttons["计算器"].exists)

            app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
            app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command])
            XCTAssertEqual(search.value as? String, "")
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["时钟"].exists)
        }
    }

    @MainActor
    func testFullwidthClockQueryShowsTheClockResult() throws {
        try withFixture { app, _ in
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            search.click()
            let pasteboard = NSPasteboard.general
            let previousItems = pasteboard.pasteboardItems?.map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            defer {
                pasteboard.clearContents()
                if let previousItems { _ = pasteboard.writeObjects(previousItems) }
            }
            let query = "\u{FF23}\u{FF4C}\u{FF4F}\u{FF43}\u{FF4B}"
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString(query, forType: .string))
            search.typeKey("v", modifierFlags: .command)
            XCTAssertEqual(search.value as? String, query)
            XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["时钟"].isHittable)
            XCTAssertFalse(app.buttons["计算器"].exists)
        }
    }

    @MainActor
    func testEscapeCancelsFolderRenameAndSecondEscapeCloses() throws {
        try withFixture { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            app.buttons["文件夹 新建文件夹"].click()
            let title = app.textFields["文件夹名称"]
            beginFolderRename(title)
            title.typeText("草稿")
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

            XCTAssertEqual(title.value as? String, "新建文件夹")
            XCTAssertTrue(app.groups["打开的文件夹 新建文件夹"].waitForExistence(timeout: 5))
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["文件夹 新建文件夹"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.groups["打开的文件夹 新建文件夹"].exists)
        }
    }

    @MainActor
    func testFolderRenameThenSearchKeepsIndependentEditing() throws {
        try withFixture { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)

            app.buttons["文件夹 新建文件夹"].click()
            let title = app.textFields["文件夹名称"]
            beginFolderRename(title)
            // Begin-edit already selects all (folderTitleSelectsAllOnBeginEditing).
            // app.typeKey(⌘A) under UI Automation can miss the field editor.
            title.typeText("日常工具")
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            app.buttons["关闭文件夹"].click()

            let search = app.searchFields["搜索应用"]
            search.click()
            search.typeText("Calculator")
            // Folder members in search results carry their folder as context.
            XCTAssertTrue(app.buttons["计算器，文件夹 日常工具"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["时钟"].exists)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            let renamed = app.buttons["文件夹 日常工具"]
            XCTAssertTrue(renamed.waitForExistence(timeout: 5))
            renamed.click()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "日常工具")
        }
    }

    @MainActor
    func testFolderRenameDraftIsDiscardedWhenAnotherAppBecomesActive() throws {
        let calculator = XCUIApplication(bundleIdentifier: "com.apple.calculator")
        guard calculator.state == .notRunning else {
            throw XCTSkip("Calculator is already running; preserve the user's instance")
        }
        try withFixture(mergeDiagnostics: true) { app, layout in
            dragCalculatorOntoClock(in: app)
            let created = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [created], timeout: 5)
            let original = try Data(contentsOf: layout)

            app.buttons["文件夹 新建文件夹"].click()
            let title = app.textFields["文件夹名称"]
            beginFolderRename(title)
            // Begin-edit already selects all (folderTitleSelectsAllOnBeginEditing).
            // app.typeKey(⌘A) under UI Automation can miss the field editor.
            title.typeText("UncommittedFolderDraft")
            XCTAssertEqual(title.value as? String, "UncommittedFolderDraft")

            guard calculator.state == .notRunning else {
                throw XCTSkip("Calculator started during fixture setup; preserve that instance")
            }
            calculator.launch()
            defer { calculator.terminate() }
            XCTAssertTrue(calculator.windows.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(calculator.state, .runningForeground)
            app.activate()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "新建文件夹")
            XCTAssertEqual(try Data(contentsOf: layout), original)

            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["文件夹 新建文件夹"].waitForExistence(timeout: 15))
            XCTAssertEqual(try Data(contentsOf: layout), original)
        }
    }

    @MainActor
    func testFailedLaunchShowsAccessibleDismissibleToast() throws {
        try withFixture(additionalApps: 1) { app, _ in
            enableReducedMotion(in: app)
            let fixture = app.buttons["Fixture 01"]
            XCTAssertTrue(fixture.waitForExistence(timeout: 15))
            fixture.click()

            let toast = app.groups["无法打开“Fixture 01”"]
            XCTAssertTrue(toast.waitForExistence(timeout: 3))
            let close = app.buttons["关闭提示"]
            XCTAssertTrue(close.exists)
            close.click()
            let dismissed = expectation(
                for: NSPredicate(format: "exists == NO"),
                evaluatedWith: toast,
                handler: nil
            )
            wait(for: [dismissed], timeout: 3)
            XCTAssertTrue(app.windows.firstMatch.exists)
        }
    }

    @MainActor
    func testFailedLaunchUsesVisibleAliasInToast() throws {
        try withFixture(additionalApps: 1) { app, _ in
            let fixture = app.buttons["Fixture 01"]
            XCTAssertTrue(fixture.waitForExistence(timeout: 15))
            fixture.rightClick()
            app.menuItems["设置别名…"].click()

            let alert = app.dialogs.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            let aliasField = alert.textFields["Fixture 01 的别名"]
            aliasField.click()
            pasteText("我的常用应用", into: aliasField)
            alert.buttons["保存"].click()

            let renamed = app.buttons["我的常用应用"]
            XCTAssertTrue(renamed.waitForExistence(timeout: 5))
            renamed.click()
            XCTAssertTrue(app.groups["无法打开“我的常用应用”"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testReturnInSearchLaunchesFirstResult() throws {
        try withFixture(additionalApps: 1) { app, _ in
            let search = app.searchFields["搜索应用"]
            XCTAssertTrue(search.waitForExistence(timeout: 15))
            search.click()
            app.typeText("Fixture 01")
            XCTAssertTrue(app.buttons["Fixture 01"].waitForExistence(timeout: 5))
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            XCTAssertTrue(app.groups["无法打开“Fixture 01”"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testSecondPageShowsThirtySixthAppAndReturnsToFirstPage() throws {
        try withFixture(additionalApps: 34) { app, _ in
            let secondPage = app.buttons["第 2 页"]
            XCTAssertTrue(secondPage.waitForExistence(timeout: 15))
            XCTAssertGreaterThanOrEqual(secondPage.frame.width, 24)
            XCTAssertGreaterThanOrEqual(secondPage.frame.height, 24)
            XCTAssertTrue(app.buttons["计算器"].exists)
            XCTAssertFalse(app.buttons["Fixture 34"].exists)

            secondPage.click()
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Fixture 34"].isEnabled)
            XCTAssertFalse(app.buttons["计算器"].exists)
            app.searchFields["搜索应用"].click()
            app.typeText("NoSuchApp")
            // No-match copy now lives in the grid area (09cc55d, PRD).
            let noMatches = app.otherElements["search.empty"]
            XCTAssertTrue(noMatches.waitForExistence(timeout: 5))
            XCTAssertEqual(noMatches.label, "未找到匹配的应用")
            XCTAssertTrue(noMatches.staticTexts["按 Esc 清除搜索"].exists)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))

            app.buttons["第 1 页"].click()
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Fixture 34"].exists)

            app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))
            app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
        }
    }

    /// REOPEN-PAGE-BEHAVIOR-01 / daily T5. Always-home snaps while the window
    /// is hidden. This does not drive `showPage`.
    @MainActor
    func testReopenAlwaysHomeReturnsToFirstPage() throws {
        try withFixture(additionalApps: 34, buttonScript: true, reopenPageBehavior: "alwaysHome") { app, layout in
            let secondPage = app.buttons["第 2 页"]
            XCTAssertTrue(secondPage.waitForExistence(timeout: 15))
            secondPage.click()
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["计算器"].exists)

            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).click()
            let hidden = expectation(
                for: NSPredicate(format: "exists == NO"),
                evaluatedWith: window,
                handler: nil
            )
            wait(for: [hidden], timeout: 3)
            // Carbon hotkey has no window to type into after orderOut.
            // The debug script calls the same show() the hotkey uses.
            let script = layout.deletingLastPathComponent().appendingPathComponent("button-script")
            try Data("show-launcher".utf8).write(to: script, options: .atomic)
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 8))
            XCTAssertFalse(app.buttons["Fixture 34"].exists)
            XCTAssertTrue(app.buttons["第 2 页"].waitForExistence(timeout: 3))
        }
    }

    /// FOLDER-PAGE-KEYS-01 / daily T5. Page Down scrolls a tall folder.
    /// Closing it must still be on the main grid's first page.
    @MainActor
    func testFolderPageDownScrollsMembersWithoutTurningMainGrid() throws {
        try withFixture(additionalApps: 68) { app, layout in
            app.terminate()
            try seedLeadingFolder(in: layout, memberCount: 30, name: "翻页键")
            app.launch()

            let folder = app.buttons["文件夹 翻页键"]
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["Fixture 63"].exists)
            folder.click()

            let panel = app.groups["文件夹 翻页键"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            // Off-screen members are not in the AX tree. The sixth row starts
            // at Fixture 24; the fifth row's last icon is Fixture 23.
            XCTAssertTrue(app.buttons["Fixture 23"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Fixture 24"].exists)
            let calculator = app.buttons["计算器"]
            let focused = expectation(
                for: NSPredicate(format: "hasKeyboardFocus == true"),
                evaluatedWith: calculator,
                handler: nil
            )
            wait(for: [focused], timeout: 5)
            app.typeKey(XCUIKeyboardKey.pageDown, modifierFlags: [])
            XCTAssertTrue(app.buttons["Fixture 24"].waitForExistence(timeout: 3))

            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            let closed = expectation(
                for: NSPredicate(format: "exists == NO"),
                evaluatedWith: panel,
                handler: nil
            )
            wait(for: [closed], timeout: 3)
            XCTAssertTrue(folder.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["Fixture 63"].exists)

            app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
            XCTAssertTrue(app.buttons["Fixture 63"].waitForExistence(timeout: 5))
            XCTAssertFalse(folder.exists)
        }
    }

    /// GRID-KEY-WALK-01 / daily T5. Up and left at the first folder member
    /// stay there. The main grid is still on page 1 after the folder closes,
    /// and right arrow can still turn that page.
    @MainActor
    func testArrowAtFolderEdgeStaysInsideAndKeepsMainPage() throws {
        try withFixture(additionalApps: 36) { app, layout in
            app.terminate()
            try seedLeadingFolder(in: layout, memberCount: 2, name: "边缘")
            app.launch()

            let folder = app.buttons["文件夹 边缘"]
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["Fixture 35"].exists)
            folder.click()
            let panel = app.groups["文件夹 边缘"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            let calculator = app.buttons["计算器"]
            let focused = expectation(
                for: NSPredicate(format: "hasKeyboardFocus == true"),
                evaluatedWith: calculator,
                handler: nil
            )
            wait(for: [focused], timeout: 5)

            app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
            XCTAssertEqual(calculator.value(forKey: "hasKeyboardFocus") as? Bool, true)
            app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
            XCTAssertEqual(calculator.value(forKey: "hasKeyboardFocus") as? Bool, true)
            XCTAssertFalse(app.buttons["Fixture 35"].exists)

            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            let closed = expectation(
                for: NSPredicate(format: "exists == NO"),
                evaluatedWith: panel,
                handler: nil
            )
            wait(for: [closed], timeout: 3)
            XCTAssertTrue(folder.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["Fixture 35"].exists)
            app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
            XCTAssertTrue(app.buttons["Fixture 35"].waitForExistence(timeout: 5))
            XCTAssertFalse(folder.exists)
        }
    }

    @MainActor
    func testFullPageBoundariesAtThirtyFiveAndSeventyApps() throws {
        try withFixture(additionalApps: 33) { app, _ in
            XCTAssertTrue(app.buttons["Fixture 33"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["第 2 页"].exists)
            XCTAssertEqual(visibleAppLabels(in: app).count, 35)
        }

        try withFixture(additionalApps: 68) { app, _ in
            XCTAssertTrue(app.buttons["Fixture 33"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["Fixture 34"].exists)
            XCTAssertEqual(visibleAppLabels(in: app).count, 35)
            XCTAssertFalse(app.buttons["第 3 页"].exists)

            app.buttons["第 2 页"].click()
            XCTAssertTrue(app.buttons["Fixture 68"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Fixture 33"].exists)
            XCTAssertEqual(visibleAppLabels(in: app).count, 35)
            XCTAssertFalse(app.buttons["第 3 页"].exists)
        }
    }

    @MainActor
    func testSettingsShowsBuildIdentity() throws {
        try withFixture { app, _ in
            XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 15))
            app.buttons["设置"].click()
            let settings = app.windows["LaunchIcon 设置"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let identity = settings.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", "版本 ")
            ).firstMatch
            XCTAssertTrue(identity.waitForExistence(timeout: 5))
            XCTAssertNotNil((identity.value as? String)?.range(
                of: "版本 [0-9]+\\.[0-9]+\\.[0-9]+ \\([0-9]+\\) · 开发构建",
                options: .regularExpression
            ))
        }
    }

    @MainActor
    func testReducedMotionSettingPersistsAndPagingStillWorks() throws {
        try withFixture(additionalApps: 34) { app, _ in
            XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 15))
            app.buttons["设置"].click()
            let settings = app.windows["LaunchIcon 设置"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let reducedMotion = settings.checkBoxes["减少动态效果"]
            XCTAssertTrue(reducedMotion.exists)
            XCTAssertEqual(reducedMotion.value as? Int, 0)
            reducedMotion.click()
            XCTAssertEqual(reducedMotion.value as? Int, 1)

            app.terminate()
            app.launch()
            let secondPage = app.buttons["第 2 页"]
            XCTAssertTrue(secondPage.waitForExistence(timeout: 15))
            secondPage.click()
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["计算器"].exists)
            app.buttons["上一页"].click()
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.windows.firstMatch.exists)
            app.buttons["下一页"].click()
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.windows.firstMatch.exists)
            let search = app.searchFields["搜索应用"]
            search.click()
            app.typeText("Fixture 34")
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["计算器"].exists)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))

            app.buttons["设置"].click()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            XCTAssertEqual(settings.checkBoxes["减少动态效果"].value as? Int, 1)
        }
    }

    @MainActor
    func testSystemReducedMotionUpdatesOpenFolderBackdropAndScrollElasticity() throws {
        try withFixture(mergeDiagnostics: true, buttonScript: true) { app, layout in
            dragCalculatorOntoClock(in: app)
            let saved = expectation(for: NSPredicate(format: "isTrue == YES"), evaluatedWith: LayoutHasFolder(layout), handler: nil)
            wait(for: [saved], timeout: 5)
            let folder = app.buttons["文件夹 新建文件夹"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.click()
            XCTAssertTrue(app.buttons["计算器"].waitForExistence(timeout: 5))

            let normal = try sendTestSystemMotion(false, layout: layout)
            XCTAssertTrue(normal.contains("effective=false"), normal)
            XCTAssertTrue(normal.contains("folderOpen=true scaled=true blurred=true searchElasticityNone=false folderElasticityNone=false"), normal)
            let reduced = try sendTestSystemMotion(true, layout: layout)
            XCTAssertTrue(reduced.contains("effective=true changed=true folderOpen=true scaled=false blurred=false searchElasticityNone=true folderElasticityNone=true"), reduced)

            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            app.buttons["设置"].click()
            let settings = app.windows["LaunchIcon 设置"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let appMotion = settings.checkBoxes["减少动态效果"]
            XCTAssertTrue(appMotion.waitForExistence(timeout: 5))
            appMotion.click()
            XCTAssertEqual(appMotion.value as? Int, 1)
            let unchanged = try sendTestSystemMotion(false, layout: layout)
            XCTAssertTrue(unchanged.contains("effective=true changed=false"), unchanged)
        }
    }

    @MainActor
    func testSearchClearButtonRestoresPageAndKeepsSearchReady() throws {
        try withFixture(additionalApps: 34) { app, _ in
            let secondPage = app.buttons["第 2 页"]
            XCTAssertTrue(secondPage.waitForExistence(timeout: 15))
            secondPage.click()
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))

            let search = app.searchFields["搜索应用"]
            search.click()
            search.typeText("Fixture 34")
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))
            let clear = search.buttons.matching(
                NSPredicate(format: "label IN %@", ["清除搜索", "cancel", "Cancel", "取消"])
            ).firstMatch
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
            clear.click()
            XCTAssertEqual(search.value as? String, "")
            XCTAssertTrue(app.buttons["Fixture 34"].waitForExistence(timeout: 5))

            app.typeText("Clock")
            XCTAssertEqual(search.value as? String, "Clock")
            XCTAssertTrue(app.buttons["时钟"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Fixture 34"].exists)
        }
    }

    @MainActor
    private func pasteText(_ text: String, into element: XCUIElement) {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if let previousItems { _ = pasteboard.writeObjects(previousItems) }
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        element.typeKey("v", modifierFlags: .command)
    }

    private func withFixture(
        systemApps: [String] = ["Calculator", "Clock"],
        additionalApps: Int = 0,
        windowSize: String = "1024x768",
        dismissDelayMS: Int? = nil,
        mergeDiagnostics: Bool = false,
        buttonScript: Bool = false,
        reopenPageBehavior: String? = nil,
        _ body: (XCUIApplication, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-UITests-\(UUID().uuidString)", isDirectory: true)
        let applications = directory.appendingPathComponent("Applications", isDirectory: true)
        let layout = directory.appendingPathComponent("layout-v1.json")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in systemApps {
            try FileManager.default.createSymbolicLink(
                at: applications.appendingPathComponent("\(name).app"),
                withDestinationURL: URL(fileURLWithPath: "/System/Applications/\(name).app")
            )
        }
        for number in 1..<(additionalApps + 1) {
            let name = String(format: "Fixture %02d", number)
            let contents = applications.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.sunzheng.LaunchIcon.UITest.Fixture\(number)",
                "CFBundleName": name,
                "CFBundlePackageType": "APPL"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }

        let app = XCUIApplication()
        let preferencesSuite = "com.sunzheng.LaunchIcon.UITests.\(UUID().uuidString)"
        app.launchEnvironment = [
            "LAUNCHICON_TEST_SCAN_ROOT": applications.path,
            "LAUNCHICON_TEST_LAYOUT_PATH": layout.path,
            "LAUNCHICON_TEST_PREFERENCES_SUITE": preferencesSuite,
            "LAUNCHICON_TEST_WINDOW_SIZE": windowSize,
            "LAUNCHICON_SHOW_ON_LAUNCH": "1"
        ]
        if ProcessInfo.processInfo.environment["LAUNCHICON_UI_INJECT_RPAC"] == "1" {
            app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = "/usr/lib/libRPAC.dylib"
            app.launchEnvironment["PERFC_ENABLE_EXTENDED_DIAGNOSTIC_FORMAT"] = "1"
            app.launchEnvironment["PERFC_ENABLE_PROFILE_MODE"] = "1"
            app.launchEnvironment["PERFC_SUPPRESS_SYSTEM_REPORTS"] = "1"
        }
        if ProcessInfo.processInfo.environment["LAUNCHICON_UI_FIELD_EDITOR_AUDIT"] == "1" {
            app.launchEnvironment["LAUNCHICON_TEST_FIELD_EDITOR_AUDIT"] = "1"
        }
        if mergeDiagnostics {
            app.launchEnvironment["LAUNCHICON_DIAGNOSTICS_PATH"] = directory.appendingPathComponent("diagnostics.log").path
        }
        if buttonScript {
            app.launchEnvironment["LAUNCHICON_TEST_BUTTON_SCRIPT"] = directory.appendingPathComponent("button-script").path
        }
        if let dismissDelayMS {
            app.launchEnvironment["LAUNCHICON_TEST_DISMISS_DELAY_MS"] = String(dismissDelayMS)
        }
        if let reopenPageBehavior {
            app.launchEnvironment["LAUNCHICON_TEST_REOPEN_PAGE_BEHAVIOR"] = reopenPageBehavior
        }
        app.launch()
        defer { app.terminate() }

        let ready = expectation(
            for: NSPredicate(format: "isReady == YES"),
            evaluatedWith: LayoutHasOrder(layout, expectedCount: systemApps.count + additionalApps),
            handler: nil
        )
        wait(for: [ready], timeout: 15)

        try body(app, layout)
    }

    @MainActor
    private func sendTestSystemMotion(_ enabled: Bool, layout: URL) throws -> String {
        let directory = layout.deletingLastPathComponent()
        let script = directory.appendingPathComponent("button-script")
        let diagnostics = directory.appendingPathComponent("diagnostics.log")
        try Data("system-reduce-motion:\(enabled ? "on" : "off")".utf8).write(to: script, options: .atomic)
        for _ in 0..<50 {
            let pending = (try? Data(contentsOf: script)) ?? Data()
            let lines = ((try? String(contentsOf: diagnostics, encoding: .utf8)) ?? "")
                .split(separator: "\n")
            if pending.isEmpty, let event = lines.last(where: { $0.contains("System motion:") }) {
                return String(event)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("System motion test command was not handled")
        return ""
    }

    @MainActor
    private func enableReducedMotion(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 15))
        app.buttons["设置"].click()
        let settings = app.windows["LaunchIcon 设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let reducedMotion = settings.checkBoxes["减少动态效果"]
        XCTAssertTrue(reducedMotion.waitForExistence(timeout: 5))
        reducedMotion.click()
        XCTAssertEqual(reducedMotion.value as? Int, 1)
        app.terminate()
        app.launch()
    }

    @MainActor
    private func assertFolderCloses(_ modal: XCUIElement) {
        let closed = expectation(
            for: NSPredicate(format: "exists == NO"),
            evaluatedWith: modal,
            handler: nil
        )
        wait(for: [closed], timeout: 3)
    }

    @MainActor
    private func dragCalculatorOntoClock(in app: XCUIApplication) {
        let calculator = app.buttons["计算器"]
        let clock = app.buttons["时钟"]
        XCTAssertTrue(calculator.waitForExistence(timeout: 15))
        XCTAssertTrue(clock.waitForExistence(timeout: 15))
        calculator.click(forDuration: 0.3, thenDragTo: clock)
    }

    /// Pointer rename requires clickCount ≥ 2 (74114f3). A single AX click
    /// synthesizes mouseDown with clickCount 1 and never opens the field editor.
    /// Retry until the field editor has keyboard focus — open chrome landing
    /// and UI Automation focus handoff can miss a single double-click.
    /// macOS XCUIElement has no `hasKeyboardFocus` Swift property; use KVC /
    /// NSPredicate instead.
    @MainActor
    private func beginFolderRename(_ title: XCUIElement) {
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let hittable = expectation(
            for: NSPredicate(format: "isHittable == YES"),
            evaluatedWith: title,
            handler: nil
        )
        _ = XCTWaiter.wait(for: [hittable], timeout: 3)
        // One double-click opens the editor (product reconstructs clickCount==1
        // pairs under UI Automation). Wait for AX keyboard focus — product
        // publishes focus on the TextField while the field editor is up
        // (FOLDER-TITLE-AM-BEGIN-01). One extra double-click only if the first
        // miss left the field still unfocused (chrome lag).
        // Fixtures enable single-click rename begin (LAUNCHICON_TEST_LAYOUT_PATH).
        // Prefer click; fall back to doubleClick for older product builds.
        title.click()
        let focused = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: title,
            handler: nil
        )
        if XCTWaiter.wait(for: [focused], timeout: 1.2) != .completed {
            title.doubleClick()
            let focusedRetry = expectation(
                for: NSPredicate(format: "hasKeyboardFocus == true"),
                evaluatedWith: title,
                handler: nil
            )
            _ = XCTWaiter.wait(for: [focusedRetry], timeout: 1.2)
        }
        if (title.value(forKey: "hasKeyboardFocus") as? Bool) == true {
            title.typeKey("a", modifierFlags: .command)
        }
    }

    @MainActor
    private func assertMergeVisualsStarted(at log: URL, reducedMotion: Bool) {
        // A new folder sends both icons into the preview slots. Dropping onto a
        // folder that already exists logs icons=1 and does not spring the tile.
        // A full plate logs the center landing instead. Reduced motion still
        // fades the dragged picture and the folder tile.
        let expected = reducedMotion
            ? [
                "Merge flyer started: reducedMotion=true",
                "Folder landing started: reducedMotion=true"
            ]
            : [
                "Merge preview landing started: icons=2 reducedMotion=false"
            ]
        for _ in 0..<30 {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if expected.allSatisfy(text.contains) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let actual = (try? String(contentsOf: log, encoding: .utf8)) ?? "<no diagnostic log>"
        XCTFail("Merge visual callbacks did not start: \(actual)")
    }

    private func catalogReloadCompletionCount(beside layout: URL) -> Int {
        let log = layout.deletingLastPathComponent().appendingPathComponent("diagnostics.log")
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .components(separatedBy: "Catalog reload finished:").count - 1
    }

    private func waitForCatalogReload(after count: Int, beside layout: URL) {
        for _ in 0..<150 {
            if catalogReloadCompletionCount(beside: layout) > count { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("Catalog reload did not finish after the recovery view requested a retry")
    }

    @MainActor
    private func visibleAppLabels(in app: XCUIApplication) -> [String] {
        app.buttons.allElementsBoundByIndex.map(\.label).filter {
            $0 == "计算器" || $0 == "时钟" || $0.hasPrefix("Fixture ")
        }
    }

    private func seedLeadingFolder(in layout: URL, memberCount: Int, name: String) throws {
        let data = try Data(contentsOf: layout)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(document["orderedEntries"] as? [[String: Any]])
        XCTAssertGreaterThan(entries.count, memberCount)
        let memberIDs = try entries.prefix(memberCount).map { entry in
            try XCTUnwrap((entry["app"] as? [String: String])?["_0"])
        }
        let folderID = UUID().uuidString
        document["orderedEntries"] = [["folder": ["_0": folderID]]] + Array(entries.dropFirst(memberCount))
        document["folders"] = [folderID, [
            "id": folderID,
            "name": name,
            "itemIDs": memberIDs,
            "createdAt": 0.0
        ]]
        let seeded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try seeded.write(to: layout, options: .atomic)
        XCTAssertEqual(try LayoutSnapshot.load(from: layout).folders.count, 1)
        XCTAssertEqual(try LayoutSnapshot.load(from: layout).folders.values.first?.itemIDs.count, memberCount)
    }

    private func seedTwentyFiveMemberFolder(in layout: URL) throws {
        let data = try Data(contentsOf: layout)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(document["orderedEntries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 26)
        let memberIDs = try entries.prefix(25).map { entry in
            try XCTUnwrap((entry["app"] as? [String: String])?["_0"])
        }
        let folderID = UUID().uuidString
        document["orderedEntries"] = [["folder": ["_0": folderID]]] + Array(entries.dropFirst(25))
        document["folders"] = [folderID, [
            "id": folderID,
            "name": "满员测试",
            "itemIDs": memberIDs,
            "createdAt": 0.0
        ]]
        let seeded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try seeded.write(to: layout, options: .atomic)
        XCTAssertEqual(try LayoutSnapshot.load(from: layout).folders.count, 1)
    }

    private func seedSearchableFolder(in layout: URL) throws {
        let data = try Data(contentsOf: layout)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(document["orderedEntries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        let memberIDs = try entries.map { entry in
            try XCTUnwrap((entry["app"] as? [String: String])?["_0"])
        }
        let folderID = UUID().uuidString
        document["orderedEntries"] = [["folder": ["_0": folderID]]]
        document["folders"] = [folderID, [
            "id": folderID,
            "name": "测试",
            "itemIDs": memberIDs,
            "createdAt": 0.0
        ]]
        let seeded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try seeded.write(to: layout, options: .atomic)
        XCTAssertEqual(try LayoutSnapshot.load(from: layout).folders.count, 1)
    }

    private func seedTwoFolders(in layout: URL) throws {
        let data = try Data(contentsOf: layout)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(document["orderedEntries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 4)
        let memberIDs = try entries.map { entry in
            try XCTUnwrap((entry["app"] as? [String: String])?["_0"])
        }
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        document["orderedEntries"] = [
            ["folder": ["_0": firstID]],
            ["folder": ["_0": secondID]]
        ]
        document["folders"] = [
            firstID, ["id": firstID, "name": "测试 A", "itemIDs": Array(memberIDs.prefix(2)), "createdAt": 0.0],
            secondID, ["id": secondID, "name": "测试 B", "itemIDs": Array(memberIDs.suffix(2)), "createdAt": 0.0]
        ]
        let seeded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try seeded.write(to: layout, options: .atomic)
        XCTAssertEqual(try LayoutSnapshot.load(from: layout).folders.count, 2)
    }

    private func seedFolderWithStaleMember(in layout: URL) throws -> [UUID] {
        let data = try Data(contentsOf: layout)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(document["orderedEntries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        let memberIDs = try entries.map { entry in
            try XCTUnwrap((entry["app"] as? [String: String])?["_0"])
        }
        let folderID = UUID().uuidString
        document["orderedEntries"] = [["folder": ["_0": folderID]]]
        document["folders"] = [folderID, [
            "id": folderID,
            "name": "失效成员",
            "itemIDs": [memberIDs[0], UUID().uuidString, memberIDs[1]],
            "createdAt": 0.0
        ]]
        let seeded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try seeded.write(to: layout, options: .atomic)
        XCTAssertEqual(try LayoutSnapshot.load(from: layout).folders.count, 1)
        return try memberIDs.map { try XCTUnwrap(UUID(uuidString: $0)) }
    }
}

private final class LayoutHasFolder: NSObject {
    private let url: URL
    private let expectedItemCount: Int

    init(_ url: URL, expectedItemCount: Int = 2) {
        self.url = url
        self.expectedItemCount = expectedItemCount
    }

    @objc dynamic var isTrue: Bool {
        guard let data = try? Data(contentsOf: url),
              let layout = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else { return false }
        return layout.folders.count == 1 && layout.folders.values.first?.itemIDs.count == expectedItemCount
    }

    @objc dynamic var isDissolved: Bool {
        guard let data = try? Data(contentsOf: url),
              let layout = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else { return false }
        return layout.folders.isEmpty
    }
}

private final class LayoutHasOrder: NSObject {
    private let url: URL
    private let expectedIDs: [UUID]
    private let expectedCount: Int

    init(_ url: URL, expectedIDs: [UUID] = [], expectedCount: Int = 2) {
        self.url = url
        self.expectedIDs = expectedIDs
        self.expectedCount = expectedCount
    }

    @objc dynamic var isReady: Bool {
        guard let layout = try? LayoutSnapshot.load(from: url) else { return false }
        return layout.orderedEntries.compactMap(\.app?._0).count == expectedCount
    }

    @objc dynamic var isReordered: Bool {
        guard let layout = try? LayoutSnapshot.load(from: url) else { return false }
        return layout.orderedEntries.compactMap(\.app?._0) == expectedIDs
    }
}

private final class LayoutHasFolderName: NSObject {
    private let url: URL
    private let expectedName: String

    init(_ url: URL, expectedName: String) {
        self.url = url
        self.expectedName = expectedName
    }

    @objc dynamic var isNamed: Bool {
        guard let layout = try? LayoutSnapshot.load(from: url) else { return false }
        return layout.folders.values.first?.name == expectedName
    }
}

private struct LayoutSnapshot: Decodable {
    let folders: [UUID: Folder]
    let orderedEntries: [Entry]
    let appKeys: [UUID: String]

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    struct Entry: Decodable {
        let app: TaggedID?
        let folder: TaggedID?

        var id: UUID? { app?._0 ?? folder?._0 }
    }

    struct TaggedID: Decodable {
        let _0: UUID
    }

    struct Folder: Decodable {
        let id: UUID
        let name: String
        let itemIDs: [UUID]
    }
}
