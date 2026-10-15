import Foundation
import Observation
import AtlasCore

/// A link map built in the library's indexes folder.
struct BuiltLinkMap: Identifiable, Sendable {
    var id: String { directory.lastPathComponent }
    let manifest: LinkMapManifest
    let directory: URL
    let bytes: Int64
}

/// A link map being built from a dump's tables.
struct LinkMapBuild {
    let id: String
    var progress: LinkMapProgress?
}

@MainActor @Observable
final class PackageLibraryModel {
    let browser=BrowserModel()
    let intelligence:IntelligenceModel
    let research:ResearchModel
    var catalog: [WikipediaPackage] = []
    var records: [PackageRecord] = []
    var progress: [String:TransferProgress] = [:]
    var language = "eng"
    /// Kiwix (the openZIM catalog, every collection) or Archives (Wikimedia dumps).
    var catalogSource = "Kiwix"
    /// The Kiwix collection being browsed; the list is replaced by the catalog's own once it loads.
    var collection = "wikipedia"
    var collections = KiwixCollection.defaults
    var importing=false
    /// The Packages tab shown in Library: Available, Downloading or Installed.
    var packagesSection = "Available"
    var dumpProject = "enwiki"
    var loadingCatalog=false
    var busyPackages: Set<String> = []
    /// Link maps built from Wikimedia table dumps (Connect the dots, what links here, categories).
    var linkMaps: [BuiltLinkMap] = []
    var linkMapBuild: LinkMapBuild?
    var message: String?
    var storageAvailable=false
    var rootPath: String?
    private let storage: StorageManager
    private let downloads: DownloadManager
    private let source=PackageCatalog()
    private var polling: Task<Void,Never>?
    private var libraryID: UUID?
    private var collectionsLoaded=false
    private var buildTask: Task<Void,Never>?
    init(storage: StorageManager) {
        self.storage=storage; downloads=DownloadManager(storage:storage);intelligence=IntelligenceModel(storage:storage);research=ResearchModel(storage:storage)
        browser.crawler.intelligence.provider=intelligence.provider
        browser.crawler.intelligence.model=intelligence.chatModel
        let crawler=browser.crawler
        intelligence.onChatModelChange={[weak crawler] name in crawler?.intelligence.model=name}
        intelligence.onFitChange={[weak crawler] badge in crawler?.intelligence.fit=badge}
        let ai=intelligence
        Task {await ai.evaluateFit()}
        browser.crawler.intelligence.persist={discovery in
            do {
                let access=try await storage.acquire()
                try await Task.detached {
                    try access.validate()
                    let file=try access.file("metadata/discovery-"+UUID().uuidString+".json")
                    try JSONEncoder().encode(discovery).write(to:file,options:.atomic)
                }.value
            } catch { /* The visible discovery is retained if storage disappears. */ }
        }
    }
    var languages: [String] { Array(Set(catalog.map(\.languageCode))).sorted() }
    var filteredCatalog: [WikipediaPackage] { catalog.filter { language.isEmpty || $0.languageCode == language } }
    var installed: [PackageRecord] { records.filter {$0.state == .installed || $0.state == .corrupted} }
    /// Installed packages Browse can open.
    var readable: [PackageRecord] { installed.filter {$0.package.format == .zim && $0.state == .installed} }
    /// Installed Wikimedia archives: data tables, not articles.
    var archives: [PackageRecord] { installed.filter {$0.package.format == .archive} }
    /// Shows the Kiwix library's Wikipedia packages in Packages → Available.
    func showReadablePackages() {
        packagesSection = "Available"
        if catalogSource != "Kiwix" || collection != "wikipedia" { catalogSource = "Kiwix"; collection = "wikipedia"; language = "eng"; catalog = [] }
        if catalog.isEmpty { Task { await loadCatalog() } }
    }
    /// Downloaded table dumps, grouped into the sets a link map is built from.
    var dumpSets: [LinkMapLibrary.DumpSet] { LinkMapLibrary.dumpSets(records) }
    /// The newest dump's link map tables in the loaded Wikimedia catalog.
    var linkMapFiles: [WikipediaPackage] { catalogSource == "Archives" ? LinkMapLibrary.downloads(in:catalog) : [] }
    var pending: [PackageRecord] { records.filter {$0.state != .installed && $0.state != .corrupted} }
    func storageChanged(_ state: StorageState) async {
        switch state {
        case .available(let snapshot):
            storageAvailable=true; rootPath=snapshot.root.path
            if libraryID != snapshot.library.id { intelligence.reset();research.reset();browser.close(); libraryID=snapshot.library.id }
            do { try await downloads.connect(); await refresh() } catch { message=AtlasLog.message(error) }
            await refreshLinkMaps()
            if polling == nil {
                polling=Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.refresh()
                        do { try await Task.sleep(for:.seconds(1)) } catch { break }
                    }
                }
            }
        default:
            cancelLinkMapBuild(); linkMaps=[]
            storageAvailable=false; rootPath=nil; intelligence.reset();research.reset();browser.close(); await downloads.disconnect()
        }
    }
    func refresh() async { let snapshot=await downloads.snapshot(); records=snapshot.records; progress=snapshot.progress }
    func pauseAll() async { await downloads.pauseAll(); await refresh(); intelligence.reset();research.reset();browser.close() }
    func loadCatalog() async {
        guard !loadingCatalog else { return }
        loadingCatalog=true; defer { loadingCatalog=false }
        do {
            let next: [WikipediaPackage]
            if catalogSource == "Kiwix" {
                if !collectionsLoaded, let list=try? await source.kiwixCollections(), !list.isEmpty {
                    collections=list; collectionsLoaded=true
                    if !list.contains(where:{$0.id == collection}) { collection="wikipedia" }
                }
                next=try await source.kiwix(collection:collection)
            } else {
                next=try await source.wikimedia(project:dumpProject.lowercased())
            }
            catalog=next
            if !language.isEmpty && !languages.contains(language) { language="" }
            message=nil
        } catch { message=AtlasLog.message(error) }
    }
    func download(_ package: WikipediaPackage) async {
        guard !busyPackages.contains(package.id) else { return }
        busyPackages.insert(package.id); defer { busyPackages.remove(package.id) }
        do { let resolved=try await source.resolve(package); try await downloads.start(resolved); message=nil; await refresh() }
        catch { message=AtlasLog.message(error) }
    }
    /// Brings a ZIM file the user chose into the library: it's opened to check it's a ZIM and read
    /// its title and language, then copied in, verified and listed with the installed packages.
    func importFile(_ url: URL) async {
        guard !importing else { return }
        importing=true; defer { importing=false }
        do {
            let info=try await Task.detached { try ZIMArticleProvider.fileInfo(at:url) }.value
            let size=Int64((try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0)
            guard size > 0 else { throw AtlasError.notZIM }
            try await downloads.importArchive(from:url,package:PackageImport.package(for:info,file:url,size:size))
            message=nil; await refresh()
        } catch { message=AtlasLog.message(error) }
    }
    func pause(_ id: String) async { await downloads.pause(id); await refresh() }
    func resume(_ id: String) async {
        do { try await downloads.connect(); try await downloads.resume(id); await refresh() } catch { message=AtlasLog.message(error) }
    }
    func delete(_ id: String) async {
        if browser.record?.id == id {intelligence.reset();research.reset();browser.close()}
        do { try await downloads.delete(id); await refresh() } catch { message=AtlasLog.message(error) }
    }
    func verify(_ id: String) async {
        if browser.record?.id == id {intelligence.reset();research.reset();browser.close()}
        do { try await downloads.verify(id); await refresh() } catch { message=AtlasLog.message(error) }
    }
    func open(_ record: PackageRecord) async {
        do {intelligence.reset();research.reset();let access=try await storage.acquire();try await browser.open(record:record,access:access)}
        catch { message=AtlasLog.message(error) }
    }
    // MARK: Link maps

    /// Downloads the newest dump's link map tables that aren't in the library yet.
    func downloadLinkMapFiles() async {
        for package in linkMapFiles where !records.contains(where:{$0.id == package.id}) { await download(package) }
    }
    func refreshLinkMaps() async {
        guard let access=try? await storage.acquire() else { linkMaps=[]; return }
        linkMaps=await Task.detached { () -> [BuiltLinkMap] in
            guard let indexes=try? access.file("indexes") else { return [] }
            return LinkMapLibrary.installed(in:indexes).map { entry in
                let files=(try? FileManager.default.contentsOfDirectory(at:entry.directory,includingPropertiesForKeys:[.fileSizeKey])) ?? []
                let bytes=files.reduce(Int64(0)) { $0+Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
                return BuiltLinkMap(manifest:entry.manifest,directory:entry.directory,bytes:bytes)
            }
        }.value
    }
    /// Builds a link map from a dump's downloaded tables, off the main thread. It takes minutes for a
    /// large Wikipedia; the open package picks the map up when it's done.
    func buildLinkMap(_ set: LinkMapLibrary.DumpSet) {
        guard linkMapBuild == nil, set.missing.isEmpty else { return }
        let records=self.records, storage=self.storage
        linkMapBuild=LinkMapBuild(id:set.id)
        buildTask=Task {
            do {
                let access=try await storage.acquire()
                let work=Task.detached(priority:.utility) { () throws -> LinkMapManifest in
                    func file(_ table: String) throws -> URL? {
                        guard let id=set.records[table],let record=records.first(where:{$0.id == id}) else { return nil }
                        return try access.file(record.relativePath)
                    }
                    guard let page=try file("page"),let redirect=try file("redirect"),let pagelinks=try file("pagelinks") else { throw LinkMapError.missingTables(set.missing) }
                    let sources=LinkMapSources(project:set.project,date:set.date,page:page,redirect:redirect,pagelinks:pagelinks,
                                               linktarget:try file("linktarget"),categorylinks:try file("categorylinks"))
                    let indexes=try access.file("indexes")
                    if let free=try access.validate().availableBytes, free < LinkMapBuilder.estimatedSpace(sources) { throw LinkMapError.insufficientSpace }
                    let directory=indexes.appendingPathComponent(LinkMapLibrary.directoryName(project:set.project,date:set.date))
                    return try LinkMapBuilder.build(sources,into:directory) { progress in
                        Task { @MainActor in if self.linkMapBuild?.id == set.id { self.linkMapBuild?.progress=progress } }
                    }
                }
                _ = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                message=nil
            } catch is CancellationError {
            } catch { message=AtlasLog.message(error) }
            linkMapBuild=nil; buildTask=nil
            await refreshLinkMaps()
            await browser.loadLinkMap()
        }
    }
    func cancelLinkMapBuild() { buildTask?.cancel() }
    func deleteLinkMap(_ map: BuiltLinkMap) async {
        if browser.linkMap?.directory == map.directory { browser.linkMap=nil }
        do {
            let access=try await storage.acquire()
            try await Task.detached {
                let indexes=try access.file("indexes")
                guard map.directory.deletingLastPathComponent().standardizedFileURL == indexes.standardizedFileURL,
                      map.directory.lastPathComponent.hasPrefix("linkmap-") else { throw AtlasError.invalidPath }
                try FileManager.default.removeItem(at:map.directory)
            }.value
            message=nil
        } catch { message=AtlasLog.message(error) }
        await refreshLinkMaps()
        await browser.loadLinkMap()
    }

    func updateAvailable(_ record: PackageRecord) -> Bool {
        catalog.contains {$0.family == record.package.family && $0.version > record.package.version}
    }
}
