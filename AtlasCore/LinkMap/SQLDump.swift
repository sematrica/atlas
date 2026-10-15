import Foundation
import ZIMBridge

/// Reads a gzip file line by line. mysqldump writes each INSERT statement on one long line.
final class GzipLineReader {
    private let handle:AZGzip
    private var chunk=[UInt8](repeating:0,count:1<<20)
    private var carry:[UInt8]=[]
    let compressedSize:Int64

    init(_ url:URL) throws {
        guard let opened=az_gz_open(url.path) else {throw SQLDumpError.unreadable(url.lastPathComponent)}
        handle=opened
        compressedSize=Int64((try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
    }
    deinit {az_gz_close(handle)}

    /// How far through the compressed file reading has got, 0–1.
    var fraction:Double {
        let offset=az_gz_offset(handle)
        return compressedSize>0 && offset>=0 ? min(1,Double(offset)/Double(compressedSize)) : 0
    }

    /// Calls `line` with each line's bytes, without the newline. Returning false stops reading.
    func forEachLine(_ line:(UnsafeBufferPointer<UInt8>) throws -> Bool) throws {
        while true {
            let count=chunk.withUnsafeMutableBytes {az_gz_read(handle,$0.baseAddress,Int32($0.count))}
            if count<0 {throw SQLDumpError.corrupt}
            if count == 0 {
                if !carry.isEmpty {_ = try carry.withUnsafeBufferPointer {try line($0)};carry=[]}
                return
            }
            var keepGoing=true
            try chunk.withUnsafeBufferPointer {buffer in
                var start=0
                guard let base=buffer.baseAddress else {return}
                while start<Int(count) {
                    let found=memchr(base+start,0x0A,Int(count)-start)
                    let end=found.map {UnsafeRawPointer($0)-UnsafeRawPointer(base)} ?? Int(count)
                    if end == Int(count) {carry.append(contentsOf:buffer[start..<end]);break}
                    if carry.isEmpty {
                        keepGoing=try line(UnsafeBufferPointer(rebasing:buffer[start..<end]))
                    } else {
                        carry.append(contentsOf:buffer[start..<end])
                        keepGoing=try carry.withUnsafeBufferPointer {try line($0)}
                        carry.removeAll(keepingCapacity:true)
                    }
                    if !keepGoing {return}
                    start=end+1
                }
            }
            if !keepGoing {return}
        }
    }
}

public enum SQLDumpError:LocalizedError,Equatable {
    case unreadable(String), corrupt, missingTable(String), missingColumn(String,String)
    public var errorDescription:String? {
        switch self {
        case .unreadable(let name): "Sematrica couldn't open \(name)."
        case .corrupt: "A table dump is damaged. Verify it under Packages, or download it again."
        case .missingTable(let table): "The dump doesn't contain the \(table) table."
        case .missingColumn(let table,let column): "The \(table) table in this dump has no \(column) column, so Sematrica can't read it."
        }
    }
}

/// One value from a row of a table dump.
public enum SQLValue:Equatable,Sendable {
    case int(Int64), text([UInt8]), null, other
    public var int:Int64? {if case .int(let value)=self {return value};return nil}
    public var bytes:[UInt8]? {if case .text(let value)=self {return value};return nil}
    public var string:String? {bytes.map {String(decoding:$0,as:UTF8.self)}}
}

/// Reads mysqldump output, the format of Wikimedia's .sql.gz table dumps: a CREATE TABLE
/// statement naming the columns, then INSERT statements of rows. Only the wanted columns are
/// kept, so a billion-row table streams through without being held in memory.
public enum SQLDump {
    /// The columns of `table`, in order, from its CREATE TABLE statement.
    public static func columns(of url:URL,table:String) throws -> [String] {
        let reader=try GzipLineReader(url)
        var columns:[String]=[],inside=false,found=false
        let opening=Array("CREATE TABLE `\(table)`".utf8)
        try reader.forEachLine {line in
            if !inside {
                if line.starts(with:opening) {inside=true;found=true}
                return true
            }
            var i=0
            while i<line.count,line[i] == 0x20 || line[i] == 0x09 {i += 1}
            guard i<line.count else {return true}
            if line[i] == 0x29 {return false}  // ")" ends the column list
            guard line[i] == 0x60 else {return true}  // key definitions don't start with a backtick
            var j=i+1
            while j<line.count,line[j] != 0x60 {j += 1}
            columns.append(String(decoding:UnsafeBufferPointer(rebasing:line[(i+1)..<j]),as:UTF8.self))
            return true
        }
        guard found else {throw SQLDumpError.missingTable(table)}
        return columns
    }

    /// Reads every row of `table`, handing `row` the values of the wanted columns in the order asked.
    /// Columns in `optional` that the table lacks come through as `.null`; any other missing column throws.
    public static func read(_ url:URL,table:String,wanted:[String],optional:Set<String>=[],
                            progress:((Double) -> Void)?=nil,row:([SQLValue]) throws -> Void) throws {
        let columns=try Self.columns(of:url,table:table)
        var slot=[Int](repeating:-1,count:columns.count)
        for (position,name) in wanted.enumerated() {
            if let index=columns.firstIndex(of:name) {slot[index]=position}
            else if !optional.contains(name) {throw SQLDumpError.missingColumn(table,name)}
        }
        let reader=try GzipLineReader(url)
        let prefix=Array("INSERT INTO `\(table)` VALUES ".utf8)
        var values=[SQLValue](repeating:.null,count:wanted.count)
        var lines=0
        try reader.forEachLine {line in
            lines += 1
            if lines & 63 == 0 {
                try Task.checkCancellation()
                progress?(reader.fraction)
            }
            guard line.starts(with:prefix) else {return true}
            try parseRows(line,from:prefix.count,slots:slot,values:&values,row:row)
            return true
        }
        progress?(1)
    }

    /// Parses `(v,v,…),(v,v,…);` starting at `start`.
    static func parseRows(_ p:UnsafeBufferPointer<UInt8>,from start:Int,slots:[Int],values:inout [SQLValue],row:([SQLValue]) throws -> Void) throws {
        let n=p.count
        var i=start
        while i<n {
            while i<n,p[i] != 0x28 {  // "("
                if p[i] == 0x3B {return}  // ";"
                i += 1
            }
            guard i<n else {return}
            i += 1
            var column=0
            for k in values.indices {values[k] = .null}
            while true {
                guard i<n else {throw SQLDumpError.corrupt}
                let slot=column<slots.count ? slots[column] : -1
                var c=p[i]
                if c == 0x5F,i+8<n,p[i+1] == 0x62,p[i+7] == 0x20 {  // "_binary 'x'"
                    i += 8;c=p[i]
                }
                if c == 0x27 {  // a quoted string
                    i += 1
                    var bytes:[UInt8]=[]
                    let keep=slot>=0
                    while true {
                        guard i<n else {throw SQLDumpError.corrupt}
                        let b=p[i]
                        if b == 0x5C {  // backslash escape
                            guard i+1<n else {throw SQLDumpError.corrupt}
                            if keep {
                                switch p[i+1] {
                                case 0x30: bytes.append(0)
                                case 0x6E: bytes.append(0x0A)
                                case 0x72: bytes.append(0x0D)
                                case 0x74: bytes.append(0x09)
                                case 0x62: bytes.append(0x08)
                                case 0x5A: bytes.append(0x1A)
                                default: bytes.append(p[i+1])
                                }
                            }
                            i += 2
                        } else if b == 0x27 {
                            if i+1<n,p[i+1] == 0x27 {if keep {bytes.append(0x27)};i += 2}  // '' inside a string
                            else {i += 1;break}
                        } else {
                            if keep {bytes.append(b)}
                            i += 1
                        }
                    }
                    if keep {values[slot] = .text(bytes)}
                } else if c == 0x4E || c == 0x6E {  // NULL
                    i += 4
                } else if c == 0x30,i+1<n,p[i+1] == 0x78 || p[i+1] == 0x58 {  // 0x… hex
                    i += 2
                    var bytes:[UInt8]=[],high:UInt8?
                    while i<n,let digit=hexValue(p[i]) {
                        if let first=high {bytes.append(first<<4|digit);high=nil} else {high=digit}
                        i += 1
                    }
                    if slot>=0 {values[slot] = .text(bytes)}
                } else {
                    var negative=false,number:Int64=0,integral=true,digits=0
                    if c == 0x2D {negative=true;i += 1}
                    while i<n {
                        let d=p[i]
                        if d >= 0x30 && d <= 0x39 {number=number &* 10 &+ Int64(d-0x30);digits += 1;i += 1}
                        else if d == 0x2E || d == 0x65 || d == 0x45 || d == 0x2B || (d == 0x2D && digits>0) {integral=false;i += 1}
                        else {break}
                    }
                    if slot>=0 {values[slot]=integral && digits>0 ? .int(negative ? -number : number) : .other}
                }
                column += 1
                guard i<n else {throw SQLDumpError.corrupt}
                if p[i] == 0x2C {i += 1;continue}  // ","
                if p[i] == 0x29 {i += 1;break}  // ")"
                throw SQLDumpError.corrupt
            }
            try row(values)
        }
    }

    static func hexValue(_ b:UInt8)->UInt8? {
        switch b {
        case 0x30...0x39: b-0x30
        case 0x61...0x66: b-0x61+10
        case 0x41...0x46: b-0x41+10
        default: nil
        }
    }

    /// Writes a gzip file, for tests and fixtures.
    static func writeGzip(_ text:String,to url:URL) throws {
        guard let file=az_gz_create(url.path) else {throw SQLDumpError.unreadable(url.lastPathComponent)}
        defer {az_gz_close(file)}
        let bytes=Array(text.utf8)
        let written=bytes.withUnsafeBytes {az_gz_write(file,$0.baseAddress,Int32($0.count))}
        guard written == bytes.count else {throw SQLDumpError.corrupt}
    }
}
