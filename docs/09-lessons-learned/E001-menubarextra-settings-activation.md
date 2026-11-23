---
id: E001
title: MenuBarExtra Settings Window Requires Policy Switch
category: api-misuse
source_type: error
keywords: [MenuBarExtra, openSettings, LSUIElement, activationPolicy, orderFrontRegardless, menu-bar-app]
date: 2026-03-06
---

## Symptom

在 LSUIElement (menu bar only) app 中，点击 `openSettings()` 可以打开设置窗口，但窗口不会被带到最前面。如果设置窗口被其他 App 遮挡，再次点击设置按钮无法将其置前。`NSApp.activate()` 单独使用无效，同步切换 `activationPolicy` 也无效。

## Root Cause

LSUIElement app 的 activation policy 是 `.accessory`，macOS 不允许 accessory app 将窗口带到其他 app 之上。必须临时切换到 `.regular` policy 才能获得完整的窗口激活权限。但切换 policy 后需要等待系统处理（约 100ms），同步调用会被系统忽略。

## Prevention

对 LSUIElement menu bar app 打开设置窗口的正确模式：

1. 调用 `openSettings()`
2. 异步（`Task`）切换 `NSApp.setActivationPolicy(.regular)`
3. `Task.sleep(100ms)` 等待系统处理
4. `NSApp.activate()` + 找到设置窗口调用 `makeKeyAndOrderFront` / `orderFrontRegardless`
5. 设置窗口关闭时（`onDisappear`）恢复 `NSApp.setActivationPolicy(.accessory)`

关键代码位置（2026-11-23 起）：
- `ModelProxy/App/SettingsPresenter.swift` — 策略切换、置前、窗口关闭时恢复
- `ModelProxy/Views/StatusPopover.swift` — 齿轮按钮：先 `dismiss` 面板，再调用 SettingsPresenter

参考：https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items

## 2026-11-23 addendum — re-learned after a regression

The fix above was removed on 2026-11-19 by the Apple HIG design pass
(`9d1b3b9`): the settings button became a plain `SettingsLink`, and the
policy switch and its restore were deleted. From inside the menu-bar panel a
`SettingsLink` leaves the panel open and opens Settings behind every other
app's window. Re-applied the same day in
`ModelProxy/App/SettingsPresenter.swift`, with two findings the original
lesson does not carry. Measured in a throwaway harness on macOS 27, then on
the real app.

1. The policy switch itself may be synchronous. What waits for a later
   main-loop turn is the raise. What must not happen is an early restore:
   switching back to `.accessory` 0.5 s after opening Settings dropped it
   behind the other windows again. The policy stays `.regular` until the
   Settings window closes.
2. Close the panel with the view's `dismiss` action, never
   `NSWindow.close()`. Closing the window behind SwiftUI's back leaves
   MenuBarExtra believing the panel is still presented, and the user's next
   click on the status item is swallowed.

A lesson that names its code locations goes stale when the code moves. Search
this directory for the symptom before re-deriving a fix.
