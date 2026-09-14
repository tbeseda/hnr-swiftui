# Agent Guidelines for HNReader

Development note: always build, kill, and restart the app after making changes. Do this in one command like:

```sh
xcodebuild -project HNReader.xcodeproj -scheme HNReader -configuration Debug build 2>&1 | tail -3 && pkill -x HNReader 2>/dev/null; sleep 0.5 && open ~/Library/Developer/Xcode/DerivedData/HNReader-*/Build/Products/Debug/HNReader.app
```

## Project Overview

HNReader is a native macOS windowed app for browsing Hacker News stories in reverse-chronological order. It fetches stories from the official HN Firebase API, filters by minimum point threshold, and tracks which stories are new since the user's last refresh. The app is **read-only** -- it never posts or modifies anything on Hacker News.

## Architecture

Pure SwiftUI, macOS 26+ (Tahoe) deployment target. Older macOS is deliberately unsupported: the on-device classifier needs the macOS 26 Foundation Models framework, and a single target keeps availability gating out of the code. The app uses a single `WindowGroup` scene.

Application state lives in a single `AppState` object (`@Observable` + `.environment()`). The API client (`HNClient`) is immutable and `Sendable`, and so is the on-device `StoryClassifier`. User preferences (`minPoints`, `lastSeenStoryID`) persist via `@AppStorage`.

### Filters vs. Settings

View filters -- points threshold, community posts, front page, hide AI -- live in a toolbar filter button (`line.3.horizontal.decrease.circle`, filled while any filter narrows the list) that opens `FilterPopover`. They apply immediately and the panel spells out the resulting counts in words ("Showing 627 of 967"). Settings (Cmd+,) keeps only preferences that rarely change: background refresh interval, dock badge, and the experimental classification opt-in. Keep that split; a filter is not a preference.

The points threshold is the one filter that touches the network: the store never holds sub-threshold stories, so lowering it needs a fan-out. `AppState.applyThreshold` re-renders from the store at once and fans out only when the bar was lowered, without `beginRefresh`, so the unread divider and the new-story count stay put. `ContentView` drives it from `.task(id: minPoints)`, which cancels a fan-out that a newer value superseded; `finishRefresh` returns early on cancellation instead of reporting an error. The launch load is the first run of that same task.

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

**No external dependencies.** Pure SwiftUI with Foundation and Apple system frameworks (FoundationModels for the classifier). No third-party packages.

**Fixed timestamp format.** Use relative time display ("2h ago", "15m ago") for story ages. When absolute timestamps are needed, use `yyyy-MM-dd HH:mm`, not locale-dependent formatting.

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
- View filters go in the toolbar filter panel and apply immediately; Settings is for preferences that rarely change
- Always ask the user before git operations (commit, push, tag)

## Assets

The app icon lives in `HNReader/Assets.xcassets/AppIcon.appiconset/`. Source PNGs are in `./icons/`. If the icon changes, regenerate all sizes (16 through 1024) from the source and update the appiconset.

## CI / Release

A GitHub Actions workflow at `.github/workflows/release.yml` builds and releases the app on `v*` tags. It runs `xcodebuild` on `macos-26`, zips the `.app` bundle, and creates a GitHub Release with auto-generated notes. The build is unsigned; the only secret is the tap token.

The workflow then rewrites `version`, `sha256`, and the `depends_on macos:` floor in `Casks/hn-reader.rb` of `tbeseda/homebrew-tap` with `sed` and pushes. The floor comes from `CASK_MACOS` in the workflow; keep it in sync with `MACOSX_DEPLOYMENT_TARGET`, because `brew audit` reads the shipped app's minimum OS and fails the cask if `depends_on` disagrees -- which is also why the floor can only move together with a release. Nothing else in the cask is touched, so other cask changes (`desc`, `zap` paths, the quarantine-clearing steps) are manual commits to the tap repo. Homebrew 6 deprecated the Ruby `postflight do` block in favor of the declarative `postflight_steps` stanza (`run "/usr/bin/xattr", args: [...], must_succeed: false`); `brew style Casks/*.rb` in the tap checks the stanza, and `brew update` prints any deprecation the tap trips.

## Unread Tracking

The core UX feature is a visible divider line in the story list:
- On refresh, the current topmost story ID is saved as `lastSeenStoryID` -- synchronously, in `AppState.beginRefresh`, so the divider moves in the same frame the promoted stories appear (the async `finishRefresh` only settles scores)
- Stories above the divider are "new since last refresh"
- Stories below were already visible on the previous refresh
- `lastSeenStoryID` persists via `@AppStorage` across app restarts
- The divider renders above the first *displayed* story whose ID is at or below `lastSeenStoryID`, not only on an exact match, so a view filter that hides the last-seen story itself (community posts, front page, AI) doesn't make the divider vanish. Item IDs increase with time, which is what makes the comparison valid.

