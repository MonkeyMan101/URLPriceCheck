# URLPriceCheck — Architecture & Code Documentation

Native **macOS + iOS** app that watches product URLs, extracts prices from store pages, and sends local notifications when targets are hit. This document describes how the codebase is organized, how data flows, and how price detection is routed per retailer.

For setup and day-to-day use, see [README.md](README.md).

---

## Table of contents

1. [System overview](#system-overview)
2. [Project structure](#project-structure)
3. [Targets & platform split](#targets--platform-split)
4. [Application layers](#application-layers)
5. [Data model](#data-model)
6. [Price check pipeline](#price-check-pipeline)
7. [Price resolution routing](#price-resolution-routing)
8. [UI architecture](#ui-architecture)
9. [Shared URL intake](#shared-url-intake)
10. [Notifications](#notifications)
11. [Background scheduling](#background-scheduling)
12. [On-device AI (Apple Intelligence)](#on-device-ai-apple-intelligence)
13. [Python companion script](#python-companion-script)
14. [Key types & files reference](#key-types--files-reference)
15. [Design decisions](#design-decisions)

---

## System overview

```mermaid
flowchart TB
    subgraph User["User"]
        Safari[Safari / Store apps]
        AppUI[URLPriceCheck UI]
    end

    subgraph App["URLPriceCheck.app"]
        Views[SwiftUI Views]
        SwiftData[(SwiftData\nWatchedItem)]
        PCS[PriceCheckService]
        NMgr[NotificationManager]
        BGS[BackgroundCheckScheduler]
    end

    subgraph ShareExt["ShareExtension (iOS)"]
        SVC[ShareViewController]
    end

    subgraph External["External"]
        Stores[Store websites]
        NVIDIA[NVIDIA Paywall API]
        AI[Apple Intelligence\nmacOS 26 / iOS 26]
    end

    Safari -->|Share URL| SVC
    SVC -->|App Group + deep link| Views
    AppUI --> Views
    Views <--> SwiftData
    Views --> PCS
    BGS --> PCS
    PCS -->|HTTP HTML| Stores
    PCS --> StorePriceResolver
    StorePriceResolver --> NVIDIA
    StorePriceResolver --> AI
    PCS --> NMgr
    NMgr -->|UNUserNotificationCenter| User
```

| Concern | Technology |
|--------|------------|
| UI | SwiftUI |
| Persistence | SwiftData (`WatchedItem`) |
| Networking | `URLSession` (+ macOS `curl` fallback) |
| Notifications | `UserNotifications` |
| iOS background | `BackgroundTasks` (`BGAppRefreshTask`) |
| iOS share | Share Extension + App Group |
| AI (optional) | `FoundationModels` when OS ≥ 26 |

---

## Project structure

```
URLPriceCheck/
├── URLPriceCheck.xcodeproj
├── README.md
├── ARCHITECTURE.md          ← this file
├── ShareExtension/          ← iOS only
│   ├── ShareViewController.swift
│   ├── Info.plist
│   └── ShareExtension.entitlements
└── URLPriceCheck/
    ├── URLPriceCheckApp.swift      # @main, delegates, SharedURLStore
    ├── Info.plist                  # URL scheme, BG task ID
    ├── URLPriceCheck.entitlements  # App Group
    ├── Models/
    │   └── WatchedItem.swift
    ├── Views/
    │   ├── ContentView.swift
    │   ├── AddWatchView.swift
    │   ├── WatchFormView.swift
    │   ├── WatchDetailView.swift
    │   ├── WatchRowView.swift
    │   └── FormLTRRow.swift
    ├── Services/
    │   ├── PriceCheckService.swift       # Orchestrates fetch → price → notify
    │   ├── StorePriceResolver.swift      # Retailer routing
    │   ├── PageFetcher.swift
    │   ├── PriceExtractor.swift          # JSON-LD, meta, regex
    │   ├── StoreHTMLPriceExtractor.swift # Amazon, NVIDIA HTML
    │   ├── SmartPriceFinder.swift
    │   ├── OnDeviceAIPriceExtractor.swift # AI + ProductNameResolver
    │   ├── GeForceNOWPaywallPriceFetcher.swift
    │   ├── GeForceAnnualPriceExtractor.swift
    │   ├── HintAnchoredPriceExtractor.swift
    │   ├── CustomKeywordHints.swift
    │   ├── StoreKeywordProfile.swift
    │   ├── NotificationManager.swift
    │   ├── BackgroundCheckScheduler.swift
    │   ├── DetectedPrice.swift
    │   └── HTMLTextStripper.swift
    └── Assets.xcassets/
```

---

## Targets & platform split

```mermaid
graph LR
    subgraph Main["URLPriceCheck target"]
        M1[SwiftUI app]
        M2[All Services]
        M3[SwiftData]
    end

    subgraph Ext["ShareExtension target"]
        E1[ShareViewController only]
        E2[Duplicate ShareURLSupport enum]
    end

    Main -->|embeds| Ext
    Main -.->|App Group| Ext
```

| Target | Bundle ID | Role |
|--------|-----------|------|
| **URLPriceCheck** | `com.deanwass.URLPriceCheck` | Full app (macOS + iOS) |
| **ShareExtension** | `com.deanwass.URLPriceCheck.ShareExtension` | iOS share sheet only |

**App Group:** `group.com.deanwass.URLPriceCheck` — passes pending URLs from the extension to the main app.

**URL scheme:** `urlpricecheck://add?url=<encoded-https-url>`

| Feature | macOS | iOS |
|---------|-------|-----|
| Share extension | — | ✓ |
| `curl` SSL fallback | ✓ | — |
| `BGAppRefreshTask` | — | ✓ |
| Foreground 15 min timer | ✓ | ✓ |
| Pasteboard “Paste URL” | ✓ | ✓ |

---

## Application layers

```mermaid
flowchart TB
    subgraph Presentation["Presentation (Views)"]
        CV[ContentView]
        WF[WatchFormView]
        WD[WatchDetailView]
    end

    subgraph Application["Application"]
        App[URLPriceCheckApp]
        SUS[SharedURLStore / SharedURLParser]
        PCS[PriceCheckService]
        BGS[BackgroundCheckScheduler]
        NM[NotificationManager]
    end

    subgraph Domain["Domain"]
        WI[WatchedItem]
        DP[DetectedPrice]
    end

    subgraph Infrastructure["Infrastructure"]
        PF[PageFetcher]
        SPR[StorePriceResolver]
        PE[PriceExtractor + store extractors]
        AI[OnDeviceAIPriceExtractor]
    end

    CV --> PCS
    CV --> SUS
    WF --> PCS
    WF --> SPR
    App --> BGS
    App --> NM
    PCS --> WI
    PCS --> SPR
    SPR --> PE
    SPR --> AI
    PCS --> PF
    PCS --> NM
```

All UI and services that touch `WatchedItem` run on **`@MainActor`** where needed; network fetch and AI run in `async` contexts.

---

## Data model

```mermaid
erDiagram
    WatchedItem {
        UUID id PK
        string name
        string urlString
        datetime createdAt
        decimal alertPrice "optional"
        decimal criticalPrice "optional"
        decimal lastPrice "optional"
        string lastPriceDisplay "optional"
        string lastCurrency "optional"
        datetime lastCheckedAt "optional"
        string lastError "optional"
        int checkIntervalHours "1-24"
        bool isEnabled
        string keywordsLeft "optional"
        string keywordsRight "optional"
        string keywordsNegative "optional"
    }
```

### `WatchedItem` (SwiftData `@Model`)

| Field | Purpose |
|-------|---------|
| `name` | Display label; auto-filled from page when empty |
| `urlString` | Product page URL |
| `alertPrice` / `criticalPrice` | Notify when `lastPrice ≤ threshold` |
| `checkIntervalHours` | Minimum hours between automatic checks |
| `keywordsLeft` / `keywordsRight` / `keywordsNegative` | Comma-separated hints for `HintAnchoredPriceExtractor` |
| `lastPrice`, `lastPriceDisplay`, `lastCheckedAt`, `lastError` | Last run state |

**Computed:**

- `url` — parsed `URL` from `urlString`
- `isDueForCheck` — enabled and interval elapsed since `lastCheckedAt`

---

## Price check pipeline

End-to-end flow for a single watch (manual “Check”, “Check all”, or background):

```mermaid
sequenceDiagram
    participant UI as View / Scheduler
    participant PCS as PriceCheckService
    participant PF as PageFetcher
    participant PNR as ProductNameResolver
    participant SPR as StorePriceResolver
    participant NM as NotificationManager
    participant DB as SwiftData

    UI->>PCS: check(item)
    PCS->>PF: fetchHTML(url)
    PF-->>PCS: HTML string
    PCS->>PNR: resolve(html, url, name)
    PNR-->>PCS: productName
    PCS->>SPR: bestPrice(html, url, name, hints)
    SPR-->>PCS: DetectedPrice
    PCS->>DB: update lastPrice, lastCheckedAt
    PCS->>PCS: evaluateAlerts(item, price)
    alt price <= critical
        PCS->>NM: criticalAlert
    else price <= alert
        PCS->>NM: priceAlert
    else notifyOnComplete
        PCS->>NM: checkComplete
    end
```

### `PriceCheckService.check(item:notifyOnComplete:)`

1. Validate URL → error notification if invalid.
2. **Fetch** HTML via `PageFetcher`.
3. **Resolve product name** via `ProductNameResolver` (JSON-LD → meta/h1 → on-device AI → URL slug); persist if `name` was empty.
4. **Extract price** via `StorePriceResolver.bestPrice`.
5. Write `lastPrice`, `lastPriceDisplay`, `lastCurrency`, `lastCheckedAt`, clear `lastError`.
6. **`evaluateAlerts`** — critical beats alert beats generic “check complete”.

---

## Price resolution routing

`StorePriceResolver` is the single entry point. It picks strategies based on **host** and page shape, not a single global algorithm.

```mermaid
flowchart TD
    Start([bestPrice html, url, name, hints]) --> Xbox{xbox.com?}
    Xbox -->|yes| XBoxPath[PriceExtractor.bestPrice\nfirst visible £ / JSON-LD]
    Xbox -->|no| Hints{Custom keyword hints?}
    Hints -->|match| Hint[HintAnchoredPriceExtractor]
    Hints -->|no| NVIDIA{nvidia.com?}

    NVIDIA -->|SPA matrix / no £ in HTML| API[GeForceNOWPaywallPriceFetcher]
    NVIDIA --> Annual[GeForceAnnualPriceExtractor\nprefer £99.99 annual over £12.43 monthly]
    Annual --> GFNHTML[StoreHTMLPriceExtractor GeForceNow]
    GFNHTML --> Amazon[StoreHTMLPriceExtractor\nAmazon deal / priceToPay]

    Amazon --> Generic{Generic retailer?}
    Generic -->|yes| JSONLD[PriceExtractor.productJSONLDPrice]
    JSONLD --> AI1[OnDeviceAIPriceExtractor]
    AI1 --> Smart[SmartPriceFinder + keyword profiles]
    Smart --> Structured[PriceExtractor.bestPrice fallback]

    Structured --> AI2{Not NVIDIA?}
    AI2 -->|yes| AI1
    AI2 -->|NVIDIA SPA failed| Err[throw geforceNOWJavaScriptPage]
    AI2 -->|else| Fail[throw noPriceFound]

    XBoxPath --> Done([DetectedPrice])
    Hint --> Done
    API --> Done
    Annual --> Done
    GFNHTML --> Done
    Amazon --> Done
    JSONLD --> Done
    AI1 --> Done
    Smart --> Done
    Structured --> Done
```

### Retailer summary

| Store type | Primary strategy | Notes |
|------------|------------------|-------|
| **Xbox** | `PriceExtractor.bestPrice` | Matches Python: first `£X.XX` in document order |
| **Amazon** | `StoreHTMLPriceExtractor` | Prefers `priceToPay`; penalizes “Was” / strikethrough |
| **NVIDIA / GeForce NOW** | Paywall API → annual extractor → HTML | **No AI** on empty JS pages (avoids hallucinated £12.43) |
| **Generic** (Cult Beauty, etc.) | JSON-LD → AI → `SmartPriceFinder` | AI only when OS supports Foundation Models |
| **Any** + user hints | `HintAnchoredPriceExtractor` | Scores prices near keyword anchors |

### `DetectedPrice`

```swift
struct DetectedPrice {
    let amount: Decimal      // numeric compare for alerts
    let currency: String     // GBP, USD, EUR
    let display: String      // e.g. "£49.74"
    let source: String       // provenance: jsonld, display, ai, etc.
}
```

---

## UI architecture

```mermaid
flowchart LR
    App[URLPriceCheckApp] --> CV[ContentView]
    CV --> List[WatchedItem list]
    CV --> Add[AddWatchView sheet]
    Add --> WF[WatchFormView]
    List --> WD[WatchDetailView]
    List --> WR[WatchRowView]
    WF -->|Detect price| SPR[StorePriceResolver]
    WF -->|Save| SD[(SwiftData)]
    WD -->|Check now| PCS[PriceCheckService]
```

| View | Responsibility |
|------|----------------|
| **ContentView** | List, “Check all”, add sheet, notification banner, `onOpenURL` / pending shared URL |
| **AddWatchView** | Wrapper sheet; passes `initialURL` to form |
| **WatchFormView** | Create/edit: URL, name, alert/critical, interval, keyword hints, detect price |
| **WatchDetailView** | Single item history actions, manual check |
| **WatchRowView** | Row summary: name, price, last check, error badge |

Navigation uses `NavigationStack` + `NavigationLink`; edit via sheet (`itemToEdit`).

---

## Shared URL intake

Three paths into the add-watch flow with a pre-filled URL:

```mermaid
sequenceDiagram
    participant Safari
    participant Ext as ShareExtension
    participant Group as App Group UserDefaults
    participant App as URLPriceCheck
    participant CV as ContentView

  Note over Safari,CV: iOS Share
    Safari->>Ext: NSExtensionItem URL
    Ext->>Group: pendingSharedURL
    Ext->>App: open urlpricecheck://add?url=...
    App->>CV: onOpenURL / AppDelegate
    CV->>CV: SharedURLStore.setPending
    CV->>CV: present AddWatchView(initialURL)

  Note over App,CV: macOS / paste
    App->>CV: open https://... or deep link
    CV->>CV: SharedURLParser.normalize
```

**`SharedURLStore`** and **`SharedURLParser`** live in `URLPriceCheckApp.swift` (merged into the app target for reliable compilation with iCloud-synced projects).

The Share Extension duplicates a minimal `ShareURLSupport` enum — extensions cannot import the main app module.

---

## Notifications

```mermaid
flowchart TD
    PCS[PriceCheckService.evaluateAlerts] --> Kind{Threshold?}
    Kind -->|<= critical| C[criticalAlert\ntime-sensitive]
    Kind -->|<= alert| A[priceAlert]
    Kind -->|else| D[checkComplete]

    C --> NM[NotificationManager.notify]
    A --> NM
    D --> NM
    Err[check error] --> NM

    NM --> Build[productLabel: truncate name or URL slug]
    Build --> UN[UNMutableNotificationContent\ntitle + body + subtitle]
    UN --> Center[UNUserNotificationCenter]
```

### Notification content

| Kind | Title example | Body |
|------|---------------|------|
| Check complete | `Halo Wars 2 — checked` | `Halo Wars 2: Current price: £49.74` |
| Price alert | `Price alert · Cult Beauty…` | `{label}: Current price: … — at or below your alert …` |
| Critical | `CRITICAL · …` | Same pattern, time-sensitive interruption (iOS 15+) |
| Error | `Check failed · …` | `{label} — {error}` |

`productLabel` uses up to **42 characters** of `item.name`, or falls back to URL path slug / hostname.

`NotificationCenterDelegate` shows banners **while the app is in the foreground**.

---

## Background scheduling

```mermaid
flowchart TB
    subgraph iOS["iOS"]
        BGReg[register BGAppRefreshTask]
        BGRun[runBackgroundRefresh]
        BGSched[scheduleNextRefresh ~1h]
        AppDelegate[applicationDidEnterBackground]
    end

    subgraph Both["macOS + iOS"]
        Timer[Foreground Timer 15 min]
        Manual[Check all button]
    end

    AppDelegate --> BGSched
    BGReg --> BGRun
    BGRun --> PCS[PriceCheckService.checkAllDue]
    Timer --> PCS
    Manual --> PCS
```

| Mechanism | Interval | When it runs |
|-----------|----------|--------------|
| Foreground `Timer` | 15 minutes | App open (both platforms) |
| `BGAppRefreshTask` | ~1 hour earliest | iOS, system decides |
| User **Check all** | On demand | Any time |

**Task ID:** `com.deanwass.URLPriceCheck.refresh` (must match `Info.plist` `BGTaskSchedulerPermittedIdentifiers`).

For **hourly checks while macOS app is quit**, the original Python script + LaunchAgent remains an option (see [Python companion script](#python-companion-script)).

---

## On-device AI (Apple Intelligence)

```mermaid
flowchart LR
    HTML[Raw HTML] --> CTX[ProductPageContext.build\nstrip tags, cap length]
    CTX --> FM{macOS 26 / iOS 26?}
    FM -->|yes| Gen[FoundationModels session]
    FM -->|no| Skip[return nil — fall through]
    Gen --> Price[AppleIntelligencePriceExtractor]
    Gen --> Name[AppleIntelligenceProductNameExtractor]
```

- Gated with `#available(macOS 26.0, iOS 26.0, *)` and `#if canImport(FoundationModels)`.
- **`ProductNameResolver`** (in `OnDeviceAIPriceExtractor.swift`): JSON-LD name → Open Graph / `<h1>` → AI → URL slug.
- AI is **skipped for NVIDIA** when the page is a JS-only product matrix without prices in HTML.

---

## Python companion script

`URLPricecheck.py` (repo root) is the original checker:

- Fetches with `urllib` + **curl fallback** on SSL failure (same idea as macOS `PageFetcher`).
- Price: `re.findall(r'£\d+\.\d{2}', html)[0]` — first pound price in the page.

The Swift app **generalizes** this for multiple stores, currencies, and alerts. You can run both: the app for interactive use and notifications; Python/LaunchAgent for headless macOS schedules.

---

## Key types & files reference

| File | Type / symbol | Role |
|------|----------------|------|
| `URLPriceCheckApp.swift` | `URLPriceCheckApp`, `AppDelegate`, `MacAppDelegate`, `SharedURLStore` | App entry, URL handling |
| `WatchedItem.swift` | `@Model WatchedItem` | Persistence |
| `PriceCheckService.swift` | `PriceCheckService` | Check orchestration |
| `StorePriceResolver.swift` | `enum StorePriceResolver` | Retailer routing |
| `PageFetcher.swift` | `enum PageFetcher` | HTTP + macOS curl |
| `PriceExtractor.swift` | `enum PriceExtractor` | JSON-LD, meta, regex |
| `StoreHTMLPriceExtractor.swift` | Amazon / NVIDIA HTML rules | |
| `SmartPriceFinder.swift` | Scored candidate prices | Keyword profiles |
| `OnDeviceAIPriceExtractor.swift` | AI extractors, `ProductNameResolver` | |
| `GeForceNOWPaywallPriceFetcher.swift` | NVIDIA API client | |
| `NotificationManager.swift` | `NotificationManager`, `AlertKind` | Local notifications |
| `BackgroundCheckScheduler.swift` | BG task + foreground timer | |
| `ShareViewController.swift` | iOS share extension | |

---

## Design decisions

1. **Router pattern for prices** — One `StorePriceResolver` avoids scattering `if amazon` across views; new stores add extractors without UI changes.

2. **Xbox = Python parity** — First visible `£` price, not `min()` over all matches, so “recommended” tiles do not win.

3. **NVIDIA API before AI** — JS-rendered GeForce NOW pages have no reliable HTML prices; the paywall API matches the website; AI on empty HTML was removed after wrong example prices.

4. **SharedURLStore in app entry file** — Separate `SharedURLStore.swift` was not always compiled when the project lives on iCloud Drive; merging into `URLPriceCheckApp.swift` keeps the target consistent.

5. **Share extension isolation** — Duplicate URL helpers in the extension; no shared Swift module between targets.

6. **MainActor services** — UI-bound state (`WatchedItem` updates, notifications) stays on the main actor; fetches are `async`.

7. **Notifications always name the product** — Truncated label in title and body so lock-screen alerts are identifiable.

---

## Related documentation

- [README.md](README.md) — install, signing, background refresh, example watch
- [Source repository (GitHub)](https://github.com/MonkeyMan101/URLPriceCheck)
- Apple: [Background Tasks](https://developer.apple.com/documentation/backgroundtasks), [Share extensions](https://developer.apple.com/documentation/uikit/share_extensions)
