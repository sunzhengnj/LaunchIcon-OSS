#!/usr/bin/env python3
"""Guard UNINSTALL-BATCH-OTHER-COPY-01: batch uninstall must probe for another
installed copy (like single uninstall) before forgetting layout state."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
coord = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("func otherCopyMayExistAfterUninstall(probe: Bool?)" in core, "Core helper missing")
need("testBatchAndSingleUninstallKeepLayoutUnlessNoOtherCopyConfirmed" in tests, "Core test missing")
need("otherCopyMayExist: false" not in coord, "no uninstall path may hard-code otherCopyMayExist: false")
need("otherCopyMayExist: finalOtherCopy != false" not in coord, "single path must use Core helper")
need(coord.count("otherCopyMayExistAfterUninstall(probe:") >= 3, "all success paths must use Core helper")
start = coord.index("static func promptToBatchUninstall")
batch = coord[start:]
need("hasOtherInstalledCopy(of: candidate, host: host)" in batch, "batch must probe other copies")
probe_at = batch.find("hasOtherInstalledCopy(of: candidate, host: host)")
trash_at = batch.find("AppUninstallExecutor.perform(")
need(0 <= probe_at < trash_at, "batch probe must run before trashing")
need("func catalogAfterUninstall(" in core, "Core catalogAfterUninstall missing")
need("testBatchUninstallKeepsSurvivingCopyThroughLaterForgetReconcile" in tests, "Core test -02 missing")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
i = direct.index("func applySuccessfulUninstall(of candidate: AppCandidate, otherCopyMayExist: Bool)")
chunk = direct[i:i + 1600]
need("guard otherCopyMayExist == false else { return }" in chunk,
     "surviving copy must keep its catalog entry until reload")
need("catalogAfterUninstall(" in chunk, "Direct must use Core catalogAfterUninstall")
need("showPage" not in batch and "pageTransition" not in batch, "batch uninstall must not touch paging")

if failures:
    print("FAIL")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS script/test_batch_uninstall_other_copy.py")
