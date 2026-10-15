# Sematrica — Offline Wikipedia for macOS

Sematrica downloads Wikipedia into the user-selected library, browses/searches it offline, and now includes a procedural Crawler that explores an article through limited local perception. It retains Stage 1's native SwiftUI shell, macOS 14 deployment target, external-folder selection, security-scoped bookmarks, directory structure and identity validation. See [Phase 3 implementation and acceptance guide](Docs/Phase3.md).

The project was first called Atlas. Internal names keep it: the `Atlas` app target and scheme, the `AtlasCore` package, the bundle identifier `com.atlas.knowledge` (so existing settings and the chosen library survive) and the `atlas://` URL scheme. The built app is `Sematrica.app`.

## Run and try it

Open `Atlas.xcodeproj` in Xcode, select **Atlas / My Mac**, and Run. The app uses development ad-hoc signing and App Sandbox. OpenZIM is already vendored; no Homebrew packages, local server, Python runtime or external reader app are required by Sematrica.

1. In Library, choose a dedicated folder on your SSD, such as `/Volumes/SamsungT7/Sematrica`.
2. Under **Available**, choose **Kiwix library**, pick a **Collection** (Wikipedia by default) and **Load Catalog**. Select a language. Packages are sorted smallest first.
3. Choose **Download**. For a quick test, the English **Ray Charles** selection with images was about 3 MB in the catalog used during development. Availability, release dates, exact sizes and URLs are discovered live; this is not a pinned application package.
4. Watch **Downloading** for saved bytes, speed, ETA and verification. Use Pause, Resume/Retry, or Cancel Download as needed.
5. Under **Installed**, choose **Open**. Search for an article title, open a result, follow article links, and use Back, Forward and Contents.
6. Disconnect Internet access. Continue searching and reading the installed package. Catalog refresh and downloads need Internet; the reader does not.

Beyond Wikipedia, the **Collection** menu lists everything the Kiwix catalog offers that Sematrica can read: Wiktionary, Wikibooks, Wikisource, Wikivoyage, Wikiquote, Wikiversity, Project Gutenberg's public-domain books, Stack Exchange Q&A and more. The list comes from the catalog itself; collections made of video or interactive simulations (TED, PhET) are left out because Sematrica doesn't run archive scripts.

To add a ZIM file you already have (one you made, or downloaded elsewhere), choose **Import ZIM File…**. Sematrica opens it to check it's a readable ZIM and read its title and language, copies it into the library's `packages/` folder, verifies it and lists it under **Installed**. The original file is never changed. An import can't be paused or resumed; if it's cancelled or interrupted, remove it and import the file again.

For advanced datasets, choose **Wikimedia archives**, enter a Wikimedia project identifier such as `enwiki` or `simplewiki`, and load the catalog. These are downloaded and checksum-verified under `dumps/`, but are labeled **Archive only / Stored**. Sematrica does not render raw XML/SQL/history dumps.

The archives have one built-in use: Wikipedia's own link tables make a **link map**, the one thing a ZIM file doesn't carry. With a wiki's archive catalog loaded, **Download the Link Map Files** fetches its `page`, `redirect`, `pagelinks`, `linktarget` and `categorylinks` tables; then, under **Installed → Link maps**, **Build Link Map** turns them into compact files in the library's `indexes/` folder. A Wikipedia package in the same language uses the map when it opens. Connect the dots takes its chain from the whole web of links at once, "what links here" counts every article that links to a page, and category questions work. You still read the ZIM package; the map only supplies the links. English Wikipedia's tables are roughly 15 GB to download. A build takes on the order of 15–30 minutes and a few GB of memory, and leaves a map of several GB. Once the map is built, the table dumps can be deleted. Simple English is a few hundred MB and builds in under a minute. See [the companion guide](Docs/Companion.md#wikipedias-link-map).

Large articles and images remain on the selected storage device. Changing library folders never copies or deletes the old library. Switching storage pauses active downloads and closes the current reader.

