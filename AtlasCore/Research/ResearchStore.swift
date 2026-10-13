import Foundation
import SQLite3

public struct ResearchIndexProgress:Codable,Sendable {
    public var cursor:UInt64=0
    public var total:UInt64=0
    public var articles=0
    public var skipped=0
    public var complete:Bool {total>0 && cursor>=total}
    public init() {}
}
public struct ResearchNote:Codable,Sendable,Identifiable {
    public var id:String
    public var claim:String
    public var quote:String
    public var source:RetrievedPassage
    public init(claim:String,quote:String,source:RetrievedPassage) {
        self.id=KnowledgeHash.of(claim+source.id+quote);self.claim=claim;self.quote=quote;self.source=source
    }
}
public struct ResearchRun:Codable,Sendable,Identifiable {
    public var id=UUID().uuidString
    public var parentID:String?
    public var question:String
    public var model:String
    public var exhaustive:Bool
    public var subquestions:[String]=[]
    public var pendingQueries:[String]=[]
    public var searched:[String]=[]
    public var queue:[ArticleID]=[]
    public var readCount=0
    public var failedCount=0
    public var passagesExamined=0
    public var noteCount=0
    public var gaps:[String]=[]
    public var report=""
    public var reportSources:[ResearchNote]=[]
    public var status="Ready"
    public var currentArticle=""
    public var archiveCursor:UInt64=0
    public var archiveTotal:UInt64=0
    public var archiveFinished=false
    public var searchScope=""
    public var updated=Date()
    public init(question:String,model:String,exhaustive:Bool=false) {self.question=question;self.model=model;self.exhaustive=exhaustive}
}

