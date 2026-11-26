#!/usr/bin/env python3
"""Guard: zh-Hans/en Localizable catalog is complete, in use, and has grid-size copy."""
from pathlib import Path
import json
import re
import sys

root = Path(__file__).resolve().parents[1]
catalog_path = root / "Resources/Localizable.xcstrings"
data = json.loads(catalog_path.read_text(encoding="utf-8"))
strings = data["strings"]
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
sources = "\n".join(p.read_text(encoding="utf-8") for p in (root / "Sources").rglob("*.swift"))
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need(data.get("sourceLanguage") == "zh-Hans", "catalog sourceLanguage must be zh-Hans")

for key, entry in strings.items():
    locs = (entry or {}).get("localizations") or {}
    for locale in ("en", "zh-Hans"):
        unit = (locs.get(locale) or {}).get("stringUnit") or {}
        need(locale in locs, f"{key!r} missing {locale}")
        need(unit.get("state") == "translated", f"{key!r} {locale} is not translated ({unit.get('state')})")
        need(bool((unit.get("value") or "").strip()), f"{key!r} {locale} is empty")
    zh = ((locs.get("zh-Hans") or {}).get("stringUnit") or {}).get("value")
    need(zh == key, f"{key!r} zh-Hans value must equal the source key")
    need(key in sources, f"stale catalog key not used in Sources: {key!r}")

# Source CJK keys (L("…") and *Key = "…") must be in the catalog.
used = set(re.findall(r'\bL\(\s*"((?:\\.|[^"\\])*)"', sources))
for val in re.findall(r'static\s+let\s+\w*[Kk]ey\w*\s*=\s*"((?:\\.|[^"\\])*)"', sources):
    if any("\u4e00" <= c <= "\u9fff" for c in val):
        used.add(val)
for key in sorted(used):
    if any("\u4e00" <= c <= "\u9fff" for c in key) or key in strings:
        need(key in strings, f"Sources key missing from catalog: {key!r}")

# GRID-GEOMETRY-SETTINGS-01 copy, including English.
grid = {
    "网格大小": "Grid Size",
    "列": "Columns",
    "行": "Rows",
    "%d 列": "%d Columns",
    "%d 行": "%d Rows",
    "设置主界面每页的列数和行数，范围列 5 到 10、行 3 到 8；默认 7×5。文件夹网格不变。不影响翻页动画":
        "Set how many columns and rows each main-grid page uses, from 5 to 10 columns and 3 to 8 rows; the default is 7×5. Folder grids stay the same. This does not change the page-turn animation.",
}
for key, english in grid.items():
    need(key in strings, f"grid-size catalog key missing: {key!r}")
    if key in strings:
        en = strings[key]["localizations"]["en"]["stringUnit"]["value"]
        need(en == english, f"grid-size English for {key!r} is {en!r}, expected {english!r}")

need('rowTitleKey = "网格大小"' in prefs, "GridGeometryCopy must use 网格大小")
need('columnsLabelKey = "列"' in prefs, "GridGeometryCopy must use 列")
need('rowsLabelKey = "行"' in prefs, "GridGeometryCopy must use 行")
need('columnsItemFormatKey = "%d 列"' in prefs, "GridGeometryCopy must use %d 列")
need('rowsItemFormatKey = "%d 行"' in prefs, "GridGeometryCopy must use %d 行")
need("GridGeometryCopy.rowTitle" in (root / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8"),
     "Settings must use GridGeometryCopy for the grid-size row")

# Known replaced copy must stay out of the catalog.
for stale in (
    "减少动态效果（合并只保留短淡入）",
    "应用将被移到废纸篓。不会删除用户数据文件。",
    "应用已移到废纸篓，部分相关文件失败",
    "无法正常退出。要强制退出后再卸载吗？",
    "未找到匹配的应用，按 Esc 清除搜索",
    "正在结束上次查找…",
    "系统未在 10 秒内回应启动请求；应用可能仍在启动。",
    "默认全选。取消勾选可保留；这些项目也会移到废纸篓。未登记且未运行的根外副本可能无法发现，请确认不需要保留其数据。",
):
    need(stale not in strings, f"stale catalog key returned: {stale!r}")

if failures:
    print("FAIL: localizable catalog")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: localizable catalog (en/zh-Hans complete, no stale keys, grid-size copy consistent)")
