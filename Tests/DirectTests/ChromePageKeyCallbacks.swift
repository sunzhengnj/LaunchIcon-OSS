// Compiled by script/test_chrome_page_key_callbacks.py, not the Core/UI targets.
// The spy observes whether production keyDown calls super, not NSButton internals.
@MainActor
private class FallbackRecordingButton: NSButton {
    var fallbackEvents: [NSEvent] = []
    override func keyDown(with event: NSEvent) { fallbackEvents.append(event) }
}

// Type-only fixture for the production helper. A rootless button must never
// reach this method; neither the probe policy nor resolver is stubbed at runtime.
@MainActor
private final class LauncherRootView: NSView {
    func keyboardProbe(
        character: String?, keyCode: UInt16,
        command: Bool, shift: Bool, option: Bool, control: Bool,
        isEditingText: Bool
    ) -> LauncherLayout.KeyboardProbe {
        fatalError("root probe is outside this rootless-button fixture")
    }
}

// PRODUCTION INSERTION
var failures = 0
var eventCount = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

// All 16 Cmd/Shift/Option/Control combinations must keep the old keyCode policy.
let modifierBits: [NSEvent.ModifierFlags] = [.command, .shift, .option, .control]
for keyCode: UInt16 in [116, 121] {
    let direction = keyCode == 116 ? -1 : 1
    let characters = keyCode == 116 ? "\u{F72C}" : "\u{F72D}"
    for mask in 0..<16 {
        var modifiers: NSEvent.ModifierFlags = []
        for (index, flag) in modifierBits.enumerated() where mask & (1 << index) != 0 {
            modifiers.insert(flag)
        }
        for acceptsVertical in [false, true] {
            for hasPageHandler in [false, true] {
                let label = "key=\(keyCode) modifiers=\(mask) vertical=\(acceptsVertical) page=\(hasPageHandler)"
                let button = LauncherChromeButton(frame: .zero)
                check(button.window == nil, "fixture must stay rootless")
                var verticalDirections: [Int] = []
                var pageDirections: [Int] = []
                button.onVerticalPage = { value in
                    verticalDirections.append(value)
                    return acceptsVertical
                }
                if hasPageHandler { button.onPage = { pageDirections.append($0) } }
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: keyCode
                )!
                eventCount += 1
                button.keyDown(with: event)
                check(verticalDirections == [direction], "vertical callback exactly once: \(label)")
                let pages = !acceptsVertical && hasPageHandler ? [direction] : []
                check(pageDirections == pages, "vertical before paging: \(label)")
                let fallbackCount = !acceptsVertical && !hasPageHandler ? 1 : 0
                check(button.fallbackEvents.count == fallbackCount, "super fallback: \(label)")
                if let forwarded = button.fallbackEvents.first {
                    check(forwarded === event, "forward original event: \(label)")
                }
            }
        }
    }
}

// No callbacks must also preserve super; Left must never offer a vertical page.
for keyCode: UInt16 in [116, 121, 123] {
    let button = LauncherChromeButton(frame: .zero)
    let character = keyCode == 116 ? "\u{F72C}" : keyCode == 121 ? "\u{F72D}" : "\u{F702}"
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil,
        characters: character, charactersIgnoringModifiers: character,
        isARepeat: false, keyCode: keyCode
    )!
    eventCount += 1
    button.keyDown(with: event)
    check(button.fallbackEvents.count == 1, "absent callbacks reach super: \(keyCode)")
    if keyCode == 123 {
        var verticalCalls = 0
        var pages: [Int] = []
        button.onVerticalPage = { _ in verticalCalls += 1; return false }
        button.onPage = { pages.append($0) }
        eventCount += 1
        button.keyDown(with: event)
        check(verticalCalls == 0 && pages == [-1], "Left keeps existing paging path")
        check(button.fallbackEvents.count == 1, "handled Left must not add a super event")
    }
}
check(eventCount == 132, "Expected 128 matrix events plus four fallback/Left checks")
print("Chrome Page Up/Down events: \(eventCount)")
print("Chrome Page Up/Down callback failures: \(failures)")
exit(failures == 0 ? 0 : 1)
