#!/usr/bin/env python3
"""Settings feedback message must clear opacity before unhide (no solid flash)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    raise SystemExit(1)

if "settingsMessageShouldClearOpacityBeforeUnhide" not in core:
    fail("Core missing settingsMessageShouldClearOpacityBeforeUnhide")
if "settingsMessageFadeAnimationKey" not in core:
    fail("Core missing settingsMessageFadeAnimationKey")
if "func setMessage(" not in settings:
    fail("Settings missing setMessage")
if "settingsMessageShouldClearOpacityBeforeUnhide" not in settings:
    fail("Settings missing Core reveal gate")
# Reveal path: opacity 0 before isHidden = false
idx = settings.index("private func setMessage(")
body = settings[idx:idx + 3500]
# First reveal branch should clear opacity then unhide
if "messageLabel.alphaValue = 0" not in body:
    fail("setMessage reveal missing alphaValue = 0")
# Ensure opacity clear appears before isHidden = false in the animated reveal branch
clear_at = body.find("messageLabel.alphaValue = 0")
unhide_at = body.find("messageLabel.isHidden = false", clear_at)
if clear_at < 0 or unhide_at < 0 or unhide_at < clear_at:
    fail("setMessage must clear opacity before unhide on reveal")
if "fillMode = .backwards" not in body and "fillMode = .backwards" not in settings[idx:idx+5000]:
    # fadeMessageOpacity should use backwards
    fade = settings[settings.index("private func fadeMessageOpacity"):settings.index("private func fadeMessageOpacity") + 900]
    if "fillMode" not in fade or "backwards" not in fade:
        fail("fadeMessageOpacity missing fillMode.backwards")
if "animator().alphaValue" in settings:
    fail("Settings must not use animator().alphaValue for message fade")
if "settingsMessageFadeShouldApply" not in core:
    fail("Core missing settingsMessageFadeShouldApply")
if "messageFadeGeneration" not in settings:
    fail("Settings missing messageFadeGeneration")
if "settingsMessageFadeShouldApply" not in settings:
    fail("Settings missing generation gate on fade completion")
idx = settings.index("private func setMessage(")
body = settings[idx:idx + 4500]
if "messageFadeGeneration &+= 1" not in body:
    fail("setMessage must bump messageFadeGeneration")
fade = settings[settings.index("private func fadeMessageOpacity"):settings.index("private func fadeMessageOpacity") + 1200]
if "settingsMessageFadeShouldApply" not in fade:
    fail("fadeMessageOpacity completion must gate on generation")
# Call sites go through setMessage
for needle in ['messageLabel.stringValue = L(', 'messageLabel.stringValue = message',
               'messageLabel.stringValue = error', 'messageLabel.stringValue = canEditLayout',
               'messageLabel.stringValue = result']:
    if needle in settings:
        fail(f"direct assignment remains: {needle}")

if "settingsMessageShouldRestoreOpacityWhenAlreadyShown" not in core:
    fail("Core missing settingsMessageShouldRestoreOpacityWhenAlreadyShown")
if "settingsMessageShouldRestoreOpacityWhenAlreadyShown" not in settings:
    fail("Settings missing interrupted-fade restore gate")
idx = settings.index("private func setMessage(")
body = settings[idx:idx + 5500]
if "settingsMessageShouldRestoreOpacityWhenAlreadyShown" not in body:
    fail("setMessage must restore interrupted fade when same text already shown")
# Same-text early path must bump generation when restoring (cancel in-flight hide).
same_branch_start = body.find("settingsMessageShouldRestoreOpacityWhenAlreadyShown")
same_branch = body[max(0, same_branch_start - 200):same_branch_start + 900]
if "messageFadeGeneration &+= 1" not in same_branch:
    fail("interrupted restore must bump messageFadeGeneration")
if "presentation()?.opacity" not in same_branch and "presentation()?.opacity" not in body[:2000]:
    fail("restore must read presentation opacity")
# No paging
for chunk in (body[:800], same_branch):
    if "showPage(" in chunk or "pageTransition" in chunk or "pageAnimationDuration" in chunk:
        fail("settings message fade must not retune paging")

print("PASS: settings message opacity-before-unhide + interrupted fade restore")

