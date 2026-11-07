#!/usr/bin/env python3
"""Non-macOS source guards: does not substitute for AppKit GUI testing."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
s = (root / "main.swift").read_text(encoding="utf-8")
c = (root / "Core.swift").read_text(encoding="utf-8")

checks = {
    "separate saved bar position": "topBarOrigin: WindowOrigin?" in s and "store.topBarOrigin = origin" in s,
    "old saved floating position preserved": "store.windowOrigin = origin" in s,
    "two runtime display layouts": "store.layoutMode == .topBar" in s and "floatingBody" in s,
    "bar width follows display visible area": "HUDBarSizing.barWidth(available: available" in s,
    "top bar below macOS menu bar": "area.maxY - panel.frame.height - 8" in s,
    "layout changes restore independent position": "restoreWindowPosition()" in s and "appliedLayout != store.layoutMode" in s,
    "top bar respects final-phase timer toggle": "if showNextColumn { inlineCountdown(isEnd: false, density: density) }" in s,
    "per-item transparency preserved": ".opacity(bg)" in s and ".opacity(ink)" in s,
    "click through can be bypassed for adjustment": "store.effectiveClickThrough" in s and "store.isAdjustingPosition" in s,
    "top bar is exactly one row": "ViewThatFits(in: .horizontal)" in s and "singleLineBar(density: 0)" in s and "singleLineBar(density: 2)" in s,
    "fixed 42pt bar height": "height = CGFloat(HUDBarSizing.compactHeight)" in s and "static let compactHeight: Double = 42" in c,
    "no stacked fallback": "narrow ? 174" not in s and "private var topBarBody: some View {\n        let narrow" not in s,
    "position adjustment stays single line": "inlinePositionAdjustment" in s and "height: CGFloat(HUDBarSizing.compactHeight)" in s,
    "portable layout enum + sizing tests": "enum HUDLayoutMode" in c and "enum HUDBarSizing" in c,
}
for label, ok in checks.items():
    assert ok, label
print("Top bar source structure checks passed (macOS GUI testing still required).")
