# Agent Guidelines for HNReader

Development note: always build, kill, and restart the app after making changes. Do this in one command like:

```sh
xcodebuild -project HNReader.xcodeproj -scheme HNReader -configuration Debug build 2>&1 | tail -3 && pkill -x HNReader 2>/dev/null; sleep 0.5 && open ~/Library/Developer/Xcode/DerivedData/HNReader-*/Build/Products/Debug/HNReader.app
```

## Project Overview

HNReader is a native macOS windowed app for browsing Hacker News stories in reverse-chronological order. It fetches stories from the official HN Firebase API, filters by minimum point threshold, and tracks which stories are new since the user's last refresh. The app is **read-only** -- it never posts or modifies anything on Hacker News.

## Architecture

Pure SwiftUI, macOS 15+ (Sequoia) deployment target. The app uses a single `WindowGroup` scene.

Application state lives in a single `AppState` object (`@Observable` + `.environment()`). The API client (`HNClient`) is immutable and `Sendable`. User preferences (`minPoints`, `lastSeenStoryID`) persist via `@AppStorage`.

### Data loading pattern

Stories are loaded on app launch via `.task {}` and on manual refresh. A lightweight background check runs every 5 minutes to count new stories (for the dock badge and toolbar indicator) and fold them into the persistent store, but it does not update the displayed list -- the user controls when the list refreshes.

OpenGraph preview data is deferred to a later version. For now, stories display title, points, comment count, hostname, and relative time.

The API DTO (`HNItem`) uses `Decodable` (not `Codable`) since the app never writes to the API. `Story` is built from `HNItem` and is `Codable` for the local store file.

## Key Constraints

**Minimal code footprint.** Prefer SwiftUI built-ins over custom styling. Let the framework handle materials, spacing, and colors. Every custom modifier is a maintenance burden -- only add them when the default is clearly wrong.

**Don't fight the framework.** If a feature requires fighting SwiftUI's opinions, reconsider whether the feature is needed. Concessions that simplify code are better than clever hacks.

**SwiftUI only.** Avoid AppKit except where SwiftUI has no reasonable alternative. Current exceptions:
- `NSWorkspace.shared.open()` -- opening URLs in the default browser (no pure SwiftUI equivalent on macOS)
- `NSCursor.pointingHand` -- pointer cursor on hover for clickable elements (no SwiftUI equivalent on macOS)
- `NSApp.dockTile.badgeLabel` -- dock icon badge for new story count (no pure SwiftUI API for dock badges)
- `NSScreen.main?.visibleFrame.height` -- sizing the default window to the screen height (no SwiftUI equivalent for reading screen geometry at the Scene level)

If a feature requires deeper AppKit integration, reconsider whether it's needed.

**Swift 6 strict concurrency.** All model types must conform to `Sendable`. Build and test in Release mode before pushing -- it is stricter than Debug for concurrency.

**Read-only.** The app only reads from the HN Firebase API. No write operations, no authentication.

**No external dependencies.** Pure SwiftUI with Foundation. No third-party packages.

**Fixed timestamp format.** Use relative time display ("2h ago", "15m ago") for story ages. When absolute timestamps are needed, use `M-d HH:mm` (no leading zeros on month/day, year omitted for brevity), not locale-dependent formatting.

## API Details

