import Foundation

/// One atomic manifest per package limits write amplification and isolates damaged records.
public struct PackageManifest: Sendable {
    public let access: LibraryAccess
    public init(access: LibraryAccess) { self.access = access }
    private func path(_ key: String) throws -> URL { try access.file("metadata/package-\(key).json") }
    public func save(_ record: PackageRecord) throws {
        try access.validate()
        let data = try JSONEncoder().encode(record)
        try data.write(to: path(record.package.storageKey), options: .atomic)
    }
    public func load() throws -> [PackageRecord] {
        try access.validate()
        let directory = try access.file("metadata")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("package-") && $0.pathExtension == "json" }
            .map { url in
                let safe = try access.file("metadata/" + url.lastPathComponent)
                guard let record = try? JSONDecoder().decode(PackageRecord.self, from: Data(contentsOf: safe)),
                      url.lastPathComponent == "package-\(record.package.storageKey).json" else { throw AtlasError.invalidManifest }
                _ = try access.file(record.relativePath); _ = try access.file(record.partialPath)
                // Only Atlas-generated names may be deleted or overwritten.
                guard record.relativePath == PackageRecord(package: record.package).relativePath else { throw AtlasError.invalidManifest }
                return record
            }
    }
    public func delete(_ record: PackageRecord) throws {
        guard record.relativePath == PackageRecord(package:record.package).relativePath else { throw AtlasError.invalidManifest }
        try access.validate()
        for relative in [record.relativePath, record.partialPath] {
            let url = try access.file(relative)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let url = try path(record.package.storageKey)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
