# HNReader Implementation Plan

## App Summary

A native macOS windowed app for reading Hacker News stories in reverse-chronological order. This replaces a web service (Arc.codes/AWS) that polls the HN Algolia API, stores stories in DynamoDB, enriches them with OpenGraph data, and serves a server-rendered UI.

The SwiftUI app simplifies this dramatically: it fetches directly from the Algolia API on user action, displays stories in a single scrolling list, and persists only the minimum state needed for unread tracking.

## Conversion Scope

### Features Carried Over
- **Chronological story feed** -- Algolia `search_by_date` endpoint, newest first
- **Minimum points filter** -- Configurable threshold (default 35, matching the web service)
- **Unread divider line** -- Visual separator between new and previously-seen stories
- **Story metadata display** -- Title, points, comment count, hostname, relative time
- **Open in browser** -- Click a story to open its URL in the default browser

### Features Deferred
- **OpenGraph previews** -- Requires fetching each story URL; defer to v2
- **AI content scoring** -- The `is-ai-ish` scoring from the web service; defer to v2
- **Story retention/pruning rules** -- No local database; fetch fresh each time
- **Background polling** -- No timers; user controls refresh
- **New story count badge** -- The `/count` endpoint equivalent; defer to v2

### Features Dropped
- **Server-side rendering** -- Replaced by native SwiftUI views
- **DynamoDB storage** -- No persistent story database
- **Session-based tracking** -- Replaced by `@AppStorage`
- **Web components** -- Replaced by SwiftUI views

## Project Structure

```
hnr-swiftui/
├── AGENTS.md
├── PLAN.md
├── HNReader.xcodeproj/
└── HNReader/
    ├── HNReaderApp.swift       # @main, WindowGroup scene, Settings scene
    ├── AppState.swift          # @Observable: stories, loading, error, refresh logic
    ├── HNClient.swift          # Immutable Sendable Algolia API client
    ├── Models.swift            # Story model (Decodable, Sendable, Identifiable)
    └── Views/
        ├── ContentView.swift   # Toolbar (refresh, points filter) + story list
        ├── StoryRowView.swift  # Single story: title, meta, hostname, time
        └── UnreadDivider.swift # Visual divider between new and old stories
```

## Data Model

### Story

Decoded from HN Algolia API response. Maps Algolia field names to cleaner Swift names.

```swift
struct Story: Decodable, Identifiable, Hashable, Sendable {
    let storyID: String        // Algolia: objectID
    let title: String          // Algolia: title
    let author: String         // Algolia: author
    let url: String?           // Algolia: url (nullable -- Ask HN, Show HN without links)
    let points: Int            // Algolia: points
    let commentsCount: Int     // Algolia: num_comments
    let createdAtTimestamp: Int // Algolia: created_at_i (Unix timestamp)

    var id: String { storyID }
}
```

### Algolia API Response Wrapper

```swift
struct AlgoliaResponse: Decodable, Sendable {
    let hits: [Story]
}
```

## API Integration

### Endpoint

```
GET https://hn.algolia.com/api/v1/search_by_date
    ?tags=story
    &numericFilters=points>{minPoints}
    &hitsPerPage=200
```

- No authentication required
- Returns stories sorted by creation date (newest first)
- `hitsPerPage=200` matches the web service's display limit

### HNClient

Immutable, `Sendable` struct. Single method:

```swift
struct HNClient: Sendable {
    func fetchStories(minPoints: Int) async throws -> [Story]
}
```

- Builds URL from base + query parameters
- Decodes `AlgoliaResponse`, returns `.hits`
- Throws on network or decoding errors

## State Management

### AppState (`@Observable`, `@MainActor`)

```swift
@MainActor @Observable
final class AppState {
    var stories: [Story] = []
    var isLoading = false
    var error: String?

    func refresh(minPoints: Int) async { ... }
}
```

### Persisted State (`@AppStorage`)

Stored in `ContentView` (or wherever the preference is read):

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `minPoints` | `Int` | `35` | Minimum point threshold for API query |
| `lastSeenStoryID` | `String` | `""` | Most recent story ID at time of previous refresh |

## Unread Tracking Logic

This is the core UX feature. The flow:

1. **First launch:** No `lastSeenStoryID` stored. Fetch stories, display all without a divider. Save the topmost story's ID as `lastSeenStoryID`.

