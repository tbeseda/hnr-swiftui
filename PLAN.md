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
- **OpenGraph previews** -- Requires fetching each story URL; exploring for v2
- **Story retention/pruning rules** -- No local database; fetch fresh each time

### Features Dropped
- **AI content scoring** -- The `is-ai-ish` scoring from the web service; not worth the complexity

- **Background polling** -- Implemented in v1 (configurable interval)
- **New story count badge** -- Implemented in v1 (dock badge + toolbar indicator)

### Features Dropped (from web service)
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
    ├── HNReaderApp.swift       # @main, WindowGroup + Settings scenes
    ├── AppState.swift          # @Observable: stories, loading, error, refresh logic
    ├── HNClient.swift          # Immutable Sendable Algolia API client
    ├── Models.swift            # Story model (Decodable, Sendable, Identifiable)
    └── Views/
        ├── ContentView.swift   # Toolbar (refresh, filter) + story list
        ├── StoryRowView.swift  # Single story: title, meta, hostname, time
        ├── SettingsView.swift  # macOS Settings window (Cmd+,)
        ├── UnreadDivider.swift # Visual divider between new and old stories
        └── Helpers.swift       # Color.hnOrange, .pointerOnHover() modifier
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

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `minPoints` | `Int` | `35` | Minimum point threshold for API query |
| `lastSeenStoryID` | `String` | `""` | Most recent story ID at time of previous refresh |
| `showCommunityPosts` | `Bool` | `true` | Show/hide Ask HN, Show HN, Launch HN |
| `frontPageOnly` | `Bool` | `false` | Filter to front page stories only |
| `refreshInterval` | `Int` | `300` | Background refresh interval in seconds (0 = disabled) |
| `showDockBadge` | `Bool` | `true` | Show new story count on dock icon |
| `openLinksInBackground` | `Bool` | `false` | Open URLs without activating browser (disabled -- browsers ignore `activates = false`) |

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

### Phase 4: v2 — Settings & Polish ✓

#### 4.1 Settings Window ✓
- [x] Created `SettingsView.swift` with grouped Form (Stories + Behavior sections)
- [x] Added `Settings` scene to `HNReaderApp.swift` (standard `Cmd+,`)
- [x] Removed toolbar settings popover from ContentView
- [x] Promoted `showCommunityPosts` and `frontPageOnly` from `@State` to `@AppStorage`
- [x] Settings use local `@State` draft -- changes apply on window close, not per-keystroke
- [x] Configurable background refresh interval (Never, 1m, 2m, 5m, 10m, 15m, 30m)
- [x] Dock icon badge toggle
- [x] `onChange(of: minPoints)` triggers re-fetch when min points changes via Settings

#### 4.2 Open Links in Background (partially complete)
- [x] Code in place: `openURL()` helper using `NSWorkspace.OpenConfiguration` with `activates = false`
- [ ] **Blocked:** Browsers ignore `activates = false` and activate themselves anyway. Setting is disabled in UI. Revisit if macOS or browsers improve support.

**Retested 2026-07-09 on macOS 26.5.1 (Tahoe), still blocked for Chromium browsers.** Findings from in-app testing (synthetic clicks on story titles, verified to land via Vivaldi renderer-process counts and active-tab titles):
- Vivaldi (Chromium) self-activates and foregrounds the new tab when it receives the URL, with `activates = false` behaving identically to a plain `open()`. Chrome/Edge/Brave/Arc share this code path. Cooperative activation (macOS 14+) does not block the browser's self-activation.
- `open -g` from a shell fails the same way, so this is not an NSWorkspace bug; there is no OS-level hint the browser can't override.
- Safari honors the hint: `open -g -a Safari <url>` opened a window without taking focus. The feature would work for Safari-default users only, which is too unreliable to ship as a setting.
- Considered and rejected: re-activating HNReader after the open (visible focus flicker, still briefly focuses the browser) and per-browser AppleScript automation like `make new tab` (deep automation integration, per-browser code, consent prompts).
- Testing note for the next revisit: verify synthetic clicks actually land (System Events `click at` silently missed and produced false "no focus change" results; CGEvent clicks plus renderer-count/active-tab evidence are trustworthy).

### Phase 5: OpenGraph Previews (exploratory)

Fetch OpenGraph metadata (title, description, image) for story URLs to show richer previews in the list.

**Considerations:**
- The web service used a background Lambda to scrape OG data per-story and cache it in DynamoDB
- In a native app, fetching OG data means hitting each story URL from the user's machine
- Need to be respectful: lazy-load only for visible rows, cache aggressively, handle failures gracefully
- Some sites block or rate-limit scraping -- the app must degrade gracefully to the current title-only display
- Privacy: the user's IP will be making requests to each story's domain (unlike the server-side approach)

**Open questions:**
- Is the UX improvement worth the network overhead and privacy tradeoff?
- Should OG fetching be opt-in via Settings?
- What's the minimal useful OG data? (description only? image thumbnail?)

### Phase 6: Homebrew Distribution

Distributed via a personal Homebrew tap. The app is unsigned -- Homebrew removes the quarantine attribute on install, bypassing Gatekeeper.

**Tap repository:** `tbeseda/homebrew-tap` on GitHub

**Cask formula:** `Casks/hn-reader.rb` in the tap repo, pointing to the `.zip` artifact from GitHub Releases.

**Install command:**
```sh
brew tap tbeseda/tap
brew install --cask hn-reader
```

**Release workflow (`release.yml`):**
- Builds the app, zips it, computes SHA256
- Creates a GitHub Release with the zip and SHA256 in the release notes
- Auto-updates the Homebrew tap: clones the tap repo, updates version + SHA256 in the cask formula, commits, and pushes

**Required setup:**
- [ ] Create `tbeseda/homebrew-tap` repo on GitHub with `Casks/hn-reader.rb`
- [ ] Create a GitHub PAT with `repo` scope for the tap repo
- [ ] Add the PAT as `TAP_GITHUB_TOKEN` secret in the `hnr-swiftui` repo settings
- [ ] Tag a release to trigger the first automated build + tap update

**Future: App Store Distribution (deferred)**

If revisiting App Store distribution later, the key additions are:
- Apple Developer account (active)
- Code signing (Automatic, with `DEVELOPMENT_TEAM` set)
- App Sandbox entitlements (`com.apple.security.app-sandbox` + `com.apple.security.network.client`)
- App Store Connect record with metadata, screenshots, privacy policy URL
- Archive + upload workflow (replace zip with `xcodebuild archive` + `exportArchive`)

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
| `check-story` (event Lambda) | Exploring for Phase 5 (OpenGraph) |
| `clean-stories` (scheduled Lambda) | Not needed -- no persistent storage |
| `stories` DynamoDB table | `AppState.stories` array (in-memory) |
| `sessions` DynamoDB table | `@AppStorage("lastSeenStoryID")` |
| `is-ai-ish.mjs` | Dropped -- not worth the complexity |
| `story-rules.mjs` | Not needed -- no retention rules |
| `style.css` | SwiftUI semantic styles |
| Web Components (`<hnr-header>`, `<story-list>`) | SwiftUI views |
