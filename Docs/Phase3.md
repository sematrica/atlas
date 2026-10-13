# Phase 3 — Procedural Crawler

## Try it

Open an installed offline article, then select **Crawl** in the sidebar or use the **Crawl** toolbar button in Browse. Select **Free Crawl**, or enter a case-sensitive exact phrase and select **Hunt**. **Pause**, **Resume**, and **Stop** (Escape) are available while active. A successful Hunt shows **FOUND**, highlights the exact phrase, and offers **Find Next** and **Resume Crawl**.

**Auto Follow** gently scrolls when the crawler approaches a viewport edge. Turn it off to scroll independently. **Debug** is off by default; enable it for the perception circle, terrain rectangles, available and selected anchors, recent positions, desired movement vector, state and local-text inspector. Its radius slider ranges from 80–220 document points.

For a meaningful Hunt check, pick a short phrase farther down the article. At the start, the inspector must say **Target coordinates: unknown**. The target becomes locally observed only after it enters the perception disk. Normal article title search does not participate in Hunt.

## Architecture and rendering

`ProceduralCrawlerAgent` is a value-type, independently identified simulation in AtlasCore. It owns its state, mission, observation, memory and navigator. The app owns one `CrawlerController` per browser model; there is no global crawler singleton. Article navigation and library closure stop the current creature.

The explicit state machine covers idle, spawning, exploring, walking, inspecting, turning, paused, target suspected, approaching target, found and recovery. The navigator sets a desired position; movement applies acceleration and restrained organic speed variation; the separate leg controller chooses contact points; the renderer only draws.

Core Graphics draws a small faceted mechanical body, teal optical sensors, exposed pivot bearings and eight long articulated legs in a transparent native NSView above WKWebView. A macOS display link schedules rendering at the display cadence. This avoids a web animation dependency and keeps article input available through the non-interactive overlay. A narrow pale outline keeps the dark creature visible over images and dark backgrounds. Spawn fades and unfolds the legs over 0.65 seconds; FOUND changes the body color without obscuring the phrase.

Each leg has a body attachment, knee, contact point and stepping phase. The legs walk on an alternating tetrapod gait, as real spiders do: L1 R2 L3 R4 swing together while R1 L2 R3 L4 stay planted in document coordinates, then they swap. Knees come from two-segment inverse kinematics, so legs bend rather than stretch, and a swinging leg lifts its knee. New contacts favor nearby text edges or image boundaries and avoid anchors already used by another leg. Empty space permits nominal ground contacts. Above 600 points/second (companion dashes and sweeps) planted steps can't keep up, so the legs scuttle around the body instead of snapping across the page. The spider is always drawn like a debug view: by default it is a neon creature (cyan legs, pink joints and feet, a dark boxy body with a cyan eye), and every word or link a planted foot touches is outlined in a glowing neon box (mostly cyan, blue for links, now and then a pink, blue or cyan fill) while its letters glow cyan. When the foot lifts, the box fades over about 1.6 seconds, leaving a trail of touched words. **Touch glow** in the manual tools turns the boxes off; **Neon** off restores the amber mechanical spider. Locomotion uses approximately 0.4–0.9-second scuttling bursts at up to 270 document points/second, separated by 0.10–0.23-second inspections. Reduce Motion uses slower, smoother continuous movement, removes step lift, and disables smooth following while preserving exploration.

## Geometry and constrained perception

`DocumentGeometryScript` runs in `WKContentWorld.defaultClient`; archive scripts remain disabled. A geometry-only block index is built in batches of 400 DOM elements and bucketed vertically. This index may know document geometry, but the crawler receives neither its contents nor the whole article text. It is invalidated on resize, resource load and text/child layout changes.

`CrawlerPerception.observe(around:radius:)` accepts only a position and radius. It returns document dimensions and viewport, revision, nearby terrain with stable IDs, small text fragments and local link destinations. All four corners of each returned text rectangle must lie inside the disk. Swift validates this again and rejects stale samples. Word ranges preserve UTF-16 offsets, inline adjacency and gaps; out-of-radius words cannot be silently joined into a fabricated phrase.

