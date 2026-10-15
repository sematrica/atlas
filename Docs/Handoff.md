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
| Connect the dots: shortest chain of links between two articles (outward search plus stepping stones from search, provably shortest when a level is fully read, resumable) | `AtlasCore/Companion/ArticleConnection.swift`; redirects resolved from the directory alone by `az_resolve_paths` / `ZIMArticleProvider.resolve(paths:)` |
| Connect in the companion: `connect` step, phrasings, the spider walking the route, the constellation map and its image | `CompanionPlan.swift`, `CompanionPlanner.swift`, `CompanionLocalParser.swift`, `CrawlerConversation.swift`, `CrawlerControls.swift` (`ConnectionCard`, `ConnectionMap`, `ConnectionPoster`) |
| Collections beyond Wikipedia: the Kiwix catalog's own list of collections (Wiktionary, Wikibooks, Wikisource, Gutenberg, Stack Exchange…), a Collection picker in Library, each package's collection stored | `AtlasCore/Library/PackageCatalog.swift` (`KiwixCollection`, `kiwix(collection:)`), `PackageModels.swift` (`category`), `Atlas/App/PackageLibraryModel.swift`, `Atlas/UI/PackagesView.swift` |
| Import ZIM File…: read the file's own metadata, copy into `packages/`, verify, list as installed; interrupted imports are marked, never resumed | `AtlasCore/Library/PackageImport.swift`, `DownloadManager.importArchive`, `ZIMArticleProvider.fileInfo(at:)` with the new `az_metadata` and `az_uuid` |
| Link map from Wikipedia's table dumps: streaming gzip reader (zlib) and mysqldump parser that reads the column list from CREATE TABLE (old and 2024-on schemas) | `Native/ZIMBridge/GzipReader.c` (`az_gz_*`, linked with `-lz`), `AtlasCore/LinkMap/SQLDump.swift` |
| Link map builder and reader: article numbers, redirects resolved, links sorted both ways into memory-mapped files, categories; two-ended shortest path | `AtlasCore/LinkMap/LinkMapBuilder.swift`, `LinkMap.swift` |
| Which dumps make a map, which map goes with a package, answers for "what links here" and categories | `AtlasCore/LinkMap/LinkMapLibrary.swift` |
| Connect the dots from the map, each link checked on the pages, links the pages lack avoided, reading search as fallback | `ArticleConnection.swift` (`searchMap`) |
| In the app: map loaded with the package, "what links here" and the `category` step, Packages download/build/delete UI | `BrowserModel.swift` (`linkMap`), `CrawlerConversation.swift` (`linksHere`, `category`), `PackageLibraryModel.swift`, `PackagesView.swift` (`linkMapDownload`, `linkMapCard`) |
| Fit meter in Ask | `Atlas/Intelligence/IntelligenceModel.swift`, `IntelligenceView.swift` |

Removed: `AtlasCore/Crawler/CrawlerCompanion.swift` (regex guards, fixed tool menu), `AtlasCore/Crawler/CrawlerIntent.swift` and most of `CrawlerCommands.swift` (the old "Talk to crawler" path, no longer wired to any UI), and their tests and docs.

**Ollama** (`AtlasCore/AI/LLMProvider.swift`, new `OllamaProvider.swift`): schema-constrained output with a fallback to JSON mode for Ollama < 0.5; model validation cached for 10 minutes instead of two extra requests per call; one fixed `num_ctx` (8192) so Ollama never reloads the model between calls; `keep_alive` 30 minutes; `profile(model:)` for the fit meter.

**Crawler motion**: `CrawlerLegController.swift` (tetrapod gait on long legs with unhurried, predictive steps, fanned IK knees, dash scuttle above 600 pt/s), `CrawlerNavigator.swift` (curious, coverage-aware wandering instead of row-by-row sweeps), `CrawlerController.swift` (take/release control, pause or stop without cancelling the conversation, travel-speed override, hunt "found" announcement), `CrawlerRenderer.swift` (draws IK knees, clamped feet, body bob, the four creature looks and glowing boxes around touched words).

No new app-target files were added, so `Atlas.xcodeproj` needs no changes. New AtlasCore files (including the `LinkMap` folder) and `GzipReader.c` are picked up by the Swift package automatically; `Package.swift` now links zlib (`-lz`, part of macOS) into ZIMBridge.

## Already verified in the container