Beside every article is a **reading companion** that answers questions and carries out tasks on the page, with an animated spider as its hands: counting ("how many capital letters are here?"), finding and highlighting in any colors ("find all adjectives that end with w and highlight them in green"), walking to targets and sections, following links, hunting for phrases and exploring by topic. It also answers exact questions across the whole library ("how many articles mention Atlantic Records?") and connects the dots between any two articles ("how is Ray Charles connected to Paris?"), walking the shortest chain of links and drawing it as a constellation. With a link map it also answers "what links here" and category questions. Common requests run instantly without a model; everything else uses one local Ollama call. See [the companion guide](Docs/Companion.md). **Ask** answers questions from an embedding index of chosen articles, and **Research** reads across the library to write cited reports ([Research](Docs/Research.md)).

## Build

```sh
xcodebuild -project Atlas.xcodeproj -scheme Atlas -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/AtlasStage2Build build
swift test --scratch-path /tmp/AtlasStage2Tests
open /tmp/AtlasStage2Build/Build/Products/Debug/Sematrica.app
```

Universal Release build:

```sh
xcodebuild -project Atlas.xcodeproj -scheme Atlas -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/AtlasStage2Release build
```

Build outside cloud-synced Documents folders: file-provider metadata can make codesign reject generated bundles. Xcode and SwiftPM require access to their normal compiler caches. Distribution signing/notarization and a project-wide distribution license are not configured.

## Architecture

The existing two-module architecture remains:

- **Atlas:** native SwiftUI presentation, observable main-actor view models, NSOpenPanel and workspace notifications, WKWebView integration.
- **AtlasCore:** storage actor, library identity and scoped access, catalog parsing, download lifecycle, manifests, verification, local URL policy and archive-provider contracts.
- **ZIMBridge:** a small C ABI around maintained OpenZIM C++. Exceptions stay inside C++; allocations have explicit ownership. `ZIMArticleProvider` confines its searcher to a Swift actor. The UI depends on `ArticleProvider`, not C++ or a concrete archive format.

Browsing, conventional search, the companion and the crawler keep separate interfaces. Search uses no AI. No full encyclopedia scan or one-object-per-article preload occurs.

### Catalog sources