## AI Story Filter (experimental)

Two settings. `classifyAIStories` runs the classifier: each stored story's title + hostname is classified as AI-topic or not with Apple's on-device Foundation Models framework, in the background. `hideAIStories` is the "Hide AI stories" toggle in the toolbar filter panel, a view filter alongside the community-post and front-page filters, with "N of M stories are AI" spelled out beneath it. The panel shows the toggle whenever the model is available, and turning it on also turns classification on, so the one-click path works without a trip to Settings; Settings > Experimental > "Classify stories with Apple Intelligence" is the switch to turn classification back off. (An earlier Settings label, "AI story filter", read as if it were the filter itself.) (Earlier cuts -- a pressed `sparkles` toggle meaning "hidden", then a segmented "All N | No AI M" picker -- tested as counterintuitive and too wordy for the toolbar respectively.) The split matters: the user wants to hide AI bursts for a while and bring them back, so classification must keep running while hiding is off, otherwise a quick "hide" would find the newest stories unclassified. Requires Apple Intelligence to be enabled on an Apple silicon Mac; `StoryClassifier.unavailableReason` explains why the Settings toggle is disabled, and the panel omits the AI toggle entirely. No network, no API keys, nothing leaves the Mac.

**Two stages, and the prompt shape is load-bearing.** `StoryClassifier` first checks the title and host against keyword lists (AI, LLM, GPT, OpenAI, Claude, "machine learning", openai.com, ...); a hit is `.ai` with no model call, which settles ~20% of the store instantly. Only the rest go to the model, with a strict "default is no" prompt. Measured Sept 2026 on the "26.4" model against 82 hard negatives (generic titles a permissive prompt had flagged: "bzip3", "Audacity 4.0", "Haiku R1" the OS) and 44 clear positives: the permissive rubric flagged 69/82 negatives; the strict prompt alone flagged 0/82 but missed 15/44 positives, mostly titles that literally say "AI"; keywords catch 37/44 with 0/82 false positives; combined, 0 false positives and 4 misses (AI coding tools the title never names). Keep the keyword lists conservative -- Cursor, Grok, Haiku, Astra, agent, and model are all common words elsewhere. Prefer fewer false positives: a hidden story is a silent loss, a shown AI story is a visible nuisance.

Model call shape: one plain-text yes/no prompt per story, fresh `LanguageModelSession` each time, greedy sampling, ~300 ms, 0 refusals over 200 titles. Do not switch to `@Generable` structured output (refused 30-100% of the time with a topic rubric, including with Apple's role-preamble mitigation), do not batch several titles into one prompt (guardrail violation on every batch), and do not feed page descriptions or body text (lowered accuracy, added refusals). Any error from the model -- refusal, guardrail, context -- is a `.unknown` verdict and the story is shown: the filter fails open.

**Verdicts never remove a story mid-session.** `AppState.storedVerdicts` is written by the background pass; the view filters by `AppState.verdicts`, a snapshot synced (`syncVerdictSnapshot`) wherever `stories` is assigned (`beginRefresh`, `finishRefresh`, `applyThreshold`) and when the user turns hiding on. So a verdict landing in the background takes effect at the next user action, the same rule the store already follows for new stories and score changes.

**Where it runs.** `classifyPendingStories()` is called after each refresh, after each background check, and when `classifyAIStories` turns on -- only while that setting is on, regardless of whether hiding is on. The background check additionally classifies its few new finds inline (`classifyNow`) before recounting, so the new-story badge excludes AI stories while hiding instead of promising stories that refresh then hides. It processes stored stories lacking a current verdict, newest first, one at a time, in a single `Task`; a second call while a pass is running is a no-op and the running pass picks up newly stored stories. The first pass over a full 14-day store (~1000 stories) takes about five minutes.

**Persistence and versioning.** Verdicts live in `~/Library/Application Support/HNReader/verdicts.json` as `[storyID: StoredVerdict]`, pruned with the store. Each is pinned to `StoryClassifier.promptVersion` (bump it when the instructions or prompt change) and `StoryClassifier.modelVersion` (Apple ships distinct models at 26.0, 26.4, 27.0). Stale verdicts still filter the display until recomputed, so a version bump doesn't flash unfiltered stories.

**Known gaps.** Stories first discovered by a refresh fan-out show once unfiltered until the next refresh or the next time hiding is turned on.

**Popover focus.** macOS hands first responder to the first text field in a popover and selects its text, so any keystroke replaced the points threshold. `defaultFocus(_, false)` and resigning in `.task` at appearance both failed to stop it; `FilterPopover` resigns focus 150 ms after appearance instead. If a cleaner hook turns up, replace that.