- **140 AtlasCore unit tests pass and 6 are skipped** (they need the network or a local fixture server), on Swift 6.0.3 on Linux. The library code (storage, catalog, downloads, manifests, verification, imports) now compiles there too, against stand-ins for CryptoKit, OSLog and security-scoped bookmarks, so `LibraryTests`, `Stage2Tests` and the new `PackageSourcesTests` run. The others: `PageQueryTests`, `CompanionParserTests` (including the user's own example requests), `HighlightStyleTests`, `CompanionPlanTests`, `CompanionPlannerTests` (scripted model: one call, repair, rejected steps, semantic filter, fit scoring), `CrawlerTests`, `CrawlerMotionTests`, `CrawlerPageTests`, `CrawlerCommandTests`, `ArticlePageMapTests`, `LibraryQueryTests`, `LibraryParserTests`, `ArticleConnectionTests` (direct links, proven two- and three-link chains, stepping stones through redirects, shorter chains preferred, no search index, stopping and resuming, unproven chains, no connection, the open article, "the Moon"), `ConnectParserTests`, and for the link map `SQLDumpTests` (quoting, escapes, hex and `_binary` literals, rows split across lines), `LinkMapTests` (both dump schemas, redirects followed once as MediaWiki does, red links and other namespaces left out, lists built in several passes, shortest paths checked against a plain breadth-first search on random graphs), `ConnectionLinkMapTests` (chain from the map checked on the pages, links and articles the package lacks avoided, fallback to reading, no chain in the map), `LinkMapAnswerTests` and `LinkMapParserTests`. A connection search was also run on a synthetic 20,000-article library: proven-shortest three-link chains after reading 80–180 articles, in under half a second. A link map of a synthetic 200,000-article, 6-million-link wiki built in 3.5 s (release build), took 61 MB on disk and 232 MB of memory at peak, and answered 50 shortest-path searches in 0.02 s. Linux has no NaturalLanguage framework, so a small stand-in tagger was used; part-of-speech and name results on macOS come from Apple's tagger and may differ slightly.
- `OllamaProvider.swift` type-checks (against a shim for `URLSession.AsyncBytes`).
- `CrawlerConversation.swift`, `CrawlerController.swift`, `CrawlerIntelligence.swift`, `DocumentGeometryScript.swift`, `CrawlerRenderer.swift` and the link map section of `PackageLibraryModel.swift` compile without errors or warnings under complete strict-concurrency checking, against stand-ins for WebKit, AppKit, CoreGraphics and `BrowserModel`.
- `ZIMArticleProvider.swift` and `ResearchStore.swift` compile against the real bridge header and SQLite (with do-nothing bridge functions), and the library phrase lookup was run against a real SQLite FTS5 index. The new bridge function passes `clang++ -fsyntax-only` against the vendored libzim headers.
- **End to end in Chromium**: the real geometry script built a page map of a Wikipedia-style page; the Swift engine ran the user's requests on it; the script painted the results. Highlights covered exactly the matched words, survived a resize and an image reflow, a text change was detected as stale, single-layer removal worked, and unsafe colors and layer names were rejected.

## Not verified yet (needs the Mac)

- Compiling the SwiftUI and AppKit files: `CrawlerControls.swift`, `IntelligenceView.swift`, `IntelligenceModel.swift`, `PackageLibraryModel.swift`, `PackagesView.swift`, `BrowserModel.swift` and `CrawlerRenderer.swift` against the real AppKit and CoreGraphics.
- A link map built from real Wikimedia dumps: the container can't reach dumps.wikimedia.org, so the dump reader was tested on fixtures written in mysqldump's layout for both schemas. Start with `simplewiki` (small, quick) before `enwiki`.
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

`az_fulltext_page`, `az_resolve_paths`, `az_metadata` and `az_uuid` in `Native/ZIMBridge/ZIMBridge.cpp` and the `az_gz_*` functions in `GzipReader.c` are new native code: check they link, that a library question in a ZIM with a full-text index pages past 100 results, and that a connection through a redirect link is found.

Places most likely to need a compile fix, in order: `CrawlerControls.swift` (new `HighlightLegend`, `FitBadge`, `Color(hex:)`, the constellation theme: `ThreadNode`, `ConstellationEmblem`, `ConstellationBackdrop`, `CompanionToolbarLabel`, and the connection views: `ConnectionCard`, `ConnectionMap`, `ConnectionPoster` with `ImageRenderer` and `NSSavePanel`), `IntelligenceView.swift` (`CompanionFitRow`), `CrawlerRenderer.swift` (knee, foot, creature-look and touch-box drawing; it was type-checked here against stand-ins for AppKit and CoreGraphics), `BrowserSmoke.swift`.

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
3. Watch the spider: a slim body on long legs, no legs snapping across the page or crossing each other, unhurried steps, gliding starts, stops and turns, a pause every few seconds rather than stop-start bursts, a quick scuttle on long trips, curious wandering rather than rows. By default it should look like the creature in the app icon (glass legs on glowing knee joints, ringed feet in pools of warm light, a faceted crystal body with glass spheres and an orange core, a haloed head with a flare, a beaded tail and a long orange spike, and a soft shadow on the page), and each word or link under a planted foot should get a glowing box with orange-glowing letters that fades into a short trail as it walks. Try each **Look** (Sematrica, Constellation, Neon, Mechanical) and **Touch glow** in the manual tools; the look should be remembered after relaunching.

4. Library questions (open a package with a built-in full-text index first, then one without):
   - `how many articles mention Atlantic Records` · `which articles link to Paris` · `count jazz in the articles linked in the Discography section` (on Ray Charles)
   - Click an article in the list: it should open and highlight the matches. Try **Copy list**.
   - On a large package, `how many articles mention the` should stop after 2,000 articles and offer **Check more articles**.
   - In a package without a built-in index, build part of the text index under Research and check the answer says the index isn't finished.
5. Connect the dots (in a package with a built-in full-text index, then one without):
   - `how is Ray Charles connected to Paris` · `connect this to the Moon` · `find the shortest path from Jazz to Tokyo` · `how are Paris and Tokyo linked`
   - The answer should give the chain and say whether it's the shortest. The spider should open the first article, walk to the link that leads on, light it orange, follow it, and so on to the destination, while the map's threads glow. Check a chain whose link goes through a redirect (the map says "via …").
   - **Walk it**, **Copy image** (paste into Preview or Notes) and **Save image…**. With "stay in this article" on, the chain should be found but not walked.
   - A faraway pair should stop after 2,000 articles with **Keep looking**.
6. Library beyond Wikipedia:
   - **Packages → Available → Kiwix library**: the **Collection** menu should fill from the catalog (Wikipedia first). Load Wiktionary and Project Gutenberg, download a small package of each, open it, search titles, read a page and ask the companion something about it.
   - **Import ZIM File…** with a ZIM downloaded from the Kiwix website: it should copy with progress under Downloading, verify, appear under Installed with its own title and language, and open. Importing it again should say it's already in the library. Try a renamed non-ZIM file: it should be refused before copying. Quit during a large import and relaunch: the import should say it was interrupted.
7. Link map (start with Simple English: a `wikipedia_en_simple_all` package and the `simplewiki` archives):
   - Before any ZIM is installed, with only `.gz` archives: Browse's package menu should list them as "data, not articles" with **Show Them in Packages** (and **Build a Link Map from Them…** once a full set is in), and the empty page should explain they can't be opened and offer **Get a Wikipedia Package**. Each archive under Installed should say what it's for.
   - **Packages → Available → Wikimedia archives**, project `simplewiki`, **Load Catalog**. The Link map box should offer **Download the Link Map Files** for the newest dump's five tables; download them.
   - **Installed → Link maps** should show the dump as ready, then **Build Link Map** with steps and a progress bar. Try **Cancel** once, then build again. The finished map lists its articles, links, categories and size.
   - Open the Simple English package. `how is Ray Charles connected to Paris` should answer at once with "the shortest chain in Wikipedia's link map", and the spider should still walk it. `what links here` on an article, `which articles link to Paris`, `how many articles are in the category Jazz musicians` and `what categories is this article in` should all answer at once, with lists that open articles.
   - Delete the map: Connect the dots should go back to reading, and a category question should explain how to build a map. On a non-Wikipedia package, a category question should say it needs a Wikipedia package.
   - If there's room, repeat with `enwiki` and an English Wikipedia package, and note the build's time, memory and disk use.
8. Companion look: the panel should be dark in both light and dark mode, with the app icon's creature in the header (its orange core breathing while a reply is in progress), messages strung on a thin thread of light, orange accents for Sematrica's name, links and the send button, and readable text everywhere (check the text field, the legend and the manual-tools popover). The toolbar's **Companion** button should show the same creature, small, on a dark capsule whose edge glows orange while the panel is open. The Dock, Finder and About window should show the new icon (if the Dock keeps an old one, quit the app, run `killall Dock` and relaunch).

## Known limits and ideas for next steps

- The fit test uses a fixed fixture context; it measures understanding, not article reading.
- Meaning-based highlighting judges up to 600 candidates in batches of 50 (about 12 model calls at most).
- Cross-article exploration still uses the Phase 4 semantic-hunt loop in `CrawlerIntelligence.swift`, unchanged apart from not cancelling the conversation on transitions.
- If schema output proves slow with a particular model, `OllamaProvider.contextTokens` and the planner's `maxTokens` (700) are the first knobs.
