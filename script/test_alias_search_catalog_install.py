#!/usr/bin/env python3
"""Guard: catalog install always applies aliases; restart paste is hardened."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
ui = (root / "Tests/UITests/LauncherDragUITests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


catalog = body(direct, "    func setCatalog(_ candidates: [AppCandidate], layout: LayoutState) {", "        layoutState = layout")
need("ALIAS-SEARCH-CATALOG-INSTALL-01" in catalog, "catalog alias install marker missing")
need("appSearchIndex.setAliases(layout.appAliases)" in catalog, "setCatalog must install aliases")
need(
    "if layoutState.appAliases != layout.appAliases" not in catalog,
    "setCatalog must not skip setAliases when layout aliases already match",
)
need(
    "testSearchIndexFindsAliasOnFreshIndexBeforeCatalogTermsAreCached" in tests,
    "fresh-index alias Core test missing",
)
need(
    "index.setAliases([calculator.deduplicationKey: \"我的计算器\"])" in tests,
    "Core test must install the restart alias on an empty index",
)
need('query: "我的"' in tests, "Core test must search the alias fragment")

need(
    "private func pasteText(_ text: String, into element: XCUIElement, in app: XCUIApplication? = nil)"
    in ui,
    "pasteText must accept the application for occlusion-safe paste",
)
need("app.typeKey(\"v\", modifierFlags: .command)" in ui, "pasteText must be able to type through the app")
restart = body(ui, "            let searchAfterRestart = app.searchFields[\"搜索应用\"]", "            let searchValueAfterRestart")
need("pasteText(\"我的\", into: searchAfterRestart, in: app)" in restart, "restart search must paste through the app")
need(
    'if (searchAfterRestart.value as? String) != "我的"' in restart,
    "restart search must retry paste if the query did not land",
)

if failures:
    print("FAIL: alias search catalog install")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: alias search catalog install")