2. **Subsequent refreshes:** Before fetching, save the current topmost story ID as the new `lastSeenStoryID`. Fetch fresh stories. Stories with IDs not matching `lastSeenStoryID` appear above the divider (new). The story matching `lastSeenStoryID` and everything below it appear below the divider (previously seen).

3. **Edge case -- `lastSeenStoryID` not in results:** If the saved ID is too old and no longer in the API results, show all stories without a divider (treat as fresh start). Save the new topmost ID.

4. **Persistence:** `lastSeenStoryID` survives app restarts via `@AppStorage`.

### Divider Placement

In the story list, iterate stories. When we encounter the story whose ID matches `lastSeenStoryID`, insert an `UnreadDivider` view before it. Everything above is new; everything at and below the divider was seen on the previous refresh.

## View Layout

### ContentView

```
┌─────────────────────────────────────────┐
│  Toolbar: [Refresh Button]  [Points: 35]│
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────────┐│
│  │ Story Title                    2h ago││
│  │ 142 pts  ·  87 comments  ·  example ││
│  ├─────────────────────────────────────┤│
│  │ Story Title                    4h ago││
│  │ 98 pts  ·  43 comments  ·  example  ││
│  ├─────────────────────────────────────┤│
│  │ ── New stories since last refresh ──││  <-- UnreadDivider
│  ├─────────────────────────────────────┤│
│  │ Story Title (previously seen)  6h ago││
│  │ 201 pts  ·  156 comments  ·  example││
│  └─────────────────────────────────────┘│
│                                         │
│  Loading / Error states shown inline    │
└─────────────────────────────────────────┘
```

### StoryRowView

Each row displays:
- **Title** -- Primary text, tappable to open URL in browser
- **Relative time** -- "2h ago", "15m ago" (trailing)
- **Meta line** -- Points, comment count, hostname extracted from URL
- Stories without a URL (Ask HN, etc.) show title only, clicking opens the HN discussion page

### UnreadDivider

A simple horizontal line with label text: "New stories since last refresh"
Uses `.secondary` foreground color and default divider styling.

## Implementation Phases

### Phase 1: Skeleton ✓
- [x] AGENTS.md
- [x] PLAN.md
- [x] Project structure with stub files
- [x] Models.swift with Story struct
- [x] HNClient.swift with fetchStories
- [x] AppState.swift with refresh logic
- [x] Basic views (ContentView, StoryRowView)

### Phase 2: Core Functionality ✓
- [x] Wire up .task {} for initial load
- [x] Toolbar with refresh button and points filter
- [x] Unread divider logic
- [x] Open story URL in browser
- [x] Error and loading states

### Phase 3: Polish ✓
- [x] Relative time formatting
- [x] Hostname extraction from URL
- [x] HN discussion link for stories without URL
- [x] Window title and sizing
- [x] Keyboard shortcuts (Cmd+R for refresh)
- [x] Background polling (5-min) with new story count badge
- [x] Dock badge for new story count
- [x] Visited story dimming
- [x] Story type tags (Show, Ask, Launch)
- [x] Front page story highlighting
- [x] Text filter in toolbar

### Phase 4: v2 — Settings, Background Open, App Store

#### 4.1 Settings Window

Replace the toolbar settings popover with a proper macOS `Settings` scene (`⌘,`).

**Create `SettingsView.swift`:**
- Single-pane settings form containing all preferences
- All settings backed by `@AppStorage` (persisted across launches)

| Setting | Key | Type | Default | Notes |
|---------|-----|------|---------|-------|
| Minimum points | `minPoints` | `Int` | `35` | Already exists as `@AppStorage` in ContentView |
| Show community posts | `showCommunityPosts` | `Bool` | `true` | Currently `@State` only — promote to `@AppStorage` |
| Front page only | `frontPageOnly` | `Bool` | `false` | Currently `@State` only — promote to `@AppStorage` |
| Open links in background | `openLinksInBackground` | `Bool` | `false` | New setting |
| Background refresh interval | `refreshInterval` | `Int` | `300` | New setting (seconds). Picker options: 60, 120, 300, 600, 900, 1800, 0 (never) |

**Update `HNReaderApp.swift`:**
- Add `Settings { SettingsView() }` scene alongside the existing `WindowGroup`
- This gives the app the standard macOS Preferences window via `⌘,`