Each response caps text at 8,192 characters, text terrain at 180 fragments and scanning work at 6,000 word candidates; Swift also rejects payloads at or above 128 KiB. The observation records truncation. Long text nodes use a geometric line jump before inspecting nearby words. The bridge retains only the latest local ranges for exact highlighting. It never receives the Hunt target, queries a global text index, or navigates to a search result.

Scroll metrics are coalesced to animation frames. Document positions are transformed into viewport coordinates only while drawing, so scrolling does not move the simulated creature. Resize revisions discard stale target geometry; the wandering memory adapts to the new page size instead of starting over.

## Navigation, memory and Hunt

The navigator divides the page into cells and remembers which ones the creature has seen. Each new goal is scored for novelty (unvisited cells), nearby landmarks it can actually see (headings, links, images), its current direction of travel, and distance, so it roams curiously instead of sweeping rows. The nearest unvisited cells are always candidates, so coverage never depends on luck; when every cell has been seen, a new lap begins. Each spawn gets its own random seed. Movement waits if it would outrun the last perception disk.

Memory retains 160 recent positions and up to 4,096 visited groups before renewing the local visited set. Found occurrence keys are retained for the current mission so Find Next can exclude previous discoveries. Missions and memory reset when a new crawler run starts.

The matcher sees only contiguous fragments in the current observation. It preserves case and whitespace and supplies exact UTF-16 highlight offsets. A local match enters target suspected, pauses briefly, approaches its observed rectangle, and re-confirms nearby text before FOUND. Find Next excludes that occurrence and continues coverage; it also supports another occurrence in the same text node.

## Performance and concurrency

Rendering and movement use the native display link, with simulation steps capped at 50 ms. Perception runs approximately eight times per second; ordinary navigation decisions run about every 100 ms. Terrain anchors are cached per observation. There are no per-frame DOM queries or full-article JSON transfers. SwiftUI observes controls/status rather than every limb coordinate. Pausing stops the display link; Stop cancels the senses task immediately and invalidates in-flight observations.

WebKit DOM work necessarily executes in its isolated script world. Swift's bounded matching, navigation and gait operations remain simple synchronous work under the main-actor controller, while pure Sendable core models remain independently testable. No unnecessary task-per-leg or actor-per-frame machinery is introduced. Display cadence was exercised in real windows, but sustained 60/120 Hz performance on huge articles, Intel and macOS 14 has not been benchmarked.

## Verification

Final verification on the development Apple Silicon Mac: Debug build passed; universal Release build passed and contains arm64 and x86_64; 32 enabled core tests passed with zero failures (38 discovered, six optional live/download-recovery tests skipped). The network-denied real-browser smoke passed on all three articles. The farther-down Hunt used 199 local observations in the final run. Screenshot inspection confirmed the native creature was visible over article text.

Build and run:

```sh
xcodebuild -project Atlas.xcodeproj -scheme Atlas -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/AtlasStage3Build build
swift test --scratch-path /tmp/AtlasStage3Tests
ATLAS_BUILD_DIR=/tmp/AtlasStage3Build ATLAS_DENY_NETWORK=1 Scripts/test-browser.sh
```

The browser smoke harness needs the small real Ray Charles ZIM fixture created by the Stage 2 live tests; see the README for fixture setup. The network denial applies only to the harness, not the Mac's connection.

Verification covers:

- Core tests: local-only target discovery; rejection of out-of-radius geometry; exact matching across inline fragments; gap rejection; Unicode offsets; independent instances; pause/stop; deterministic coverage; planted alternating feet; layout invalidation; and Reduce Motion functionality.
- Real native WebKit rendering on **Ray Charles**, **Ray Charles (album)** and **Ray Charles Anthology**, including movement, actual terrain anchors, scrolling and resizing.
- A farther-down phrase found after approximately 200 local observations, with target suspected, approach, exact highlight and FOUND. The test accelerates the simulation clock, but obtains every observation through the real constrained bridge. Fixture selection reads test-only DOM text; coordinates are never supplied to the crawler.
- A repeated phrase found twice with distinct occurrence keys, and actual Auto Follow scrolling beyond the initial viewport.
- Stage 2 regression smoke: article, local image/stylesheets, Contents, hyperlink, Back/Forward and external-navigation blocking, with networking denied.
- An actual native-overlay/WebKit composite captured at `/tmp/atlas-phase3-crawler.png` and visually inspected.