/// Serialized SQLite access, on-disk full-text index, atomic job checkpoints and append-only evidence.
public actor ResearchStore {
    private let access:LibraryAccess
    private var db:OpaquePointer?
    public let packageID:String
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    public init(access:LibraryAccess,record:PackageRecord) throws {
        self.access=access;packageID=record.id
        try access.validate()
        let fingerprint=KnowledgeHash.of(record.id+record.package.version+(record.package.checksum?.value ?? "")+String(record.receivedBytes)+"research-v1")
        let directory=try access.file("indexes/research-"+fingerprint)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=try access.file("indexes/research-"+fingerprint+"/research.sqlite")
        var pointer:OpaquePointer?
        guard sqlite3_open(file.path,&pointer) == SQLITE_OK else {sqlite3_close(pointer);throw AIError.message("Cannot open the research database.")}
        db=pointer
        let sql="""
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=5000;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS indexed(path TEXT PRIMARY KEY);
        CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(path UNINDEXED,payload UNINDEXED,title,body);
        CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,updated REAL,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS visits(job TEXT,path TEXT,status TEXT,PRIMARY KEY(job,path));
        CREATE TABLE IF NOT EXISTS notes(job TEXT,id TEXT,payload TEXT,PRIMARY KEY(job,id));
        CREATE VIRTUAL TABLE IF NOT EXISTS note_search USING fts5(job UNINDEXED,id UNINDEXED,claim,body);
        CREATE TRIGGER IF NOT EXISTS note_insert AFTER INSERT ON notes BEGIN
          INSERT INTO note_search(job,id,claim,body) VALUES(new.job,new.id,json_extract(new.payload,'$.claim'),json_extract(new.payload,'$.quote'));
        END;
        INSERT INTO note_search(job,id,claim,body) SELECT job,id,json_extract(payload,'$.claim'),json_extract(payload,'$.quote') FROM notes n WHERE NOT EXISTS(SELECT 1 FROM note_search s WHERE s.job=n.job AND s.id=n.id);

        """
        guard sqlite3_exec(pointer,sql,nil,nil,nil) == SQLITE_OK else {sqlite3_close(pointer);db=nil;throw AIError.message("SQLite full-text search could not be initialized.")}
    }
    deinit {sqlite3_close(db)}
    private func query(_ sql:String,_ bindings:[String]=[]) throws -> [[String]] {
        try access.validate()
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK else {throw AIError.message("Research database: "+String(cString:sqlite3_errmsg(db)))}
        defer {sqlite3_finalize(statement)}
        for (i,text) in bindings.enumerated() {sqlite3_bind_text(statement,Int32(i+1),text,-1,transient)}
        var rows:[[String]]=[]
        while true {
            let result=sqlite3_step(statement)
            if result == SQLITE_DONE {return rows}
            guard result == SQLITE_ROW else {throw AIError.message("Research database: "+String(cString:sqlite3_errmsg(db)))}
            rows.append((0..<sqlite3_column_count(statement)).map {sqlite3_column_text(statement,$0).map {String(cString:$0)} ?? ""})
        }
    }
    private func json<T:Encodable>(_ value:T) throws -> String {String(decoding:try JSONEncoder().encode(value),as:UTF8.self)}
    public func progress() throws -> ResearchIndexProgress {
        guard let text=try query("SELECT value FROM meta WHERE key='index'").first?.first else {return .init()}
        return try JSONDecoder().decode(ResearchIndexProgress.self,from:Data(text.utf8))
    }
    public func indexAll(provider:any ResearchArticleProvider) async throws {
        var progress=try progress()
        while !progress.complete {
            try Task.checkCancellation()
            let batch=try await provider.articleBatch(offset:progress.cursor)
            guard batch.next>progress.cursor || batch.next == batch.totalEntries else {throw AIError.message("Archive enumeration did not advance.")}
            progress.total=batch.totalEntries
            for id in batch.articles {
                try Task.checkCancellation()
                if try !query("SELECT path FROM indexed WHERE path=?",[id.path]).isEmpty {continue}
                let article:Article
                do {article=try await provider.article(for:id)}
                catch is CancellationError {throw CancellationError()}
                catch {try access.validate();progress.skipped += 1;continue}
                let chunks=TextExtractor.chunks(article)
                try Task.checkCancellation()
                _ = try query("BEGIN IMMEDIATE")
                do {
                    if try query("SELECT path FROM indexed WHERE path=?",[article.id.path]).isEmpty {
                        for chunk in chunks {_ = try query("INSERT INTO passages(path,payload,title,body) VALUES(?,?,?,?)",[article.id.path,try json(chunk),article.title,chunk.text])}
                        _ = try query("INSERT INTO indexed(path) VALUES(?)",[article.id.path])
                    }
                    _ = try query("COMMIT")
                } catch {_ = try? query("ROLLBACK");throw error}
            }
            progress.cursor=batch.next
            progress.articles=Int(try query("SELECT count(*) FROM indexed").first?.first ?? "0") ?? 0
            _ = try query("INSERT OR REPLACE INTO meta(key,value) VALUES('index',?)",[try json(progress)])
            if batch.totalEntries == 0 {break}
        }
    }
    public func search(_ text:String,limit:Int=20) throws -> [RetrievedPassage] {
        let terms=text.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).filter {$0.count>1}.prefix(16)
        guard !terms.isEmpty else {return []}
        let expression=terms.map {"\""+$0+"\""}.joined(separator:" OR ")
        return try query("SELECT payload FROM passages WHERE passages MATCH ? ORDER BY bm25(passages) LIMIT ?",[expression,String(min(100,max(1,limit)))]).map {try JSONDecoder().decode(RetrievedPassage.self,from:Data($0[0].utf8))}
    }
    public func save(_ run:ResearchRun) throws {_ = try query("INSERT OR REPLACE INTO jobs(id,updated,payload) VALUES(?,?,?)",[run.id,String(Date().timeIntervalSince1970),try json(run)])}
    public func recentRuns() throws -> [ResearchRun] {try query("SELECT payload FROM jobs ORDER BY updated DESC LIMIT 30").map {try JSONDecoder().decode(ResearchRun.self,from:Data($0[0].utf8))}}
    public func visited(job:String,path:String) throws -> Bool {try !query("SELECT path FROM visits WHERE job=? AND path=?",[job,path]).isEmpty}
    public func notes(job:String,limit:Int=100) throws -> [ResearchNote] {try query("SELECT payload FROM notes WHERE job=? ORDER BY rowid DESC LIMIT ?",[job,String(min(1000,max(1,limit)))]).map {try JSONDecoder().decode(ResearchNote.self,from:Data($0[0].utf8))}}
    public func relevantNotes(job:String,question:String,limit:Int=24) throws -> [ResearchNote] {
        let words=question.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).filter {$0.count>3}.prefix(20)
        var candidates:[ResearchNote]=[]
        if !words.isEmpty {
            let expression=words.map {"\""+$0+"\""}.joined(separator:" OR ")
            candidates=try query("SELECT notes.payload FROM note_search JOIN notes ON notes.job=note_search.job AND notes.id=note_search.id WHERE note_search MATCH ? AND note_search.job=? ORDER BY bm25(note_search) LIMIT 200",[expression,job]).map {try JSONDecoder().decode(ResearchNote.self,from:Data($0[0].utf8))}
        }
        candidates += try notes(job:job,limit:100)
        var ids:Set<String>=[],perArticle:[String:Int]=[:],selected:[ResearchNote]=[]
        for note in candidates where ids.insert(note.id).inserted {
            let path=note.source.article.path
            guard perArticle[path,default:0]<3 else {continue}
            perArticle[path,default:0] += 1;selected.append(note)
            if selected.count>=limit {break}
        }
        return selected
    }
    public func fork(_ previous:ResearchRun,question:String,model:String) throws -> ResearchRun {
        var next=ResearchRun(question:question,model:model,exhaustive:previous.exhaustive);next.parentID=previous.id
        _ = try query("BEGIN IMMEDIATE")
        do {
            _ = try query("INSERT INTO notes(job,id,payload) SELECT ?,id,payload FROM notes WHERE job=?",[next.id,previous.id])
            next.noteCount=Int(try query("SELECT count(*) FROM notes WHERE job=?",[next.id]).first?.first ?? "0") ?? 0
            try save(next);_ = try query("COMMIT");return next
        } catch {_ = try? query("ROLLBACK");throw error}
    }
    public func commitArticle(run initial:ResearchRun,id:ArticleID,notes:[ResearchNote],failed:Bool=false) throws -> ResearchRun {
        var run=initial
        _ = try query("BEGIN IMMEDIATE")
        do {
            _ = try query("INSERT OR IGNORE INTO visits(job,path,status) VALUES(?,?,?)",[run.id,id.path,failed ? "failed" : "read"])
            for note in notes {_ = try query("INSERT OR IGNORE INTO notes(job,id,payload) VALUES(?,?,?)",[run.id,note.id,try json(note)])}
            if failed {run.failedCount += 1}else {run.readCount += 1}
            run.noteCount=Int(try query("SELECT count(*) FROM notes WHERE job=?",[run.id]).first?.first ?? "0") ?? 0
            run.queue.removeAll {$0 == id};try save(run)
            _ = try query("COMMIT");return run
        } catch {_ = try? query("ROLLBACK");throw error}
    }
}