**Update `ContentView.swift`:**
- Remove the settings popover entirely (gear button, `showSettings` state, popover + Form — lines 43-58)
- Replace `@State var showCommunityPosts` and `@State var frontPageOnly` with `@AppStorage` equivalents
- Read `refreshInterval` from `@AppStorage` and use it in the background polling loop instead of the hardcoded `300`
- Handle `refreshInterval == 0` to disable background polling entirely

#### 4.2 Open Links in Background

All links should open in the default browser without bringing it to the foreground when the setting is enabled. Applies to both story URLs and HN discussion links.

**Update `StoryRowView.swift`:**
- Read `@AppStorage("openLinksInBackground") var openLinksInBackground = false`
- Replace the 3 `NSWorkspace.shared.open(url)` call sites (lines 36, 38, 63-67) with a helper that uses `NSWorkspace.OpenConfiguration`:

```swift
private func openURL(_ url: URL) {
    if openLinksInBackground {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config)
    } else {
        NSWorkspace.shared.open(url)
    }
}
```

This is a legitimate AppKit exception (like the existing `NSWorkspace.shared.open()` calls already allowed in AGENTS.md).

#### 4.3 App Store Distribution

**Signing configuration (in Xcode project or `project.pbxproj`):**
- `CODE_SIGN_STYLE = Automatic`
- `DEVELOPMENT_TEAM = <team ID from Apple Developer account>`
- `CODE_SIGN_IDENTITY = "Apple Development"` (Debug) / `"Apple Distribution"` (Release)
- Let Xcode manage provisioning profiles automatically

**App Sandbox entitlements — create `HNReader.entitlements`:**
- `com.apple.security.app-sandbox` = `YES`
- `com.apple.security.network.client` = `YES` (outgoing network for Algolia API)

Note: `NSWorkspace.shared.open()`, `NSApp.dockTile.badgeLabel`, `NSCursor`, and `NSScreen` all work fine within the App Sandbox.

**App Store metadata prep:**
- **Category:** News
- **Bundle display name:** HN Reader (currently "HNReader" — consider adding a space)
- **Description:** Draft concise App Store copy
- **Screenshots:** Capture main list view in light and dark mode
- **Privacy policy:** The app only calls the public Algolia HN API. No accounts, no data collection. Host a simple privacy policy page (GitHub Pages or similar).
- **Age rating:** 4+
- **Copyright:** Set `INFOPLIST_KEY_NSHumanReadableCopyright` (e.g., "Copyright © 2025 tbeseda")

**Update GitHub Actions (`release.yml`):**
- Import signing certificates and provisioning profiles via repository secrets
- Build with proper code signing for App Store distribution
- Export as `.pkg` for App Store upload
- Optionally upload to App Store Connect via `xcrun altool` or Transporter

**App Store Connect (manual):**
- Create app record
- Upload first build
- Fill metadata, screenshots, privacy URL
- Submit for review

### Phase 5: Future (v3)
- [ ] OpenGraph preview data (async per-row fetch)
- [ ] AI content scoring (port is-ai-ish logic)

## Xcode Project

The Xcode project (`project.pbxproj`) will need to be generated. Options:
1. **Manual creation** -- Write the pbxproj file directly (as BlueprintsBar did)
2. **`swift package init`** -- Start as a Swift package, convert later
3. **Xcode generation** -- Create project when Xcode is available

Since Xcode is not currently installed, source files will be written first. The project file can be generated or created when Xcode becomes available.

## Reference: Web Service Mapping

| Web Service Component | SwiftUI Equivalent |
|----------------------|-------------------|
| `get-stories` (scheduled Lambda) | `HNClient.fetchStories()` called on user action |
| `get-index` (HTTP Lambda + Pug) | `ContentView` + `StoryRowView` |
| `get-count` (HTTP Lambda) | Not needed -- unread state is local |
| `check-story` (event Lambda) | Deferred -- OpenGraph in v2 |
| `clean-stories` (scheduled Lambda) | Not needed -- no persistent storage |
| `stories` DynamoDB table | `AppState.stories` array (in-memory) |
| `sessions` DynamoDB table | `@AppStorage("lastSeenStoryID")` |
| `is-ai-ish.mjs` | Deferred to v2 |
| `story-rules.mjs` | Not needed -- no retention rules |
| `style.css` | SwiftUI semantic styles |
| Web Components (`<hnr-header>`, `<story-list>`) | SwiftUI views |