[Kiwix OPDS v2](https://kiwix-tools.readthedocs.io/en/latest/kiwix-serve.html) is fetched from `https://opds.library.kiwix.org/catalog/v2/entries`, filtered to the chosen collection and paginated. The collections themselves come from `https://opds.library.kiwix.org/catalog/v2/categories`; until that list loads, a built-in list of the familiar ones is shown. Titles, languages, snapshot dates, descriptions, flavor tags, sizes and acquisition links come from this feed. Language choices are derived from returned entries. Mini packages are explicitly labeled abridged. Kiwix flavors are mapped to text-only, standard/images or full/images without inventing unavailable variants.

Current acquisition links use Metalink. Sematrica parses their exact byte count, full-file SHA-256/SHA-1/MD5 and HTTPS mirror URLs; it does not mistake piece hashes for a full-file checksum. The first prioritized HTTPS mirror is used. Catalog sizes may be rounded; the resolved exact size is used for downloading and verification.

[Wikimedia dumps](https://dumps.wikimedia.org/backup-index.html) are discovered from the selected project's dated directories. Sematrica checks the newest available snapshot manifests, reads `dumpstatus.json`, and lists only completed jobs/files with actual sizes and URLs. History files are classified separately. The available SHA-1/MD5 is retained. The newest snapshot can contain only the jobs completed so far; the UI lists those rather than inventing missing files.

Catalog fetches happen only when requested. Opening/searching installed packages does not refresh the catalog. Updates are indicated when a loaded catalog contains a newer release of the same family; existing versions are not overwritten automatically.

### Direct-to-library downloads

`DownloadManager` is an actor. `StreamTransfer` uses an ephemeral `URLSessionDataTask` with a serial delegate queue, no URL cache and identity transfer encoding. It writes incoming buffers directly through FileHandle into a `.partial` file on the selected volume. It deliberately does not use URLSession's download-task temporary storage, which could reside on the internal disk.

Before writing, Sematrica validates the library UUID, required directories, write availability and free capacity against the exact remaining bytes, leaving a small metadata margin. File writes and hashing stay off the main actor. Progress/checkpoints are updated about once per second, with file synchronization before a persisted progress report. Every operation retains a security-scoped `LibraryAccess` for its lifetime.

Pause cancels the network request while retaining partial bytes. Resume obtains the actual on-disk length and requests the remaining HTTP byte range, using a strong ETag or Last-Modified validator when available. Sematrica rejects ignored/misaligned ranges, changed totals, encoded responses and excess/incomplete bytes. If a server refuses ranges, the UI explains that the partial download must be canceled and restarted. Retry is user-controlled; there is no hidden switch to another storage device.

On restart, manifests left in Downloading/Verifying become resumable. A crash after final rename but before manifest registration is recovered by re-verifying the final file. An interrupted initial setup can be repaired by explicitly choosing the same folder. Unavailable-drive checks are read-only and never recreate the old mount point.

### Verification and manifests

Each package has an atomic `metadata/package-<stable-hash>.json` record. Paths are relative to the selected library, so volume renames do not embed a brittle mount path. Records preserve package metadata, checksum, validators, partial progress, state, verification and user-facing recovery messages. A corrupt manifest is reported and preserved; Sematrica does not silently replace it with an empty library.

`FileVerifier` hashes in 1 MiB chunks and checks exact size. ZIM files must also open successfully through libzim; where an external checksum is unavailable, libzim's internal checksum is checked. Only after successful validation is the partial file renamed on the same device and marked Installed. Raw datasets without an upstream checksum would be labeled unverified after size validation; the tested official Wikimedia dataset had a checksum.

Manual Verify uses the same pipeline and exposes corruption. Delete/Cancel requires confirmation in the app and only removes that package's generated file paths and record. Root/subdirectory symbolic links, traversal paths and manipulated record paths are rejected.

### Native ZIM dependency

Sematrica embeds **OpenZIM libzim 9.8.2, official macOS build revision 1**, as a universal dylib. It supplies random-access archive reads, decompression, redirect resolution and built-in title suggestions. Its only dynamic dependencies are Apple's system libraries; users do not install a separate reader.

See [dependency provenance, hashes and licensing](Vendor/libzim/README.md), [GPL notice](Vendor/libzim/COPYING), and `Scripts/prepare-libzim.sh` for reproducibility. libzim is GPL-2.0-or-later; distribution must meet libzim and bundled dependency license/source obligations. This task has not assigned a license to the entire Sematrica project.

### Strict offline browser

The reader uses `atlas://<package-key>/<archive-path>` with a `WKURLSchemeHandler`; there is no listening HTTP server. HTML, images, CSS, fonts and other local resources are read from the archive. Resource delivery is chunked; individual HTML documents are bounded to 32 MiB for security-policy injection. Entire archives are never loaded into RAM.

Archive scripts are disabled. Every HTML document receives a restrictive Content Security Policy. A compiled WebKit content rule list separately blocks HTTP(S), WebSocket, FTP and file requests. The navigation delegate permits only the current local archive. Absolute Wikipedia article links are redirected to local article lookup; other external links are labeled and blocked. Missing content stays a local unavailable state and never falls back to the Internet. Each reader uses a nonpersistent website data store.

Archive redirects are resolved to canonical paths before top-level navigation, preserving relative styles and image links. WKWebView owns Back/Forward history. An isolated client-world bridge extracts article headings for the Contents menu and marks external links. Remote references are not fetched just because an article contains them.

### Local search and crawler boundary

`FullTextSearch` remains independent of LLMProvider. Stage 2 implements **title search** with libzim's SuggestionSearcher: it uses the embedded title index where available and libzim's ordered-title fallback otherwise. A fallback archive may require original capitalization/prefixes. Sematrica does not build a second index for browsing. Research can build an optional SQLite FTS5 index; fuzzy title search remains future work.

`atlasDocument` retains the isolated Contents bridge. Phase 3 adds `atlasTerrain` in the same isolated client world and an origin-checked `atlasCrawlerMetrics` handler. Only bounded local word/terrain observations reach the crawler. Its target never enters JavaScript or the archive search provider. Native rendering, local perception and medium-level navigation run separately. See [the crawler architecture and verification record](Docs/Phase3.md).

## Stage 2 automated verification

Verified on the development Apple Silicon Mac with Xcode 27 / Swift 6.4:

- Debug application build and universal arm64/x86_64 Release build succeeded.
- The final complete run passed **28 tests with zero failures and zero skips**, including all Stage 1 regressions and opted-in integration/recovery tests.
- Catalog parsing, checksum selection, streamed corruption/size checks, manifest relocation/path safety, local URL encoding and invalid-ZIM tests passed.
- Live Kiwix download: English Ray Charles, snapshot 2026-08-02, **3,010,245 bytes**, selected from the live catalog. Download, SHA-256 verification, atomic installation, manifest rediscovery, title search, article, image, CSS and link retrieval passed.
- Live Wikimedia archive: `simplewiki-20261001-site_stats.sql.gz`, **860 bytes**, discovered from the official manifest, downloaded and checksum-verified as archive-only.
- Core title search/article/image/CSS/link test passed under an OS sandbox denying all networking.
- The smoke harness compiles the actual BrowserModel/OfflineWebView sources. Article rendering, a loaded local image, **25 loaded stylesheets**, Contents, actual hyperlink click, Back, Forward and blocked external navigation passed, including with networking denied to the test process.
- A throttled localhost fixture verified pause, saved partial bytes, restart recovery, ranged continuation, manual verification, corruption detection, deletion and rejection of ignored Range requests. A mid-download library-path disappearance also recovered after restoration without creating a fallback directory.

Standard `swift test` skips the explicitly opted-in live/fixture tests. To reproduce the integration checks:

```sh
# Download a small official ZIM and tiny raw dump into temporary test libraries.
ATLAS_RUN_LIVE_TESTS=1 swift test --scratch-path /tmp/AtlasStage2Tests

# In a separate terminal, serve the downloaded fixture locally, with throttling.
python3 Scripts/range-fixture.py
# Then run recovery tests (stop the fixture server afterward).
ATLAS_RUN_RECOVERY_TESTS=1 swift test --scratch-path /tmp/AtlasStage2Tests --filter DownloadRecoveryTests

# Build Debug first; this harness uses the actual application browser sources.
ATLAS_DENY_NETWORK=1 Scripts/test-browser.sh

# Direct XCTest execution avoids SwiftPM's nested compiler sandbox.
ATLAS_RUN_OFFLINE_TESTS=1 sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest AtlasCoreTests.LiveWikipediaTests/testOfflineSearchResourcesAndLinks \
  /tmp/AtlasStage2Tests/out/Products/Debug/AtlasCoreTests.xctest
```

The XCTest product path above is for the verified Swift 6.4 build system; older SwiftPM layouts differ. Network-denial tests affect only their test processes, not the Mac's Internet connection. Integration fixtures remain under `/tmp/AtlasStage2LiveLibrary` and `/tmp/AtlasStage2RawLiveLibrary` for inspection; they are not the user's selected application library. Only test setup uses those temporary destinations.

## Manual acceptance and known limits

Physical SSD unplug/replug, volume renaming, full disks, and sandbox folder permission restoration in the actual signed app still need hardware acceptance. Automated tests cover underlying invariants and simulated path loss, not every filesystem/device failure mode. The implementation never intentionally changes the destination to internal storage.

Run the requested acceptance sequence on your SSD: download → open → search → follow links → Back/Forward → quit/relaunch → disconnect Internet → search/read/follow several more links. Then repeat while ejecting and reconnecting the SSD, including relaunch while disconnected. Confirm it is rediscovered without another folder selection. Test a renamed volume and verify errors remain understandable when permission is revoked or the disk is full.

Other limits:

- Very large 30–500 GB archives and macOS 14/Intel runtime performance have not been physically exercised. Release compiles for both architectures.
- HTTP resumption requires a valid byte-range response. Servers refusing it require cancel/re-download. Automatic mirror failover and scheduled/background downloads while Sematrica is quit are not implemented.
- Title search is implemented; full-text, fuzzy search, persistent reading history and article bookmarks are not. In-session Back/Forward works.
- JavaScript-dependent interactive article widgets are disabled by design. The tested Wikipedia package renders its static encyclopedia content, images and styles offline.
- Raw/historical shards are stored independently; no MediaWiki importer, reconstruction or rendering pipeline exists.
- Catalog contents are fetched on request rather than cached across launches. Installed packages remain available without a catalog.
- Simultaneous mutation by multiple Sematrica application processes is unsupported. Do not run two copies against the same library.
- Native libzim's full internal checksum fallback is not interruptible mid-call; official Metalink checksums use the cancellable streaming verifier.

## Files

Stage 1 files modified:

- `Package.swift`, `Atlas.xcodeproj/project.pbxproj`: native bridge dependency and dylib embedding; existing app configuration retained.
- `Atlas/Atlas.entitlements`: outbound network entitlement for catalog/download operations.
- `Atlas/Assets.xcassets/AppIcon.appiconset`: the app icon (a glowing constellation spider walking in a dark rounded square), at every macOS size from 16 to 1024 px. To change it, replace the PNGs at the same sizes; `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` points the build at it.
  macOS caches app icons, so after the icon changes Finder and a pinned Dock item can keep the old one. The running app always shows its own icon (`AtlasApp` sets it at launch from the bundle); to refresh the caches too, quit the app, raise `CURRENT_PROJECT_VERSION`, rebuild, and run `killall Dock Finder`.
- `Atlas/Assets.xcassets/SematricaEmblem.imageset`: the same creature cut out of its tile on a transparent background, used for the companion's header and the toolbar's **Companion** button. Replace it whenever the app icon changes.
- `Atlas/App/LibraryViewModel.swift`: reuse existing storage while coordinating package state and long-lived access.
- `Atlas/UI/ContentView.swift`, `Atlas/UI/LibraryView.swift`: functional Library/Browse/Search screens; Crawl was subsequently implemented in Phase 3.
- `AtlasCore/Library/LibraryModels.swift`, `AtlasCore/Library/StorageManager.swift`: expanded package model moved into its own file; scoped access lease added.
- `AtlasCore/Wikipedia/ArticleProvider.swift`: format-independent resource/title-search contract.
- `README.md`: current architecture, usage, tests, limits and next stage.

Files added:

- `AtlasCore/Library/PackageModels.swift`, `PackageCatalog.swift` (with `KiwixCollection`), `PackageManifest.swift`, `StreamTransfer.swift`, `DownloadManager.swift` (downloads and imports), `FileVerifier.swift`, `PackageImport.swift` (what an imported file becomes, and the copy).
- `AtlasCore/Wikipedia/ZIMArticleProvider.swift`, `OfflineURL.swift`.
- `Atlas/App/PackageLibraryModel.swift`, `BrowserModel.swift`.
- `Atlas/UI/PackagesView.swift`, `BrowserView.swift`, `OfflineWebView.swift`.
- `Native/ZIMBridge/ZIMBridge.cpp`, `include/ZIMBridge.h`.
- `Vendor/libzim/`: official headers, universal dylib, license and provenance.
- `Tests/AtlasCoreTests/Stage2Tests.swift`, `DownloadRecoveryTests.swift`, `Tests/BrowserSmoke/BrowserSmoke.swift`.
- `Scripts/prepare-libzim.sh`, `range-fixture.py`, `test-browser.sh`.