Official HN Firebase API base URL: `https://hacker-news.firebaseio.com/v0` (docs: https://github.com/HackerNews/API). The app previously used the HN Algolia API, but in July 2026 that service dropped `points` from its filterable attributes (breaking `numericFilters=points>=N` with a 400) and its repo (algolia/hn-search) was archived in Feb 2026, so we migrated to the official API.

Endpoints used:
```
GET /topstories.json     -- ~500 IDs, front-page ranking
GET /beststories.json    -- ~200 IDs, highest-scoring recent
GET /newstories.json     -- ~500 IDs, every submission (~8h deep), no ranking
GET /item/{id}.json      -- single item
```

The API has no server-side filtering: security rules deny collection-level queries on `/v0/item` (no orderBy/startAt range queries, and no indexes on score/type/time), so the ID lists are the only "queries" available. Full enumeration is not viable either (HN creates ~15k items/day, comments included). Refresh fetches the union of top+best+new IDs (~900-1000 items, concurrent) and filters by points client-side.

**The ranked lists forget.** top/best coverage of qualifying stories is complete for only ~48h (measured July 2026); older stories fall off, with flagged/penalized stories dropping earliest. To keep the reverse-chron list canonical, `AppState` accumulates every qualifying story it sees into a store persisted at `~/Library/Application Support/HNReader/stories.json` (inside the sandbox container if sandboxed), pruned to a 14-day horizon. The displayed list is the store filtered by threshold, so stories never vanish once seen. Residual gap: stories that rise and fall entirely while the app is closed for 2+ days. Lowering the points threshold only takes effect for newly seen stories -- the store never held sub-threshold ones.

Key invariant: **HN item IDs increase monotonically with creation time.** The 5-minute background check exploits this -- it fetches `topstories.json` + `newstories.json` plus only items whose ID is greater than the newest displayed story's ID, skipping IDs already stored or already checked below-threshold (ranked IDs are rechecked, since their scores are moving). Typically a handful of item requests per check, never the full snapshot. Keep it that way: the fan-out belongs on user-initiated refresh only. Qualifying finds are folded into the store, so long-running sessions accumulate canonically even without manual refreshes.

The API is HTTP/1.1 only; `HNClient` uses a URLSession with `httpMaximumConnectionsPerHost = 40` (measured July 2026: 2x faster than 20; 64 regresses, so don't raise it further). Two more things keep refresh fast: (1) refresh displays from the store instantly and lets the fan-out settle scores afterward, so perceived latency is ~0; (2) items fetched this session and found below threshold are skipped while unranked (`checkedIDs`) -- an unranked story's score is effectively frozen, so it can't cross the threshold without re-entering the rankings. Cold refresh is ~960 items; warm refresh is roughly half that. No authentication, no rate limiting (per the official docs).

**Response mapping** (`HNItem` -> `Story`):
| Firebase Field | Model Field |
|----------------|-------------|
| `id` (Int) | `storyID` (String) |
| `title` | `title` |
| `by` | `author` |
| `url` | `url` (nullable -- absent on Ask HN/self posts) |
| `score` | `points` |
| `descendants` | `commentsCount` |
| `time` | `createdAtTimestamp` |
| `text` | `storyText` |
| (derived) | `tags` -- `story` always; `show_hn`/`ask_hn`/`launch_hn` from title prefix; `front_page` = membership in first 30 of topstories |

Items with `deleted` or `dead` set, and item requests returning literal `null`, are dropped. Story IDs are unchanged from the Algolia era (Algolia's `objectID` was the HN item ID), so persisted `lastSeenStoryID` values remain valid.

## Style Preferences

- Lean on SwiftUI defaults for spacing, colors, and materials
- Use semantic styles (`.secondary`, `.tertiary`) not custom colors
- Keep views flat and declarative -- avoid deep nesting or coordinator patterns
- Load data with `.task {}`, not `onAppear` + Task
- Error and loading states as simple inline views, not separate components
- Prefer computed properties over helper methods when no parameters needed
- Use `@AppStorage` for simple user preferences
- Always ask the user before git operations (commit, push, tag)

## Assets

The app icon lives in `HNReader/Assets.xcassets/AppIcon.appiconset/`. Source PNGs are in `./icons/`. If the icon changes, regenerate all sizes (16 through 1024) from the source and update the appiconset.

## CI / Release

A GitHub Actions workflow at `.github/workflows/release.yml` builds and releases the app on `v*` tags. It runs `xcodebuild` on `macos-15`, zips the `.app` bundle, and creates a GitHub Release with auto-generated notes. No secrets or signing are configured -- the build is unsigned.

## Unread Tracking

The core UX feature is a visible divider line in the story list:
- On refresh, the current topmost story ID is saved as `lastSeenStoryID`
- Stories above the divider are "new since last refresh"
- Stories below were already visible on the previous refresh
- `lastSeenStoryID` persists via `@AppStorage` across app restarts
