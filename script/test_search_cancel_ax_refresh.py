#!/usr/bin/env python3
"""Search-cancel accessibility refreshes after the field editor is torn down.

The production discard, settings abort, presentation clear, and Esc clear run
against a search field whose editor can disappear without controlTextDidChange.
No window is ordered front, and nothing is posted to the accessibility system.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
core = (root / "Sources/Core/LauncherLayout.swift").read_text()


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


proxy_start = source.index("SEARCH-CANCEL-AX-DURING-IME-01")
proxy_end = source.index("\n}", proxy_start) + 2
proxy = source[proxy_start:proxy_end]
if "SEARCH-CANCEL-AX-PRESS-01" not in proxy:
    fail("missing SEARCH-CANCEL-AX-PRESS-01 slice tag")
if "accessibilityPerformPress()" not in proxy:
    fail("synthetic × must implement accessibilityPerformPress")
if "activateSyntheticCancelFromAccessibility()" not in proxy:
    fail("Press must call the cell's cancel path")
if "isAccessibilitySelectorAllowed" not in proxy:
    fail("VoiceOver must be allowed to invoke Press")
if "accessibilityActionNames()" not in proxy:
    fail("synthetic × must advertise the Press action")
if ".press" not in proxy:
    fail("Press must appear in accessibilityActionNames")
if "searchFieldDidEndSearching?" not in source[source.index("func activateSyntheticCancelFromAccessibility()"):source.index("func activateSyntheticCancelFromAccessibility()") + 500]:
    fail("AX press must reach searchFieldDidEndSearching")

# SEARCH-CANCEL-TEST-HOOK-01: the debug script must invoke the production
# Press path, not a parallel stringValue clear.
if "SEARCH-CANCEL-TEST-HOOK-01" not in source:
    fail("missing SEARCH-CANCEL-TEST-HOOK-01 slice tag")
hook_start = source.index("title == \"clear-search\"")
hook = source[hook_start:hook_start + 800]
if "activateSearchCancelFromAccessibilityForTest()" not in hook:
    fail("clear-search script must call the production AX-press wrapper")
if "stringValue =" in hook or "clearSearchIfNeeded()" in hook:
    fail("clear-search script must not use a parallel clear path")
wrapper_start = source.index("func activateSearchCancelFromAccessibilityForTest()")
wrapper = source[wrapper_start:wrapper_start + 400]
if "activateSyntheticCancelFromAccessibility()" not in wrapper:
    fail("test hook must call activateSyntheticCancelFromAccessibility")

# SEARCH-CANCEL-BUTTON-CLEARS-MARKED-AND-COMMITTED-01: one production
# EndSearching handler clears marked and committed text. It must not use the
# Esc path that protects marked-only pinyin, and must not have a second IME
# clear alongside it.
if source.count("func searchFieldDidEndSearching(") != 1:
    fail("there must be one searchFieldDidEndSearching handler")
if "SEARCH-CANCEL-BUTTON-CLEARS-MARKED-AND-COMMITTED-01" not in source:
    fail("missing SEARCH-CANCEL-BUTTON-CLEARS-MARKED-AND-COMMITTED-01 slice tag")


def extract(text: str, signature: str) -> str:
    start = text.index(signature)
    end = text.index("\n    }", start) + len("\n    }")
    body = text[start:end]
    if body.startswith("    private func"):
        body = body.replace("private func", "func", 1)
    return body


end_search = extract(source, "    func searchFieldDidEndSearching(_ sender: NSSearchField)")
if "searchCancelButtonShouldExitSearch(" not in end_search:
    fail("× must consult searchCancelButtonShouldExitSearch")
if "searchCancelRequiresForcedEmpty(" in end_search:
    fail("× must not use the Esc IME-protecting forced-empty path")
try:
    abort_at = end_search.index("abortEditing()")
    clear_at = end_search.index('searchField.stringValue = ""')
    apply_at = end_search.index("applySearch()")
except ValueError:
    fail("× must abort the editor, clear stringValue, and applySearch")
if not (abort_at < clear_at < apply_at):
    fail("× must abort marked text, then clear committed text, then applySearch")
if "if marked {" in end_search or "if editingHasMarkedText {" in end_search:
    fail("× must not use a parallel marked-only clear branch")


def static_func(name: str) -> str:
    start = core.index(f"    public static func {name}(")
    end = core.index("\n    }", start) + len("\n    }")
    return core[start:end].replace("public static func", "static func", 1)


struct_start = core.index("    public struct SearchCancelAccessibilityTreeUpdate")
struct_end = core.index("\n    }", struct_start) + len("\n    }")
tree_struct = (
    core[struct_start:struct_end]
    .replace("public struct", "struct", 1)
    .replace("public var", "var")
)

layout = "enum LauncherLayout {\n" + tree_struct + "\n"
for name in (
    "shouldAcceptPointerActivation",
    "shouldApplySearchFieldEdit",
    "shouldApplyDeferredSearchRefilter",
    "shouldDiscardSearchCompositionOnResignKey",
    "textByRemovingMarkedRange",
    "searchCancelButtonRequiresForcedEmpty",
    "searchCancelButtonShouldExitSearch",
    "searchFieldShowsCancelButton",
    "searchCancelAccessibilityShouldAppendSynthetic",
    "searchCancelAccessibilityTreeUpdate",
    "shouldFocusFirstGridItemAfterSearchFieldDidEndSearching",
):
    layout += static_func(name) + "\n"
layout += "}\n"

methods = [
    extract(source, "    func discardSearchCompositionBecauseWindowResignedKey()"),
    extract(source, "    private func abortSearchFieldForSettingsOpen()"),
    extract(source, "    private func clearSearchQueryForPresentation()"),
    extract(source, "    func clearSearchIfNeeded() -> Bool"),
    extract(source, "    func noteSearchCompositionEnded()"),
    extract(source, "    private func postSearchCancelAccessibilityTreeChangeIfNeeded()"),
    extract(source, "    func searchFieldDidEndSearching(_ sender: NSSearchField)"),
]
joined = "\n".join(methods)
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in joined:
        fail(f"paging red line {bad} in search-cancel accessibility refresh")
poster = "NSAccessibility.post(element: searchField, notification: .layoutChanged)"
if poster not in joined:
    fail("production refresh must post layoutChanged")
joined = joined.replace(poster, "layoutChangedPosts += 1", 1)

prep_start = source.index("func prepareForPresentation(clearsSearchQuery:")
prep_end = source.index("clearSearchQueryForPresentation()", prep_start)
preserve = source[prep_start:prep_end]
if "guard clearsSearchQuery else" not in preserve:
    fail("prepareForPresentation must keep the preserve-query branch")
if "postSearchCancelAccessibilityTreeChangeIfNeeded()" not in preserve:
    fail("preserving the query must refresh search-cancel accessibility")

harness = r'''
final class HostWindow { var isVisible = true }
final class MarkedEditor: NSTextView {
    var marked = false
    var mark = NSRange(location: NSNotFound, length: 0)
    override func hasMarkedText() -> Bool { marked }
    override func markedRange() -> NSRange { mark }
}
final class StubSearchField: NSSearchField {
    var stubEditor: MarkedEditor?
    var abortCount = 0
    override func currentEditor() -> NSText? { stubEditor }
    @discardableResult
    override func abortEditing() -> Bool {
        abortCount += 1
        stubEditor = nil
        return true
    }
    override func validateEditing() {}
}
@MainActor final class Harness {
    let searchField = StubSearchField()
    var window: HostWindow? = HostWindow()
    var launcherIsDismissing: () -> Bool = { false }
    var isDiscardingSearchComposition = false
    var frozenSearchFieldText: (committed: String, editing: String?)?
    var searchCancelAccessibilityShown = false
    var layoutChangedPosts = 0
    var applySearchCount = 0
    var isSearching = false
    func applySearch() { applySearchCount += 1 }
    func searchFieldHoldsKeyboardFocus() -> Bool { false }
    func focusFirstGridItemOnCurrentPage() {}
''' + joined + "\n}\n"

cases = r'''
var failures = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL"): \(label)")
    if !condition { failures += 1 }
}
let harness = Harness()

harness.searchCancelAccessibilityShown = true
harness.discardSearchCompositionBecauseWindowResignedKey()
check(!harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == 1,
      "resign-key with no editor clears the synthetic cancel flag and posts once")
check(harness.applySearchCount == 0, "missing editor does not refilter")

let stillEditing = MarkedEditor()
stillEditing.string = "ni"
stillEditing.marked = false
harness.searchField.stubEditor = stillEditing
harness.searchField.stringValue = ""
harness.searchCancelAccessibilityShown = true
let postsBeforeLeftover = harness.layoutChangedPosts
harness.discardSearchCompositionBecauseWindowResignedKey()
check(harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsBeforeLeftover,
      "unmarked leftover editor text keeps the synthetic cancel button")
check(harness.searchField.stubEditor != nil, "discard does not abort an unmarked editor")

harness.searchCancelAccessibilityShown = true
stillEditing.string = ""
harness.discardSearchCompositionBecauseWindowResignedKey()
check(!harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsBeforeLeftover + 1,
      "empty unmarked editor on resign-key drops the synthetic cancel button")

let composing = MarkedEditor()
composing.string = "nihao"
composing.marked = true
composing.mark = NSRange(location: 2, length: 3)
harness.searchField.stubEditor = composing
harness.searchField.stringValue = ""
harness.frozenSearchFieldText = (committed: "", editing: "nihao")
harness.searchCancelAccessibilityShown = true
let postsBeforeAbort = harness.layoutChangedPosts
let searchesBeforeAbort = harness.applySearchCount
harness.abortSearchFieldForSettingsOpen()
check(harness.searchField.stubEditor == nil && harness.searchField.abortCount == 1,
      "settings open aborts the field editor after discarding the mark")
check(!harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsBeforeAbort + 1,
      "settings open posts layout-changed only once the editor is gone")
check(harness.applySearchCount == searchesBeforeAbort + 1,
      "visible settings open still refilters after the mark is cut")
check(harness.frozenSearchFieldText?.editing == "ni",
      "frozen search text keeps the letters that remain after the mark")
check(harness.searchField.stringValue == "", "settings abort does not invent a committed query")

let next = MarkedEditor()
next.string = "hao"
next.marked = true
next.mark = NSRange(location: 0, length: 3)
harness.searchField.stubEditor = next
let postsBeforeNext = harness.layoutChangedPosts
harness.postSearchCancelAccessibilityTreeChangeIfNeeded()
check(harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsBeforeNext + 1,
      "the next composition posts layout-changed after the flag was cleared")
harness.postSearchCancelAccessibilityTreeChangeIfNeeded()
check(harness.layoutChangedPosts == postsBeforeNext + 1,
      "a later keystroke in the same composition does not post again")

harness.searchField.stubEditor = nil
harness.searchField.stringValue = "mail"
harness.postSearchCancelAccessibilityTreeChangeIfNeeded()
check(harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsBeforeNext + 1,
      "a preserved committed query keeps the synthetic button")
let markedAgain = MarkedEditor()
markedAgain.string = "ni"
markedAgain.marked = true
markedAgain.mark = NSRange(location: 0, length: 2)
harness.searchField.stubEditor = markedAgain
harness.searchField.stringValue = ""
harness.searchCancelAccessibilityShown = true
let postsWhileMarked = harness.layoutChangedPosts
harness.postSearchCancelAccessibilityTreeChangeIfNeeded()
check(harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsWhileMarked,
      "preserving a live composition does not announce a tree change")

harness.searchField.stubEditor = nil
harness.searchField.stringValue = ""
harness.searchCancelAccessibilityShown = true
let postsBeforeIdleClear = harness.layoutChangedPosts
let searchesBeforeIdleClear = harness.applySearchCount
harness.clearSearchQueryForPresentation()
check(!harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsBeforeIdleClear + 1,
      "appearing with nothing to clear still drops a stale synthetic flag")
check(harness.applySearchCount == searchesBeforeIdleClear,
      "an already empty field does not apply search again")

let leftover = MarkedEditor()
leftover.string = "abc"
leftover.marked = false
harness.searchField.stubEditor = leftover
harness.searchField.stringValue = ""
harness.searchCancelAccessibilityShown = true
let postsBeforePrepare = harness.layoutChangedPosts
harness.clearSearchQueryForPresentation()
check(harness.searchField.stubEditor == nil && harness.searchField.stringValue == "",
      "appearance abort removes the leftover editor and clears the field")
check(!harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsBeforePrepare + 1,
      "appearance posts layout-changed after the leftover editor is gone")

harness.searchCancelAccessibilityShown = true
let postsBeforeEscIdle = harness.layoutChangedPosts
check(harness.clearSearchIfNeeded() == false, "Esc on an idle field does not report a query")
check(!harness.searchCancelAccessibilityShown && harness.layoutChangedPosts == postsBeforeEscIdle + 1,
      "Esc on an idle field drops a stale synthetic flag")

let escEditor = MarkedEditor()
escEditor.string = "abc"
escEditor.marked = false
harness.searchField.stubEditor = escEditor
harness.searchField.stringValue = ""
harness.searchCancelAccessibilityShown = true
let postsBeforeEsc = harness.layoutChangedPosts
check(harness.clearSearchIfNeeded() == false, "Esc with only an unmarked editor is not a query")
check(harness.searchField.stubEditor == nil && !harness.searchCancelAccessibilityShown,
      "Esc aborts the unmarked editor and drops the synthetic button")
check(harness.layoutChangedPosts == postsBeforeEsc + 1, "Esc posts layout-changed after abort")

harness.searchField.stringValue = "mail"
harness.searchCancelAccessibilityShown = false
let postsBeforeQuery = harness.layoutChangedPosts
check(harness.clearSearchIfNeeded() == true, "Esc clears a committed query")
check(harness.searchField.stringValue == "" && !harness.searchCancelAccessibilityShown,
      "clearing a committed query leaves the synthetic button hidden")
check(harness.layoutChangedPosts == postsBeforeQuery,
      "clearing a committed query does not announce a synthetic button that was already absent")

// SEARCH-CANCEL-BUTTON-CLEARS-MARKED-AND-COMMITTED-01
let markedOnly = MarkedEditor()
markedOnly.string = "ni"
markedOnly.marked = true
harness.searchField.stubEditor = markedOnly
harness.searchField.stringValue = ""
harness.isSearching = true
harness.searchCancelAccessibilityShown = true
let searchesBeforeMarked = harness.applySearchCount
let abortBeforeMarked = harness.searchField.abortCount
harness.searchFieldDidEndSearching(harness.searchField)
check(harness.searchField.stubEditor == nil && harness.searchField.abortCount == abortBeforeMarked + 1,
      "× during marked text aborts the field editor")
check(harness.searchField.stringValue == "",
      "× during marked text leaves the committed string empty")
check(harness.applySearchCount == searchesBeforeMarked + 1,
      "× during marked text uses the production applySearch path")

let markedAndCommitted = MarkedEditor()
markedAndCommitted.string = "钟ni"
markedAndCommitted.marked = true
harness.searchField.stubEditor = markedAndCommitted
harness.searchField.stringValue = "钟"
harness.isSearching = true
let searchesBeforeBoth = harness.applySearchCount
let abortBeforeBoth = harness.searchField.abortCount
harness.searchFieldDidEndSearching(harness.searchField)
check(harness.searchField.stubEditor == nil && harness.searchField.abortCount == abortBeforeBoth + 1,
      "× over committed+marked aborts the mark")
check(harness.searchField.stringValue == "",
      "× over committed+marked also clears the committed query")
check(harness.applySearchCount == searchesBeforeBoth + 1,
      "committed+marked uses the same production applySearch path")

harness.isSearching = false
harness.searchField.stubEditor = nil
harness.searchField.stringValue = ""
let searchesBeforeIdle = harness.applySearchCount
let abortBeforeIdle = harness.searchField.abortCount
harness.searchFieldDidEndSearching(harness.searchField)
check(harness.searchField.abortCount == abortBeforeIdle && harness.searchField.stringValue == "",
      "× on an idle empty field does not invent a clear")
check(harness.applySearchCount == searchesBeforeIdle,
      "× on an idle empty field does not refilter")

print("Failures: \(failures)")
exit(failures == 0 ? 0 : 1)
'''

swift = "import AppKit\n" + layout + harness + cases
with tempfile.TemporaryDirectory(prefix="LaunchIcon-SearchCancelAX-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(swift)
    subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "6", str(path / "main.swift"), "-o", str(path / "refresh")],
        check=True,
    )
    sys.exit(subprocess.run([str(path / "refresh")], check=False).returncode)
