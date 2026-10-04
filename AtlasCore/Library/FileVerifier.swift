import Foundation
import CryptoKit

public enum FileVerifier {
    public static func verify(url: URL, size: Int64, checksum: PackageChecksum?, progress: @Sendable (Double) -> Void = {_ in}) throws {
        let file=try FileHandle(forReadingFrom:url); defer { try? file.close() }
        guard try file.seekToEnd() == UInt64(size) else { throw AtlasError.incompleteDownload }
        try file.seek(toOffset:0)
        var sha256=SHA256(),sha1=Insecure.SHA1(),md5=Insecure.MD5()
        var count: Int64=0; var tick=Date.distantPast
        while let data=try file.read(upToCount:1024*1024),!data.isEmpty {
            try Task.checkCancellation(); count += Int64(data.count)
            switch checksum?.algorithm {
            case .sha256: sha256.update(data:data)
            case .sha1: sha1.update(data:data)
            case .md5: md5.update(data:data)
            case nil: break
            }
            if Date().timeIntervalSince(tick) > 0.5 { progress(Double(count)/Double(max(size,1))); tick=Date() }
        }
        guard count == size else { throw AtlasError.incompleteDownload }
        if let checksum {
            let actual: String
            switch checksum.algorithm {
            case .sha256: actual=sha256.finalize().map {String(format:"%02x",$0)}.joined()
            case .sha1: actual=sha1.finalize().map {String(format:"%02x",$0)}.joined()
            case .md5: actual=md5.finalize().map {String(format:"%02x",$0)}.joined()
            }
            guard actual == checksum.value.lowercased() else { throw AtlasError.checksumMismatch }
        }
        progress(1)
    }
}
