#!/usr/bin/env python3
"""Guard: every literal L("…") key in Direct has an English entry, and no
entry is a corrupted pair (zh value ≠ key, or en value literally "en")."""
from pathlib import Path
import json
import re
import sys

root = Path(__file__).resolve().parents[1]
strings = json.loads((root / "Resources/Localizable.xcstrings").read_text())["strings"]
failures = []


def en_value(key):
    return strings.get(key, {}).get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")


keys = set()
for path in sorted((root / "Sources/Direct").glob("*.swift")):
    for match in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"\)', path.read_text()):
        keys.add(match.group(1))
for key in sorted(keys):
    if not en_value(key):
        failures.append(f"missing en: {key}")

for key, entry in strings.items():
    loc = entry.get("localizations", {})
    zh = loc.get("zh-Hans", {}).get("stringUnit", {}).get("value")
    en = loc.get("en", {}).get("stringUnit", {}).get("value")
    if key == "en" or en == "en" or (zh is not None and zh != key):
        failures.append(f"corrupted entry: {key!r}")
    if en is not None and re.findall(r"%[@d]", key) != re.findall(r"%[@d]", en):
        failures.append(f"format specifiers differ: {key!r}")

# Any CJK literal in Direct/Core (e.g. passed through a helper then L()) needs English too.
cjk_literal = re.compile(r'"((?:[^"\\]|\\.)*[\u4e00-\u9fff](?:[^"\\]|\\.)*)"')
for folder in ("Sources/Direct", "Sources/Core"):
    for path in sorted((root / folder).glob("*.swift")):
        for line in path.read_text().splitlines():
            if line.lstrip().startswith("//"):
                continue
            for match in cjk_literal.finditer(line):
                key = match.group(1)
                if "\\(" in key:
                    continue
                if not strings.get(key, {}).get("localizations", {}).get("en"):
                    failures.append(f"{path.name}: CJK literal without English: {key!r}")

# Core helpers that pre-format the Chinese key bypass L(); Direct must format L(key) itself.
UNLOCALIZED_CORE_FORMATTERS = ["hideSelectedApplicationsToastMessage(", "hideApplicationToastMessage("]
for path in sorted((root / "Sources/Direct").glob("*.swift")):
    text = path.read_text()
    for name in UNLOCALIZED_CORE_FORMATTERS:
        if name in text:
            failures.append(f"{path.name}: uses unlocalized Core formatter {name}")

if failures:
    print("FAIL: localization coverage")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: localization coverage")
