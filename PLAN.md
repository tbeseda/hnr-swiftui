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
- **AI content scoring** -- The `is-ai-ish` keyword scoring from the web service; not worth the complexity. Revisited in Phase 7 as an on-device model classifier.

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
    ├── StoryClassifier.swift   # On-device AI-topic classifier (FoundationModels, macOS 26)
    └── Views/
        ├── ContentView.swift   # Toolbar (refresh, filter) + story list
        ├── StoryRowView.swift  # Single story: title, meta, hostname, time
        ├── SettingsView.swift  # macOS Settings window (Cmd+,)
        ├── FilterPopover.swift # Toolbar filter panel: points, community, front page, AI
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
| `classifyAIStories` | `Bool` | `false` | Run the on-device AI-topic classifier in the background and show the toolbar toggle (macOS 26 + Apple Intelligence) |
| `hideAIStories` | `Bool` | `false` | Filter panel toggle: hide stories the classifier marked AI-topic |

## Unread Tracking Logic

This is the core UX feature. The flow:

1. **First launch:** No `lastSeenStoryID` stored. Fetch stories, display all without a divider. Save the topmost story's ID as `lastSeenStoryID`.

2. **Subsequent refreshes:** Before fetching, save the current topmost story ID as the new `lastSeenStoryID`. Fetch fresh stories. Stories with IDs not matching `lastSeenStoryID` appear above the divider (new). The story matching `lastSeenStoryID` and everything below it appear below the divider (previously seen).

3. **Edge case -- `lastSeenStoryID` not in results:** If the saved ID is too old and no longer in the API results, show all stories without a divider (treat as fresh start). Save the new topmost ID.

4. **Persistence:** `lastSeenStoryID` survives app restarts via `@AppStorage`.

### Divider Placement

In the story list, insert an `UnreadDivider` above the first displayed story whose ID is at or below `lastSeenStoryID` (item IDs increase with time). Everything above is new; everything at and below the divider was seen on the previous refresh. Comparing IDs rather than requiring an exact match keeps the divider in place when a view filter (community posts, front page, AI) hides the last-seen story itself.

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
- [x] Settings use local `@State` draft -- changes apply on window close, not per-keystroke (removed in Phase 7: the points field moved to the filter panel, and the remaining preferences bind directly)
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

