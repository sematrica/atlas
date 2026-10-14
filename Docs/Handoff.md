# Hand-off: companion and crawler rebuild

This branch replaces Codex's companion pipeline and reworks the crawler's movement. It was written in a Linux cloud container that can't build the macOS app, so **the first job on a Mac is to build it, run the tests and fix anything the compiler finds.** This page lists what changed, what was already verified, and what to check, in order.

## What changed

**Companion (see [Companion.md](Companion.md))**

| Area | Files |
| --- | --- |
| Query model: targets, conditions, ordering, plain-English summaries | `AtlasCore/Companion/PageQuery.swift` |
| Deterministic execution over the page map; place and link lookup | `AtlasCore/Companion/PageQueryEngine.swift` |
| Instant parsing of common requests (no model) | `AtlasCore/Companion/CompanionLocalParser.swift` |
| Plan and step types, lenient decoding, ordered JSON schema | `AtlasCore/Companion/CompanionPlan.swift` |
| Single schema-constrained model call, repair, semantic filter, whole-article reader | `AtlasCore/Companion/CompanionPlanner.swift` |
| Colors from the user's words (split, gradient, alternate, groups, underline, text) | `AtlasCore/Companion/HighlightStyle.swift` |
| Excerpt selection and chunking (moved from the old companion file) | `AtlasCore/Companion/CompanionContext.swift` |
| Model-fit estimate and 12-case fit test | `AtlasCore/Companion/ModelFit.swift` |
| Library questions: scopes, candidates, exact per-article counts, resumable batches, answers | `AtlasCore/Companion/LibraryQuery.swift` |
| Page maps built straight from archive HTML; link destinations | `AtlasCore/Companion/ArticlePageMap.swift` |
| Paged built-in full-text search | `Native/ZIMBridge` (`az_fulltext_page`), `ZIMArticleProvider.fullTextPage` |
| Phrase lookup in the Research text index | `ResearchStore.articlePaths(matching:limit:)` |
| Executor: runs each step with the spider (tours, sweeps, navigation, hunts, rules) | `Atlas/Crawler/CrawlerConversation.swift` (rewritten) |
| Highlight layers that survive reflow; tags and sections in the page map | `Atlas/Crawler/DocumentGeometryScript.swift` |
| Companion panel: trails, legend, Finish now, fit badge; constellation theme (night background, thread of nodes, orange core, the app icon's creature as emblem) and the toolbar's Companion button | `Atlas/Crawler/CrawlerControls.swift`, `Atlas/UI/BrowserView.swift`, `Atlas/Assets.xcassets/SematricaEmblem.imageset` |
| Fit meter in Ask | `Atlas/Intelligence/IntelligenceModel.swift`, `IntelligenceView.swift` |

Removed: `AtlasCore/Crawler/CrawlerCompanion.swift` (regex guards, fixed tool menu), `AtlasCore/Crawler/CrawlerIntent.swift` and most of `CrawlerCommands.swift` (the old "Talk to crawler" path, no longer wired to any UI), and their tests and docs.

**Ollama** (`AtlasCore/AI/LLMProvider.swift`, new `OllamaProvider.swift`): schema-constrained output with a fallback to JSON mode for Ollama < 0.5; model validation cached for 10 minutes instead of two extra requests per call; one fixed `num_ctx` (8192) so Ollama never reloads the model between calls; `keep_alive` 30 minutes; `profile(model:)` for the fit meter.

**Crawler motion**: `CrawlerLegController.swift` (tetrapod gait on long legs with unhurried, predictive steps, fanned IK knees, dash scuttle above 600 pt/s), `CrawlerNavigator.swift` (curious, coverage-aware wandering instead of row-by-row sweeps), `CrawlerController.swift` (take/release control, pause or stop without cancelling the conversation, travel-speed override, hunt "found" announcement), `CrawlerRenderer.swift` (draws IK knees, clamped feet, body bob, the three creature looks and glowing boxes around touched words).

No new app-target files were added, so `Atlas.xcodeproj` needs no changes. New AtlasCore files are picked up by the Swift package automatically.

## Already verified in the container

- **61 AtlasCore unit tests pass** (Swift 6.0.3 on Linux): `PageQueryTests`, `CompanionParserTests` (including the user's own example requests), `HighlightStyleTests`, `CompanionPlanTests`, `CompanionPlannerTests` (scripted model: one call, repair, rejected steps, semantic filter, fit scoring), `CrawlerTests`, `CrawlerMotionTests`, `CrawlerPageTests`, `CrawlerCommandTests`. Linux has no NaturalLanguage framework, so a small stand-in tagger was used; part-of-speech and name results on macOS come from Apple's tagger and may differ slightly.
- `OllamaProvider.swift` type-checks (against a shim for `URLSession.AsyncBytes`).
- `CrawlerConversation.swift`, `CrawlerController.swift`, `CrawlerIntelligence.swift`, `DocumentGeometryScript.swift` and `CrawlerRenderer.swift` compile without errors or warnings under complete strict-concurrency checking, against stand-ins for WebKit, AppKit, CoreGraphics and `BrowserModel`.
- `ZIMArticleProvider.swift` and `ResearchStore.swift` compile against the real bridge header and SQLite (with do-nothing bridge functions), and the library phrase lookup was run against a real SQLite FTS5 index. The new bridge function passes `clang++ -fsyntax-only` against the vendored libzim headers.
- **End to end in Chromium**: the real geometry script built a page map of a Wikipedia-style page; the Swift engine ran the user's requests on it; the script painted the results. Highlights covered exactly the matched words, survived a resize and an image reflow, a text change was detected as stale, single-layer removal worked, and unsafe colors and layer names were rejected.

## Not verified yet (needs the Mac)

- Compiling the SwiftUI and AppKit files: `CrawlerControls.swift`, `IntelligenceView.swift`, `IntelligenceModel.swift`, `PackageLibraryModel.swift`, and `CrawlerRenderer.swift` against the real AppKit and CoreGraphics.
- Real WebKit (CSS Custom Highlight API, `Highlight.priority`, `text-decoration` in `::highlight`), Apple's NaturalLanguage tagging, and live Ollama calls with a JSON-schema `format`.
- `Tests/BrowserSmoke/BrowserSmoke.swift` and `Tests/LayoutSmoke/LayoutSmoke.swift` (rewritten or adjusted, never compiled).
- How the new gait and wandering look, and how fast the companion feels with `llama3.1`.

## Build and test, in this order

```sh
# 1. Core tests (fast; no app build needed)
swift test --scratch-path /tmp/AtlasTests

# 2. App build
xcodebuild -project Atlas.xcodeproj -scheme Atlas -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/AtlasStage2Build build

# 3. Companion smoke test on a fixture page (no library or model needed)
ATLAS_COMPANION_ONLY=1 Scripts/test-browser.sh

# 4. Full browser smoke test (needs the downloaded Ray Charles test library from the README)
Scripts/test-browser.sh
ATLAS_BUILD_DIR=/tmp/AtlasStage2Build Scripts/test-layout.sh
```

`az_fulltext_page` in `Native/ZIMBridge/ZIMBridge.cpp` is new native code: check it links and that a library question in a ZIM with a full-text index pages past 100 results.

Places most likely to need a compile fix, in order: `CrawlerControls.swift` (new `HighlightLegend`, `FitBadge`, `Color(hex:)`, and the constellation theme: `ThreadNode`, `ConstellationEmblem`, `ConstellationBackdrop`, `CompanionToolbarLabel`), `IntelligenceView.swift` (`CompanionFitRow`), `CrawlerRenderer.swift` (knee, foot, creature-look and touch-box drawing; it was type-checked here against stand-ins for AppKit and CoreGraphics), `BrowserSmoke.swift`.

## Manual acceptance on the Mac

With `llama3.1:latest` selected in Ask (the badge should read **Medium?** until the fit test runs):

1. Ask → **Run Fit Test**. Note the score and seconds per request.
2. Open an article. In the companion, try without waiting for replies to finish typing:
   - `how many capital letters in this article` · `how many dots in this article` · `how many links in this article` (each should say "understood instantly")
   - `find me all the words that start with a and ends with r`
   - `find all adjective that ends with w and highlight it with green`
   - `highlight the verbs half green half yellow` · `highlight the nouns in the introduction in light blue`
   - `go to the second longest word` · `take me to the Early life section` · `go to the bottom`
   - Resize the window: highlights must stay. Click × on a legend row, then `clear highlights`.
   - Model requests: `paint every word to do with music in purple`, `what is this article about?`, `open the article on Paris and count its links`, `hunt for the phrase "…"`, `wander`, `faster`, `stop`.
3. Watch the spider: a slim body on long legs, no legs snapping across the page or crossing each other, unhurried steps, gliding starts, stops and turns, a pause every few seconds rather than stop-start bursts, a quick scuttle on long trips, curious wandering rather than rows. By default it should look like a constellation in a dark crystal (white lattice, glass spheres, orange core, haloed head, a slanting beam), and each word or link under a planted foot should get a glowing box with orange-glowing letters that fades into a short trail as it walks. Try each **Look** (Constellation, Neon, Mechanical) and **Touch glow** in the manual tools; the look should be remembered after relaunching.

4. Library questions (open a package with a built-in full-text index first, then one without):
   - `how many articles mention Atlantic Records` · `which articles link to Paris` · `count jazz in the articles linked in the Discography section` (on Ray Charles)
   - Click an article in the list: it should open and highlight the matches. Try **Copy list**.
   - On a large package, `how many articles mention the` should stop after 2,000 articles and offer **Check more articles**.
   - In a package without a built-in index, build part of the text index under Research and check the answer says the index isn't finished.
5. Companion look: the panel should be dark in both light and dark mode, with the app icon's creature in the header (its orange core breathing while a reply is in progress), messages strung on a thin thread of light, orange accents for Sematrica's name, links and the send button, and readable text everywhere (check the text field, the legend and the manual-tools popover). The toolbar's **Companion** button should show the same creature, small, on a dark capsule whose edge glows orange while the panel is open. The Dock, Finder and About window should show the new icon (if the Dock keeps an old one, quit the app, run `killall Dock` and relaunch).

## Known limits and ideas for next steps

- The fit test uses a fixed fixture context; it measures understanding, not article reading.
- Meaning-based highlighting judges up to 600 candidates in batches of 50 (about 12 model calls at most).
- Cross-article exploration still uses the Phase 4 semantic-hunt loop in `CrawlerIntelligence.swift`, unchanged apart from not cancelling the conversation on transitions.
- If schema output proves slow with a particular model, `OllamaProvider.contextTokens` and the planner's `maxTokens` (700) are the first knobs.
