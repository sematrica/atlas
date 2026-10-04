import Foundation

public actor DownloadManager {
    private let storage: StorageManager
    private var access: LibraryAccess?
    private var records: [String:PackageRecord] = [:]
    private var tasks: [String:Task<Void,Never>] = [:]
    private var progress: [String:TransferProgress] = [:]
    public init(storage: StorageManager) { self.storage=storage }
    public func snapshot() -> (records:[PackageRecord], progress:[String:TransferProgress]) {
        (records.values.sorted {$0.updatedAt > $1.updatedAt},progress)
    }
    public func connect() async throws {
        let newAccess=try await storage.acquire()
        if access?.libraryID == newAccess.libraryID { access=newAccess; return }
        guard tasks.isEmpty else { throw AtlasError.busy }
        let stored=try PackageManifest(access:newAccess).load()
        var next: [String:PackageRecord]=[:]
        for var record in stored {
            if record.state == .downloading || record.state == .verifying {
                record.state = .paused; record.message="Interrupted when Atlas closed. Resume to continue or finish verification."
                try PackageManifest(access:newAccess).save(record)
            }
            if record.state == .installed {
                let url=try newAccess.file(record.relativePath)
                let size=(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize).map(Int64.init)
                if size != record.package.downloadBytes { record.state = .corrupted; record.verification = .failed; try PackageManifest(access:newAccess).save(record) }
            }
            next[record.id]=record
        }
        access=newAccess; records=next; progress=[:]
    }
    public func disconnect() { tasks.values.forEach {$0.cancel()}; access=nil }
    public func start(_ package: WikipediaPackage) async throws {
        try await connect()
        guard let access else { throw AtlasError.storageUnavailable }
        guard tasks[package.id] == nil,records[package.id] == nil else { throw AtlasError.busy }
        let record=PackageRecord(package:package)
        try PackageManifest(access:access).save(record); records[record.id]=record
        try resume(record.id)
    }
    public func resume(_ id: String) throws {
        guard let access,let record=records[id] else { throw AtlasError.storageUnavailable }
        try access.validate()
        guard tasks[id] == nil,record.state != .installed,record.state != .corrupted else { throw AtlasError.busy }
        tasks[id]=Task { await self.run(id:id,access:access) }
    }
    public func pause(_ id: String) async {
        let task=tasks[id]; task?.cancel(); await task?.value
    }
    public func pauseAll() async {
        let active=Array(tasks.values); active.forEach {$0.cancel()}
        for task in active { await task.value }
    }
    public func delete(_ id: String) async throws {
        await pause(id)
        guard let access,let record=records[id] else { throw AtlasError.storageUnavailable }
        try PackageManifest(access:access).delete(record)
        records[id]=nil; progress[id]=nil
    }
    public func verify(_ id: String) throws {
        guard let access,var record=records[id],tasks[id] == nil,
              [.installed,.corrupted].contains(record.state) else { throw AtlasError.busy }
        record.state = .verifying; record.verification = .verifying
        try save(record,access:access)
        tasks[id]=Task { await self.runVerification(id:id,access:access) }
    }
    private func save(_ record: PackageRecord, access: LibraryAccess) throws {
        try PackageManifest(access:access).save(record); records[record.id]=record
    }
    private func receivedHeaders(_ headers: StreamTransfer.Headers, id:String, access:LibraryAccess) throws {
        guard var record=records[id] else { throw AtlasError.incompleteDownload }
        record.etag=headers.etag; record.lastModified=headers.modified
        try save(record,access:access)
    }
    private func receivedProgress(id:String,bytes:Int64,speed:Double,access:LibraryAccess) {
        guard var record=records[id],record.state == .downloading else { return }
        record.receivedBytes=bytes; records[id]=record; progress[id]=TransferProgress(bytesPerSecond:speed)
        do { try PackageManifest(access:access).save(record) } catch { tasks[id]?.cancel() }
    }
    private func verifyingProgress(id:String,fraction:Double) { progress[id]=TransferProgress(verificationFraction:fraction) }
    private func checkFile(record:PackageRecord,access:LibraryAccess,path:String) async throws {
        let url=try access.file(path)
        let worker=Task.detached(priority:.utility) {
            try FileVerifier.verify(url:url,size:record.package.downloadBytes,checksum:record.package.checksum) { fraction in
                Task { await self.verifyingProgress(id:record.id,fraction:fraction) }
            }
            try access.validate()
            if record.package.format == .zim {
                var local=record; local.relativePath=path
                let reader=try ZIMArticleProvider(access:access,record:local)
                _ = try await reader.info()
                if record.package.checksum == nil { try await reader.validateArchive() }
            }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private func run(id:String,access:LibraryAccess) async {
        defer { tasks[id]=nil; progress[id]=nil }
        do {
            guard var record=records[id] else { return }
            let partial=try access.file(record.partialPath), final=try access.file(record.relativePath)
            // A crash after rename but before manifest update is recovered by re-verifying the final file.
            if !FileManager.default.fileExists(atPath:final.path) {
                var offset=Int64((try? partial.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
                guard offset <= record.package.downloadBytes else { throw AtlasError.checksumMismatch }
                let snapshot=try access.validate()
                guard !snapshot.isReadOnly else { throw AtlasError.storageUnavailable }
                guard let free=snapshot.availableBytes,free >= 16*1024*1024, record.package.downloadBytes-offset <= free-16*1024*1024 else { throw AtlasError.insufficientSpace }
                if !FileManager.default.fileExists(atPath:partial.path) {
                    guard FileManager.default.createFile(atPath:partial.path,contents:nil) else { throw AtlasError.storageUnavailable }
                }
                // Without a checksum or HTTP validator, a partial file cannot be safely resumed.
                if offset > 0,record.package.checksum == nil,record.etag == nil,record.lastModified == nil {
                    let file=try FileHandle(forWritingTo:partial); try file.truncate(atOffset:0); try file.close(); offset=0
                }
                record.state = .downloading; record.message=nil; record.receivedBytes=offset; try save(record,access:access)
                if offset < record.package.downloadBytes {
                    let validator=record.etag.flatMap {$0.hasPrefix("W/") ? nil : $0} ?? record.lastModified
                    let transfer=StreamTransfer(destination:partial,access:access,size:record.package.downloadBytes,offset:offset,validator:validator,
                                                onHeaders: { try await self.receivedHeaders($0,id:id,access:access) },
                                                onProgress: { bytes,speed in Task { await self.receivedProgress(id:id,bytes:bytes,speed:speed,access:access) } })
                    try await transfer.run(url:record.package.downloadURL)
                }
            }
            try Task.checkCancellation()
            guard var current=records[id] else { return }
            current.state = .verifying; current.verification = .verifying; current.receivedBytes=current.package.downloadBytes
            try save(current,access:access)
            let hasFinal=FileManager.default.fileExists(atPath:final.path)
            try await checkFile(record:current,access:access,path:hasFinal ? current.relativePath : current.partialPath)
            try Task.checkCancellation(); try access.validate()
            if !hasFinal { try FileManager.default.moveItem(at:partial,to:final) }
            current.state = .installed; current.verification=current.package.checksum != nil || current.package.format == .zim ? .verified : .unverified
            current.updatedAt=Date(); current.message=nil; try save(current,access:access)
        } catch { fail(id:id,error:error,access:access,installed:false) }
    }
    private func runVerification(id:String,access:LibraryAccess) async {
        defer { tasks[id]=nil; progress[id]=nil }
        do {
            guard var record=records[id] else { return }
            record.state = .verifying; record.verification = .verifying; record.message=nil; try save(record,access:access)
            try await checkFile(record:record,access:access,path:record.relativePath)
            try Task.checkCancellation()
            record.state = .installed; record.verification=record.package.checksum != nil || record.package.format == .zim ? .verified : .unverified
            try save(record,access:access)
        } catch { fail(id:id,error:error,access:access,installed:true) }
    }
    private func fail(id:String,error:Error,access:LibraryAccess,installed:Bool) {
        guard var record=records[id] else { return }
        let cancelled=Task.isCancelled || error is CancellationError
        let corrupted=(error as? AtlasError).map { if case .checksumMismatch = $0 { return true }; return false } ?? false
        record.state = corrupted || installed && !cancelled ? .corrupted : .paused
        record.verification = corrupted ? .failed : .unverified
        if !cancelled && !corrupted && !installed { record.state = .failed }
        record.message=cancelled ? "Paused. Resume when your library is available." : AtlasLog.message(error)
        records[id]=record
        try? PackageManifest(access:access).save(record)
    }
}
