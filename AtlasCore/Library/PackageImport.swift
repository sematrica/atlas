import Foundation

/// What a ZIM file says about itself, read before it's imported.
public struct ZIMFileInfo: Sendable, Equatable {
    public var uuid: String
    public var title: String
    public var name: String
    /// ISO 639-3 codes, comma-separated when there are several ("eng" or "eng,fra").
    public var language: String
    public var description: String
    public var date: String
    public var flavour: String
    public var tags: String
    public init(uuid: String = "", title: String = "", name: String = "", language: String = "", description: String = "",
                date: String = "", flavour: String = "", tags: String = "") {
        self.uuid=uuid; self.title=title; self.name=name; self.language=language; self.description=description
        self.date=date; self.flavour=flavour; self.tags=tags
    }
}

/// Bringing a ZIM file the user already has (made themselves, or downloaded elsewhere) into the library.
public enum PackageImport {
    public static let source="Imported"

    /// The package an imported file becomes. Its ID comes from the file's own UUID, so importing the
    /// same file twice is noticed.
    public static func package(for info: ZIMFileInfo, file: URL, size: Int64) -> WikipediaPackage {
        let language=info.language.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let textOnly=info.tags.contains("_pictures:no") || info.flavour == "nopic" || info.flavour == "mini"
        let kind: PackageKind = textOnly ? .textOnly : info.flavour == "maxi" ? .full : .standard
        let title=info.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? file.deletingPathExtension().lastPathComponent : info.title
        let identity=info.uuid.isEmpty ? "\(file.lastPathComponent):\(size)" : info.uuid
        let version=String(info.date.prefix(10))
        return WikipediaPackage(id: "imported:"+identity, name: title, languageCode: language.isEmpty ? "und" : language, kind: kind,
                                summary: info.description.isEmpty ? "Imported from \(file.lastPathComponent)." : info.description,
                                version: version.isEmpty ? "imported" : version, downloadURL: file, downloadBytes: size,
                                format: .zim, source: source, family: "imported:"+(info.name.isEmpty ? title : info.name))
    }

    /// Copies a file in 8 MB pieces and returns the bytes copied. Progress is reported at most
    /// four times a second; cancellation stops the copy between pieces.
    public static func copy(from source: URL, to destination: URL, progress: @Sendable (Int64) -> Void = { _ in }) throws -> Int64 {
        let input=try FileHandle(forReadingFrom: source); defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw AtlasError.storageUnavailable }
        let output=try FileHandle(forWritingTo: destination); defer { try? output.close() }
        var copied: Int64=0, tick=Date.distantPast
        while let data=try input.read(upToCount: 8*1024*1024), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data); copied += Int64(data.count)
            if Date().timeIntervalSince(tick) > 0.25 { progress(copied); tick=Date() }
        }
        try output.synchronize()
        progress(copied)
        return copied
    }
}
