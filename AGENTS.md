# AGENTS.md — BLEUnlock

macOS menu-bar Swift/ObjC app (Xcode, no SPM/CocoaPods, no tests/lint). Locks/unlocks Mac by BLE RSSI proximity.

## Build

- Only verified command (mirrors CI in `.github/workflows/test.yml`, runs on macOS only):
  `xcodebuild clean build -project BLEUnlock.xcodeproj -scheme BLEUnlock`
- No unit tests, no lint/typecheck. Deployment target macOS 12.0, Swift 5.0.
- Release: `./release` requires `PASSWORD` env (app-specific password); archives, exports via `ExportOptions.plist`, notarizes Launcher then app, staples, zips. Bump `CFBundleShortVersionString` in `BLEUnlock/Info.plist` manually for releases.

## Gotcha: build number churn

- Xcode `ShellScript` build phase auto-increments `CFBundleVersion` in `BLEUnlock/Info.plist` via PlistBuddy on **every** build. `Info.plist` will show as dirty after any build — revert it unless cutting a release.

## Architecture

- Two targets in `BLEUnlock.xcodeproj`: `BLEUnlock` (`jp.sone.BLEUnlock`) + `Launcher` (`jp.sone.BLEUnlock.Launcher`, ObjC login helper). `Launcher.app` is copied to `Contents/Library/LoginItems` by a CopyFiles phase; launch-at-login is `SMLoginItemSetEnabled` (`BLEUnlock/AppDelegate.swift:522`).
- Entrypoints: `BLEUnlock/AppDelegate.swift` (menu, lock/unlock, Keychain password, CGEvent keystroke unlock), `BLEUnlock/BLE.swift` (CoreBluetooth central, active vs passive RSSI monitoring), `BLEUnlock/lowlevel.c` (IOKit display sleep/wake + private `login.framework` `SACLockScreenImmediate`), `BLEUnlock/LEDeviceInfo.swift` (resolves MAC/name from `/Library/Bluetooth/*.db` SQLite; fallback `BLE.swift:10` reads `/Library/Preferences/com.apple.Bluetooth.plist`), `BLEUnlock/checkUpdate.swift` (GitHub releases check, 24h interval).
- Private frameworks linked from `/System/Library/PrivateFrameworks`: `MediaRemote.framework` (pause/play via `MediaRemote.h`) and `login.framework`. `SYSTEM_FRAMEWORK_SEARCH_PATHS` covers this — don't "fix" by vendoring. Hardened Runtime on, Sandbox off, manual signing (Debug ad-hoc `-`, Release Developer ID, team `42LGPQYC7M`).

## Do-not-break constraints

- Do NOT set `LSUIElement` in `Info.plist` — it breaks `CBCentralManager.scanForPeripherals`. Dock icon is hidden at runtime via `NSApp.setActivationPolicy(.accessory)` (`AppDelegate.swift:731`); sleep handler flips to `.regular` so BT scanning resumes. Preserve this.
- Unlock works by typing the Keychain-stored password via CGEvents — requires Accessibility permission + Keychain "Always Allow". Can't be verified headless/CI.
- Strings are localized: `Base.lproj` + `ja/zh-Hans/de/da/nb/sv/tr` (`Localizable.strings`, `AboutBox.strings`). Add keys to all locales (or at least Base + ja) when adding UI text.
