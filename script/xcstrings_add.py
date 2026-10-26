#!/usr/bin/env python3
"""Dev helper: add zh-Hans source + en strings to Localizable.xcstrings (additions only)."""
import json, sys
from pathlib import Path
p = Path(__file__).resolve().parents[1] / "Resources/Localizable.xcstrings"
raw = p.read_text()
d = json.loads(raw)
args = sys.argv[1:]
for k, en in zip(args[::2], args[1::2]):
    if k in d["strings"]:
        continue
    d["strings"][k] = {"localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "zh-Hans": {"stringUnit": {"state": "translated", "value": k}},
    }}
out = json.dumps(d, indent=2, ensure_ascii=False)
if raw.endswith("\n"):
    out += "\n"
p.write_text(out)