**Scrape findings (Sept 2026, 59 recent story URLs from a residential IP):** 4 served `text/markdown` for `Accept: text/markdown` (Cloudflare's paid-plan opt-in "Markdown for Agents"); 5 returned 403 and 1 returned 429; a Notion-hosted story had no extractable text. Jina Reader (`https://r.jina.ai/<url>`) is the free no-key markdown service: 20 requests/min per IP, cached, headless-rendered, Apache-2.0 self-host image available. No evidence that Cloudflare Workers, Fly, or Vercel egress IPs are blocked less than Lambda. macOS 26 adds a headless `WebPage` API but no public reader-mode extractor. The AI filter (Phase 7) deliberately does not depend on any of this.

### Phase 6: Homebrew Distribution

Distributed via a personal Homebrew tap. The app is unsigned -- Homebrew removes the quarantine attribute on install, bypassing Gatekeeper.

**Tap repository:** `tbeseda/homebrew-tap` on GitHub

**Cask formula:** `Casks/hn-reader.rb` in the tap repo, pointing to the `.zip` artifact from GitHub Releases. Sept 2026: Homebrew 6 deprecated `postflight do` ("Calling `postflight` is deprecated! Use `postflight_steps` instead."), so the quarantine-clearing block became `postflight_steps` with `run "/usr/bin/xattr"` steps; `desc` dropped the platform word and `zap` gained `~/Library/Application Support/HNReader`. `brew audit` compares the shipped app's minimum OS with `depends_on macos:`, so the floor can only move with a release: the workflow now rewrites it from `CASK_MACOS` (set to `tahoe` for the macOS 26 target) next to `version` and `sha256`. The other cask edits were a manual tap commit.

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

### Phase 7: AI Story Filter (experimental) -- in progress

Optional filter that hides AI-topic stories, inspired by unslop.news. Uses Apple's on-device Foundation Models framework instead of a hosted LLM: no API keys to sniff or ship, nothing leaves the Mac.

**Research (2026-09-11, M3 Pro, macOS 26.6.2, model "26.4"):**
- unslop.news classifies title-only first (OpenAI gpt-5.6-luna, batched), then fetches Readability-extracted content only for title-negatives. Fails closed; hides filtered stories entirely.
- On-device, title + hostname, one plain-text yes/no prompt per story: p50 293 ms, 0 refusals and 1 guardrail hit over 200 titles, 22-23/26 correct on hand labels. 51% of the last 200 stored stories flagged AI.
- `@Generable` structured output with the same rubric: 30-100% refusals ("May contain sensitive content"); Apple's documented role-preamble fix didn't help. Batching 10 titles per prompt: guardrail violation every time. Adding og:description or body text: accuracy dropped 22/26 -> 20/26 and added refusals. `.contentTagging` use case: generic tags, unusable as a binary label.
- FoundationModels weak-links with the macOS 15 deployment target; features gated with `#available(macOS 26, *)`. (Moot since the deployment target was raised to macOS 26 right after the merge; the gating was removed.) Context is 4096 tokens; `tokenCount(for:)` exists from 26.4. macOS 27 ships a rebuilt model.

**Design:** see AGENTS.md "AI Story Filter". Title-only classification, fail open, verdict sidecar `verdicts.json` pinned to prompt + model version, view-level filter, and a display snapshot so verdicts only apply at the next refresh. No scraping dependency.

- [x] `StoryClassifier` with availability reasons and versioned prompt
- [x] `AppState` verdict store, background pass, display snapshot, pruning
- [x] View filter + divider placement robust to hidden last-seen story
- [x] Settings > Experimental opt-in toggle with availability / progress footer
- [x] Toolbar control to hide/show AI stories instantly; classification keeps running while hiding is off. First cut was a `sparkles` toggle with a hidden-count badge (pressed-means-hidden was counterintuitive, bare count uninformative); second was a segmented "All N | No AI M" picker (clear but too wordy for the toolbar); landed as a toggle inside a toolbar filter popover with the counts in words
- [x] Toolbar filter button + `FilterPopover`: minimum points, community posts, front page, hide AI, and a "Showing X of Y" line, all applying immediately; Settings shrinks to behavior + experimental
- [x] `applyThreshold`: threshold changes re-render from the store and fan out only when lowered, without moving the unread divider; superseded fan-outs are cancelled via `.task(id: minPoints)`
- [x] Settings label "AI story filter" renamed to "Classify stories with Apple Intelligence" after it read as the filter itself; the panel's Hide AI toggle now turns classification on by itself
- [x] Points field no longer grabs focus when the panel opens
- [x] Second tuning round after real use showed ~70% precision ("How Poor People Buy Cars", "Project Blinkenlights", "bzip3" flagged): built an 82-hard-negative / 44-positive set from the flagged list. Permissive rubric 69/82 FP; strict "default is no" prompt 0/82 FP but 15/44 FN; a keyword pre-pass (the old `is-ai-ish` idea, conservative list) catches 37/44 with 0 FP. Shipped as prompt v2: keywords first, strict model second -- 0 FP / 4 FN on the set, ~20% of stories settled without the model
- [ ] Live with v2: watch for misses on AI coding tools whose titles never name AI (Astra, harness, RTK)
- [x] New-story count excludes AI stories while hiding: the background check classifies its finds inline before counting
- [x] First tuning round: "When nothing in the title indicates AI, answer no." -- 34 labeled titles went 27 correct / 5 FP / 2 FN -> 28 / 2 FP / 4 FN. Remaining misses: "Remember Hong Kong" and a kids' programming language flagged AI; two AI-coding posts and one "OpenAI's methods" headline missed.
- [ ] Live with it: audit false positives against real usage, tune `instructions`, bump `promptVersion`
- [ ] Optional: collapsed row or "show hidden" affordance for auditing false positives
- [ ] Optional: "Fetch article previews" toggle (Phase 5), independent of the filter

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
