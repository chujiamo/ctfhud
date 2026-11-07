#!/usr/bin/env python3
"""Portable source-level regression checks for AppKit window ownership.

These checks cannot simulate NSWindow on Linux. Exercise red-button close/reopen
on macOS after compiling; see README's manual smoke-test checklist.
"""
from pathlib import Path
import re

src = (Path(__file__).resolve().parents[1] / "main.swift").read_text(encoding="utf-8")

def verify(found: bool, detail: str) -> None:
    assert found, detail

verify("settings.isReleasedWhenClosed = false" in src,
       "settings window should not be released on close")
verify("settings.delegate = self" in src,
       "the control center must have a close interception delegate")
match = re.search(r"func windowShouldClose\(_ sender: NSWindow\) -> Bool \{(.*?)\n    \}", src, re.S)
verify(match is not None, "NSWindowDelegate.windowShouldClose is missing")
body = match.group(1)
verify("sender === settings" in body and "sender.orderOut(nil)" in body and "return false" in body,
       "settings close should hide the existing window, not destroy it")
open_method = re.search(r"@objc private func openSettings\(\) \{(.*?)\n    \}", src, re.S)
verify(open_method is not None and "settings.makeKeyAndOrderFront(nil)" in open_method.group(1),
       "menu action must reopen the stored settings NSWindow")
menu_method = re.search(r"private func setupMenu\(\) \{(.*?)\n    \}", src, re.S)
verify(menu_method is not None and "if statusItem == nil" in menu_method.group(1),
       "menu recreation must reuse one NSStatusItem")
verify(len(re.findall(r"NSStatusBar\.system\.statusItem\(", src)) == 1,
       "duplicate status bar item allocations")
move_method = re.search(r"func windowDidMove\(_ notification: Notification\) \{(.*?)\n    \}", src, re.S)
verify(move_method is not None and "movingWindow === panel" in move_method.group(1),
       "moving settings must not persist the HUD's coordinates")
print("Window lifecycle source checks passed (GUI runtime smoke test still required).")