Manual acceptance: repeat Free Crawl and Hunt in the app with Debug on; watch alternating feet and occasional inspections; toggle Auto Follow; scroll and resize; pause/resume; stop with Escape; test a known repeated phrase with Find Next. Repeat with Internet disconnected and macOS Reduce Motion enabled. Physical SSD unplug/replug acceptance from Stage 2 remains applicable.

## Files

Created:

- `Atlas/Crawler/DocumentGeometryScript.swift` — isolated local terrain bridge.
- `Atlas/Crawler/CrawlerController.swift` — lifecycle, sensing, controls and inspector.
- `Atlas/Crawler/CrawlerRenderer.swift` — native overlay, display link and document transform.
- `Atlas/Crawler/CrawlerControls.swift` — mission and debug controls.
- `AtlasCore/Crawler/CrawlerNavigator.swift` — agent, memory, coverage and local matcher.
- `AtlasCore/Crawler/CrawlerLegController.swift` — articulated alternating gait.
- `Tests/AtlasCoreTests/CrawlerTests.swift` and `Docs/Phase3.md`.

Modified:

- `AtlasCore/Crawler/CrawlerContracts.swift` — replace placeholder contracts with explicit geometry, observation, mission, state and anchor types.
- `Atlas/App/BrowserModel.swift` — own the crawler and stop on closure.
- `Atlas/UI/OfflineWebView.swift` — isolated metrics handler, lifecycle and native overlay host.
- `Atlas/UI/BrowserView.swift`, `Atlas/UI/ContentView.swift` — functional Crawl entry points.
- `Atlas.xcodeproj/project.pbxproj` — register crawler app sources.
- `Tests/BrowserSmoke/BrowserSmoke.swift`, `Scripts/test-browser.sh` — actual app renderer and bridge tests.
- `README.md` — current capabilities and Phase 3 guide.

## Limits and Phase 4

Hunt is deliberately slower than indexed search. It matches a phrase only when all relevant contiguous fragments fit in one local observation; very long phrases, cross-paragraph text, words longer than 128 UTF-16 units and unusual layouts may not match. Whitespace follows DOM text rather than a normalized reading transcript. A full sweep repeats indefinitely when no match is found; there is no authoritative “not present” verdict. Geometric coverage is deterministic, but bounded/truncated perception is not proof that every possible DOM string was read. Very large or deeply nested blocks may still make individual geometry observations expensive.

The body is stylized kinematics, not a physics simulation, and can cross whitespace or images using fallback contacts. Layout reflow preserves/clamps document coordinates rather than tracking the same semantic glyph. Memory is not persisted between runs. Found occurrence keys grow with the number of discoveries in that run. Tests use real static ZIM pages, not every Wikipedia layout or a huge archive. Physical Intel/macOS 14 testing and prolonged performance profiling remain outstanding.

Phase 4 should add an optional high-level policy interface consuming a sanitized bounded observation plus bounded recent history and mission. Validate any proposed inspect/approach/turn/backtrack action against currently perceived IDs. Keep coverage fallback, movement, gait and rendering deterministic and independent of model calls; make decisions asynchronous, cancellable and infrequent. Cross-article actions need their own future permission/scope design. No LLM, embeddings, semantic Hunt, autonomous link following or simultaneous crawlers are included in Phase 3.

The later [reading companion](Companion.md) adds a separate article-wide map for exact counts, highlights, tours and constrained foot routes. Local hunt perception still uses the radius-limited bridge; whole-page commands no longer have to pretend they can only see nearby text.
