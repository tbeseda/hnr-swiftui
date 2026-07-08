# Agent Guidelines for HNReader

Development note: always build, kill, and restart the app after making changes. Do this in one command like:

```sh
xcodebuild -project HNReader.xcodeproj -scheme HNReader -configuration Debug build 2>&1 | tail -3 && pkill -x HNReader 2>/dev/null; sleep 0.5 && open ~/Library/Developer/Xcode/DerivedData/HNReader-*/Build/Products/Debug/HNReader.app
```

## Project Overview

HNReader is a native macOS windowed app for browsing Hacker News stories in reverse-chronological order. It fetches stories from the HN Algolia API, filters by minimum point threshold, and tracks which stories are new since the user's last refresh. The app is **read-only** -- it never posts or modifies anything on Hacker News.

## Architecture

Pure SwiftUI, macOS 15+ (Sequoia) deployment target. The app uses a single `WindowGroup` scene.

Application state lives in a single `AppState` object (`@Observable` + `.environment()`). The API client (`HNClient`) is immutable and `Sendable`. User preferences (`minPoints`, `lastSeenStoryID`) persist via `@AppStorage`.

### Data loading pattern

Stories are loaded on app launch via `.task {}` and on manual refresh. A lightweight background check runs every 5 minutes to count new stories (for the dock badge and toolbar indicator) but does not update the displayed list -- the user controls when the list refreshes.

OpenGraph preview data is deferred to a later version. For now, stories display title, points, comment count, hostname, and relative time.

Models use `Decodable` (not `Codable`) since the app is read-only and never encodes models back to JSON.

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

**Read-only.** The app only reads from the HN Algolia API. No write operations, no authentication.

**No external dependencies.** Pure SwiftUI with Foundation. No third-party packages.

**Fixed timestamp format.** Use relative time display ("2h ago", "15m ago") for story ages. When absolute timestamps are needed, use `M-d HH:mm` (no leading zeros on month/day, year omitted for brevity), not locale-dependent formatting.

## API Details

HN Algolia API base URL: `https://hn.algolia.com/api/v1`

Primary endpoint:
```
GET /search_by_date?tags=story&hitsPerPage=1000
```

The points threshold is applied client-side. The API used to support `numericFilters=points>={minPoints}`, but as of July 2026 it returns 400 ("attribute not specified in numericAttributesForFiltering setting") -- `points` and `num_comments` are no longer filterable; only `created_at_i` is.

No authentication required. No rate limiting headers, but be respectful -- fetch only on user action, not on a timer.

**Response mapping:**
| Algolia Field | Model Field |
|---------------|-------------|
| `objectID` | `storyID` |
| `title` | `title` |
| `author` | `author` |
| `url` | `url` (nullable) |
| `points` | `points` |
| `num_comments` | `commentsCount` |
| `created_at_i` | `createdAtTimestamp` |
| `_tags` | `tags` (array: `story`, `show_hn`, `ask_hn`, `launch_hn`, `front_page`) |

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
