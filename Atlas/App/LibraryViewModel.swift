import AppKit
import AtlasCore
import Observation

@MainActor @Observable
final class LibraryViewModel {
    private(set) var state: StorageState = .unconfigured
    private(set) var isBusy = false
    var errorMessage: String?
    let storage: StorageManager
    let packages: PackageLibraryModel
    private var observers: [NSObjectProtocol] = []
    private var monitor: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storage = StorageManager(store: FileBookmarkStore(file: support.appendingPathComponent("Atlas/library-selection.json")))
        self.storage = storage
        packages = PackageLibraryModel(storage: storage)
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        state = await storage.refresh()
        await packages.storageChanged(state)
    }

    func chooseStorage() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let panel = NSOpenPanel()
        await packages.pauseAll()
        panel.title = "Choose your Atlas library folder"
        panel.message = "Choose or create a dedicated folder, such as Atlas on your external SSD. Library files will stay in this folder."
        panel.prompt = "Use for Atlas"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return }
        do {
            state = .available(try await storage.select(url))
            await packages.storageChanged(state)
            errorMessage = nil
        } catch {
            errorMessage = AtlasLog.message(error)
        }
    }
}
