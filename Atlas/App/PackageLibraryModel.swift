import Foundation
import Observation
import AtlasCore

@MainActor @Observable
final class PackageLibraryModel {
    let browser=BrowserModel()
    let intelligence:IntelligenceModel
    var catalog: [WikipediaPackage] = []
    var records: [PackageRecord] = []
    var progress: [String:TransferProgress] = [:]
    var language = "eng"
    var catalogSource = "Wikipedia"
    var dumpProject = "enwiki"
    var loadingCatalog=false
    var busyPackages: Set<String> = []
    var message: String?
    var storageAvailable=false
    var rootPath: String?
    private let storage: StorageManager
    private let downloads: DownloadManager
    private let source=PackageCatalog()
    private var polling: Task<Void,Never>?
    private var libraryID: UUID?
    init(storage: StorageManager) {
        self.storage=storage; downloads=DownloadManager(storage:storage);intelligence=IntelligenceModel(storage:storage)
        browser.crawler.intelligence.provider=intelligence.provider
        browser.crawler.intelligence.model=intelligence.chatModel
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
    var pending: [PackageRecord] { records.filter {$0.state != .installed && $0.state != .corrupted} }
    func storageChanged(_ state: StorageState) async {
        switch state {
        case .available(let snapshot):
            storageAvailable=true; rootPath=snapshot.root.path
            if libraryID != snapshot.library.id { intelligence.reset();browser.close(); libraryID=snapshot.library.id }
            do { try await downloads.connect(); await refresh() } catch { message=AtlasLog.message(error) }
            if polling == nil {
                polling=Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.refresh()
                        do { try await Task.sleep(for:.seconds(1)) } catch { break }
                    }
                }
            }
        default:
            storageAvailable=false; rootPath=nil; intelligence.reset();browser.close(); await downloads.disconnect()
        }
    }
    func refresh() async { let snapshot=await downloads.snapshot(); records=snapshot.records; progress=snapshot.progress }
    func pauseAll() async { await downloads.pauseAll(); await refresh(); intelligence.reset();browser.close() }
    func loadCatalog() async {
        guard !loadingCatalog else { return }
        loadingCatalog=true; defer { loadingCatalog=false }
        do {
            let next = try await (catalogSource == "Wikipedia" ? source.wikipedia() : source.wikimedia(project:dumpProject.lowercased()))
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
    func pause(_ id: String) async { await downloads.pause(id); await refresh() }
    func resume(_ id: String) async {
        do { try await downloads.connect(); try await downloads.resume(id); await refresh() } catch { message=AtlasLog.message(error) }
    }
    func delete(_ id: String) async {
        if browser.record?.id == id {intelligence.reset();browser.close()}
        do { try await downloads.delete(id); await refresh() } catch { message=AtlasLog.message(error) }
    }
    func verify(_ id: String) async {
        if browser.record?.id == id {intelligence.reset();browser.close()}
        do { try await downloads.verify(id); await refresh() } catch { message=AtlasLog.message(error) }
    }
    func open(_ record: PackageRecord) async {
        do {intelligence.reset();let access=try await storage.acquire();try await browser.open(record:record,access:access)}
        catch { message=AtlasLog.message(error) }
    }
    func updateAvailable(_ record: PackageRecord) -> Bool {
        catalog.contains {$0.family == record.package.family && $0.version > record.package.version}
    }
}
