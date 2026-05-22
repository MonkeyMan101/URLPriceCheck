# URLPriceCheck

Native **macOS + iOS** app to watch store URLs, auto-detect prices, and get alerts.

**Repository:** [github.com/MonkeyMan101/URLPriceCheck](https://github.com/MonkeyMan101/URLPriceCheck)

If your local clone still uses the old remote (e.g. `Halo-Wars-2-Check`), update it:

```bash
git remote set-url origin https://github.com/MonkeyMan101/URLPriceCheck.git
git remote -v
```

## Features

- Add any product URL (Xbox, Amazon, etc.)
- **Auto price detection** — JSON-LD, meta tags, then currency regex (£ / $ / €)
- **Alert price** — notify when at or below your target
- **Critical price** — stronger (time-sensitive) notification
- **Check complete** notification on every run so you know it worked
- Per-item check interval (1–24 hours)
- Background refresh on iOS (with Background App Refresh enabled)

## Open in Xcode

1. Open `URLPriceCheck.xcodeproj` in Xcode (full Xcode required, not Command Line Tools only).
2. Select the **URLPriceCheck** target → **Signing & Capabilities** → choose your **Team**.
3. Pick run destination: **My Mac** or your **iPhone**.
4. Press **Run** (⌘R).

Allow notifications when prompted

## iPhone install (without App Store)

1. Connect iPhone, trust the Mac.
2. Run on your device from Xcode once.
3. On iPhone: **Settings → General → VPN & Device Management** → trust your developer certificate.

## Background checks

| Platform | Behaviour |
|----------|-----------|
| **macOS** | Checks every 15 min while the app is open; use **Check all** anytime. For hourly checks when the app is closed, keep using your existing LaunchAgent script. |
| **iOS** | Registers `BGAppRefreshTask` (~hourly, system decides). Enable **Settings → General → Background App Refresh** for URLPriceCheck. |

## Halo Wars 2 example

Add watch:

- **Name:** Halo Wars 2 Complete
- **URL:** `https://www.xbox.com/en-GB/games/store/halo-wars-2-complete-edition/c1c13ggxm7jg`
- **Alert:** `20`
- **Critical:** `15`

Tap **Detect price** before saving to confirm the page parses.

## Documentation

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — coding structure, data flow, price-resolution routing, share URLs, notifications, and Mermaid diagrams.

## Project layout

```
URLPriceCheck/
  URLPriceCheck.xcodeproj
  ARCHITECTURE.md
  URLPriceCheck/
    Models/WatchedItem.swift
    Services/PriceExtractor.swift
    Services/PriceCheckService.swift
    Views/...
```

The original Python script (`URLPricecheck.py`) can stay for command-line / LaunchAgent use alongside the app.
