import XCTest
@testable import AtlasCore

/// Writes Wikimedia-style mysqldump tables (gzip-compressed) for tests.
struct DumpFixture {
    let folder:URL
    init() throws {
        folder=FileManager.default.temporaryDirectory.appendingPathComponent("dump-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    }
    func remove() {try? FileManager.default.removeItem(at:folder)}

    /// A dump of `table` in mysqldump's layout, with rows split across INSERT lines.
    @discardableResult
    func table(_ table:String,columns:[String],rows:[[Any?]],file:String,perLine:Int=3) throws -> URL {
        func literal(_ value:Any?)->String {
            switch value {
            case nil: return "NULL"
            case let number as Int: return String(number)
            case let text as String:
                var escaped=""
                for character in text {
                    switch character {
                    case "'": escaped += "\\'"
                    case "\\": escaped += "\\\\"
                    case "\n": escaped += "\\n"
                    default: escaped.append(character)
                    }
                }
                return "'"+escaped+"'"
            default: return "\(value!)"
            }
        }
        var text="""
        -- MySQL dump 10.19  Distrib 10.3.38-MariaDB, for debian-linux-gnu (x86_64)
        --
        -- Host: db    Database: testwiki
        /*!40101 SET NAMES binary*/;
        DROP TABLE IF EXISTS `\(table)`;
        CREATE TABLE `\(table)` (

        """
        text += columns.map {"  `\($0)` varbinary(255) NOT NULL DEFAULT '',"}.joined(separator:"\n")
        text += "\n  PRIMARY KEY (`\(columns[0])`),\n  KEY `\(table)_index` (`\(columns.last!)`)\n) ENGINE=InnoDB DEFAULT CHARSET=binary ROW_FORMAT=COMPRESSED;\n"
        text += "/*!40000 ALTER TABLE `\(table)` DISABLE KEYS */;\n"
        var index=0
        while index<rows.count {
            let line=rows[index..<min(rows.count,index+perLine)].map {"("+$0.map(literal).joined(separator:",")+")"}.joined(separator:",")
            text += "INSERT INTO `\(table)` VALUES \(line);\n"
            index += perLine
        }
        text += "/*!40000 ALTER TABLE `\(table)` ENABLE KEYS */;\n"
        let url=folder.appendingPathComponent(file)
        try SQLDump.writeGzip(text,to:url)
        return url
    }
}

final class SQLDumpTests:XCTestCase {
    func testReadsColumnsAndRows() throws {
        let fixture=try DumpFixture();defer {fixture.remove()}
        let url=try fixture.table("page",columns:["page_id","page_namespace","page_title","page_is_redirect","page_len"],rows:[
            [1,0,"Ray_Charles",0,500],
            [2,0,"Rock_'n'_roll",0,-7],
            [3,14,"Jazz_musicians",0,nil],
            [4,0,"Café_Wha?",1,10],
            [5,0,"Back\\slash",0,1],
            [6,0,"Line\nbreak",0,2],
            [7,0,"",0,3]
        ],file:"testwiki-20261001-page.sql.gz")
        XCTAssertEqual(try SQLDump.columns(of:url,table:"page"),["page_id","page_namespace","page_title","page_is_redirect","page_len"])
        var rows:[[SQLValue]]=[]
        try SQLDump.read(url,table:"page",wanted:["page_title","page_id","page_len"]) {rows.append($0)}
        XCTAssertEqual(rows.count,7)
        XCTAssertEqual(rows[0],[.text(Array("Ray_Charles".utf8)),.int(1),.int(500)])
        XCTAssertEqual(rows[1][0].string,"Rock_'n'_roll")
        XCTAssertEqual(rows[1][2],.int(-7))
        XCTAssertEqual(rows[2][2],.null)
        XCTAssertEqual(rows[3][0].string,"Café_Wha?")
        XCTAssertEqual(rows[4][0].string,"Back\\slash")
        XCTAssertEqual(rows[5][0].string,"Line\nbreak")
        XCTAssertEqual(rows[6][0].string,"")
        XCTAssertThrowsError(try SQLDump.read(url,table:"page",wanted:["page_touched"]) {_ in}) {
            XCTAssertEqual($0 as? SQLDumpError,.missingColumn("page","page_touched"))
        }
        var nulls:[SQLValue]=[]
        try SQLDump.read(url,table:"page",wanted:["page_touched"],optional:["page_touched"]) {nulls.append($0[0])}
        XCTAssertEqual(Set(nulls.map {"\($0)"}),["null"],"a missing optional column reads as NULL")
        XCTAssertThrowsError(try SQLDump.columns(of:url,table:"pagelinks")) {XCTAssertEqual($0 as? SQLDumpError,.missingTable("pagelinks"))}
    }

    func testHexAndBinaryLiterals() throws {
        var values=[SQLValue](repeating:.null,count:2)
        var rows:[[SQLValue]]=[]
        let line=Array("INSERT INTO `t` VALUES (0x4A617A7A,_binary 'x\\'y'),(12.5,NULL);".utf8)
        try line.withUnsafeBufferPointer {
            try SQLDump.parseRows($0,from:"INSERT INTO `t` VALUES ".utf8.count,slots:[0,1],values:&values) {rows.append($0)}
        }
        XCTAssertEqual(rows,[[.text(Array("Jazz".utf8)),.text(Array("x'y".utf8))],[.other,.null]])
    }
}

/// A small wiki written out as Wikimedia table dumps, in the old layout (links name their target
/// titles) or the 2024 one (links point into a linktarget table).
struct TestWiki {
    static let pages:[[Any?]]=[
        [1,0,"Ray_Charles",0],[2,0,"Atlantic_Records",0],[3,0,"New_York_City",0],[4,0,"Paris",0],
        [5,0,"French_capital",1],[6,0,"Jazz",0],[7,0,"Georgia_(U.S._state)",0],[8,14,"Jazz_musicians",0],
        [9,0,"Rock_'n'_roll",0],[10,1,"Ray_Charles",0],[11,0,"Isolated",0],[12,0,"Double_redirect",1]
    ]
    static let redirects:[[Any?]]=[[5,0,"Paris","",""],[12,0,"French_capital","",""]]
    /// (from page, target namespace, target title, from namespace)
    static let links:[(Int,Int,String,Int)]=[
        (1,0,"Atlantic_Records",0),(1,0,"Georgia_(U.S._state)",0),(1,0,"Jazz",0),(2,0,"New_York_City",0),
        (3,0,"French_capital",0),(6,0,"Rock_'n'_roll",0),(9,0,"Ray_Charles",0),
        (1,0,"Missing_article",0),(10,0,"Paris",1),(5,0,"Paris",0),(1,1,"Ray_Charles",0),(1,0,"Ray_Charles",0)
    ]
    /// (from page, category, type)
    static let categories:[(Int,String,String)]=[(1,"Jazz_musicians","page"),(6,"Jazz_musicians","page"),(1,"Articles_with_short_description","page"),(8,"Musicians","subcat")]
    /// (from page, language, title there). The redirect's and the talk page's are left out.
    static let languages:[(Int,String,String)]=[(1,"fr","Ray Charles"),(1,"de","Ray Charles"),(4,"fr","Paris"),(4,"ja","パリ"),(5,"fr","Paris"),(10,"fr","Discussion:Ray Charles"),(6,"zh-yue","爵士樂")]

    static func sources(_ fixture:DumpFixture,modern:Bool,categories:Bool=true,linktarget:Bool=true,languages:Bool=true) throws -> LinkMapSources {
        let page=try fixture.table("page",columns:["page_id","page_namespace","page_title","page_is_redirect","page_is_new","page_random","page_len"],
                                   rows:pages.map {$0+[0,0.25,100]},file:"testwiki-20261001-page.sql.gz")
        let redirect=try fixture.table("redirect",columns:["rd_from","rd_namespace","rd_title","rd_interwiki","rd_fragment"],rows:redirects,file:"testwiki-20261001-redirect.sql.gz")
        var targets:[String:Int]=[:]
        func target(_ namespace:Int,_ title:String)->Int {
            let key="\(namespace):\(title)"
            if let id=targets[key] {return id}
            targets[key]=100+targets.count
            return targets[key]!
        }
        let pagelinks:URL,categorylinks:URL?
        if modern {
            pagelinks=try fixture.table("pagelinks",columns:["pl_from","pl_from_namespace","pl_target_id"],
                                        rows:links.map {[$0.0,$0.3,target($0.1,$0.2)]},file:"testwiki-20261001-pagelinks.sql.gz")
            categorylinks=categories ? try fixture.table("categorylinks",columns:["cl_from","cl_sortkey","cl_timestamp","cl_sortkey_prefix","cl_type","cl_collation_id","cl_target_id"],
                                                         rows:Self.categories.map {[$0.0,"KEY","2026-01-01 00:00:00","",$0.2,1,target(14,$0.1)]},file:"testwiki-20261001-categorylinks.sql.gz") : nil
        } else {
            pagelinks=try fixture.table("pagelinks",columns:["pl_from","pl_namespace","pl_title","pl_from_namespace"],
                                        rows:links.map {[$0.0,$0.1,$0.2,$0.3]},file:"testwiki-20261001-pagelinks.sql.gz")
            categorylinks=categories ? try fixture.table("categorylinks",columns:["cl_from","cl_to","cl_sortkey","cl_timestamp","cl_sortkey_prefix","cl_collation","cl_type"],
                                                         rows:Self.categories.map {[$0.0,$0.1,"KEY","2026-01-01 00:00:00","","uca-default-u-kn",$0.2]},file:"testwiki-20261001-categorylinks.sql.gz") : nil
        }
        var linktargetURL:URL?
        if modern && linktarget {
            let rows=targets.sorted {$0.value<$1.value}.map {entry -> [Any?] in
                let parts=entry.key.split(separator:":",maxSplits:1)
                return [entry.value,Int(parts[0])!,String(parts[1])]
            }
            linktargetURL=try fixture.table("linktarget",columns:["lt_id","lt_namespace","lt_title"],rows:rows,file:"testwiki-20261001-linktarget.sql.gz")
        }
        let langlinks=languages ? try fixture.table("langlinks",columns:["ll_from","ll_lang","ll_title"],rows:Self.languages.map {[$0.0,$0.1,$0.2]},file:"testwiki-20261001-langlinks.sql.gz") : nil
        return LinkMapSources(project:"testwiki",date:"20261001",page:page,redirect:redirect,pagelinks:pagelinks,linktarget:linktargetURL,categorylinks:categorylinks,langlinks:langlinks)
    }
}

final class LinkMapTests:XCTestCase {
    func build(modern:Bool,chunk:Int?=nil) throws -> (LinkMap,DumpFixture) {
        let fixture=try DumpFixture()
        let sources=try TestWiki.sources(fixture,modern:modern)
        let saved=LinkMapBuilder.chunkEdges
        if let chunk {LinkMapBuilder.chunkEdges=chunk}
        defer {LinkMapBuilder.chunkEdges=saved}
        let directory=fixture.folder.appendingPathComponent("linkmap-testwiki-20261001")
        let manifest=try LinkMapBuilder.build(sources,into:directory)
        XCTAssertEqual(manifest.articles,8)
        XCTAssertEqual(manifest.links,7,"red links, links from other namespaces or redirects, links to other namespaces and self-links are left out")
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path+".building"))
        return (try LinkMap(directory:directory),fixture)
    }

    func check(_ map:LinkMap) {
        func node(_ title:String)->Int32 {map.node(title) ?? -1}
        XCTAssertEqual(map.title(node("Ray Charles")),"Ray_Charles")
        XCTAssertEqual(node("French capital"),node("Paris"),"a redirect means its article")
        XCTAssertEqual(node("A/Paris"),node("Paris"),"ZIM paths work too")
        XCTAssertEqual(node("paris"),node("Paris"),"the first letter is capitalized, as MediaWiki does")
        XCTAssertEqual(map.title(node("Rock 'n' roll")),"Rock_'n'_roll")
        XCTAssertNil(map.node("Double redirect"),"a redirect to a redirect isn't followed")
        XCTAssertNil(map.node("Missing article"))
        XCTAssertNil(map.node("Jazz musicians"),"categories aren't articles")
        XCTAssertEqual(Set(map.links(from:node("Ray Charles")).map(map.title)),["Atlantic_Records","Georgia_(U.S._state)","Jazz"])
        XCTAssertEqual(map.links(to:node("Paris")).map(map.title),["New_York_City"],"the link to French capital counts for Paris")
        XCTAssertEqual(map.shortestPath(from:node("Ray Charles"),to:node("Paris"))?.map(map.title),["Ray_Charles","Atlantic_Records","New_York_City","Paris"])
        XCTAssertEqual(map.shortestPath(from:node("Rock 'n' roll"),to:node("Jazz"))?.map(map.title),["Rock_'n'_roll","Ray_Charles","Jazz"])
        let cut=UInt64(UInt32(node("Atlantic Records")))<<32|UInt64(UInt32(node("New York City")))
        XCTAssertNil(map.shortestPath(from:node("Ray Charles"),to:node("Paris"),avoidingEdges:[cut]))
        XCTAssertNil(map.shortestPath(from:node("Ray Charles"),to:node("Paris"),avoidingNodes:[node("New York City")]))
        XCTAssertNil(map.shortestPath(from:node("Ray Charles"),to:node("Isolated")))
        XCTAssertNil(map.shortestPath(from:node("Ray Charles"),to:node("Paris"),maxLinks:2),"three links are needed")
        XCTAssertEqual(map.shortestPath(from:node("Paris"),to:node("Paris")),[node("Paris")])
        // Categories.
        let jazzMusicians=map.category("Category:Jazz musicians")
        XCTAssertNotNil(jazzMusicians)
        XCTAssertEqual(Set(map.members(jazzMusicians ?? -1).map(map.title)),["Ray_Charles","Jazz"])
        XCTAssertEqual(Set(map.categories(of:node("Ray Charles")).map(map.categoryName)),["Jazz_musicians","Articles_with_short_description"])
        // Subcategories: Jazz musicians is filed in Musicians, which has no articles of its own.
        let musicians=map.category("Musicians")
        XCTAssertNotNil(musicians,"a category with only subcategories can be looked up too")
        XCTAssertEqual(map.members(musicians ?? -1),[],"subcategory entries aren't article memberships")
        XCTAssertEqual(map.subcategories(musicians ?? -1).map(map.categoryName),["Jazz_musicians"])
        XCTAssertEqual(map.parentCategories(jazzMusicians ?? -1).map(map.categoryName),["Musicians"])
        XCTAssertEqual(Set(map.members(of:map.categoryTree(musicians ?? -1)).map(map.title)),["Ray_Charles","Jazz"])
        XCTAssertEqual(map.manifest.subcategoryLinks,1)
        // Other languages.
        XCTAssertEqual(map.languages(of:node("Ray Charles")).map(\.language),["fr","de"])
        XCTAssertEqual(map.languages(of:node("Paris")).map(\.title),["Paris","パリ"])
        XCTAssertEqual(map.languageLinks(of:node("Jazz")),[LanguageLink(language:"zh-yue",title:"爵士樂")])
        XCTAssertEqual(map.languages(of:node("Atlantic Records")).count,0)
        XCTAssertEqual(map.manifest.languageLinks,5)
        XCTAssertEqual(map.manifest.languages,4)
        XCTAssertTrue(LinkMap.isMaintenance("Articles_with_short_description"))
        XCTAssertFalse(LinkMap.isMaintenance("Jazz_musicians"))
    }

    func testBuildsFromTheOlderDumpLayout() throws {
        let (map,fixture)=try build(modern:false);defer {fixture.remove()}
        check(map)
    }

    func testBuildsFromThe2024DumpLayout() throws {
        let (map,fixture)=try build(modern:true);defer {fixture.remove()}
        check(map)
        XCTAssertEqual(map.manifest.project,"testwiki")
        XCTAssertEqual(map.manifest.readableDate,"2026-10-01")
    }

    func testListsAreFilledInSeveralPassesWhenLarge() throws {
        let (map,fixture)=try build(modern:true,chunk:2);defer {fixture.remove()}
        check(map)
    }

    func testNeedsTheLinkTargetTableFor2024Dumps() throws {
        let fixture=try DumpFixture();defer {fixture.remove()}
        let sources=try TestWiki.sources(fixture,modern:true,linktarget:false)
        XCTAssertThrowsError(try LinkMapBuilder.build(sources,into:fixture.folder.appendingPathComponent("map"))) {
            XCTAssertEqual($0 as? LinkMapError,.needsLinkTargets)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.folder.appendingPathComponent("map.building").path),"a failed build leaves nothing behind")
    }

    /// The two-sided search finds chains exactly as long as a plain breadth-first search does.
    func testShortestPathsMatchABreadthFirstSearch() throws {
        let fixture=try DumpFixture();defer {fixture.remove()}
        struct Seeded:RandomNumberGenerator {var state:UInt64;mutating func next()->UInt64 {state=state &* 6364136223846793005 &+ 1442695040888963407;return state>>11}}
        var random=Seeded(state:7)
        let count=400
        var edges:[[Int]]=Array(repeating:[],count:count)
        var rows:[[Any?]]=[]
        for from in 0..<count {
            for _ in 0..<Int.random(in:0...3,using:&random) {
                let to=Int.random(in:0..<count,using:&random)
                if to != from,!edges[from].contains(to) {edges[from].append(to);rows.append([from+1,0,"A\(to)",0])}
            }
        }
        let page=try fixture.table("page",columns:["page_id","page_namespace","page_title","page_is_redirect"],rows:(0..<count).map {[$0+1,0,"A\($0)",0]},file:"p.sql.gz",perLine:50)
        let redirect=try fixture.table("redirect",columns:["rd_from","rd_namespace","rd_title","rd_interwiki"],rows:[],file:"r.sql.gz")
        let pagelinks=try fixture.table("pagelinks",columns:["pl_from","pl_namespace","pl_title","pl_from_namespace"],rows:rows,file:"l.sql.gz",perLine:50)
        let directory=fixture.folder.appendingPathComponent("map")
        _ = try LinkMapBuilder.build(LinkMapSources(project:"randomwiki",date:"20261001",page:page,redirect:redirect,pagelinks:pagelinks),into:directory)
        let map=try LinkMap(directory:directory)
        func bfs(_ start:Int,_ target:Int)->Int? {
            var distance=[Int](repeating:-1,count:count);distance[start]=0
            var queue=[start],head=0
            while head<queue.count {
                let u=queue[head];head += 1
                if u == target {return distance[u]}
                for v in edges[u] where distance[v]<0 {distance[v]=distance[u]+1;queue.append(v)}
            }
            return nil
        }
        var checked=0
        for _ in 0..<300 {
            let a=Int.random(in:0..<count,using:&random),b=Int.random(in:0..<count,using:&random)
            let expected=bfs(a,b)
            let path=map.shortestPath(from:map.node("A\(a)")!,to:map.node("A\(b)")!,maxLinks:40)
            XCTAssertEqual(path.map {$0.count-1},expected,"A\(a) → A\(b)")
            if let path {
                for (u,v) in zip(path,path.dropFirst()) {XCTAssertTrue(edges[Int(map.title(u).dropFirst())!].contains(Int(map.title(v).dropFirst())!),"every step is a real link")}
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked,100)
    }
}

extension DumpFixture {
    /// A link map built from articles and the articles each links to (the older dump layout).
    /// - Parameters:
    ///   - categories: category → the articles directly in it.
    ///   - subcategories: category → the categories directly inside it.
    ///   - languages: article → its (language, title) elsewhere.
    func linkMap(_ links:[String:[String]],redirects:[String:String]=[:],categories:[String:[String]]=[:],subcategories:[String:[String]]=[:],
                 languages:[String:[(String,String)]]=[:],project:String="enwiki") throws -> LinkMap {
        let titles=Array(Set(links.keys).union(links.values.joined()).union(redirects.values).union(categories.values.joined()).subtracting(redirects.keys)).sorted()+redirects.keys.sorted()
        var ids:[String:Int]=[:]
        for (index,title) in titles.enumerated() {ids[title]=index+1}
        // Category pages (namespace 14) for every category named.
        let categoryTitles=Array(Set(categories.keys).union(subcategories.keys).union(subcategories.values.joined())).sorted()
        var categoryIDs:[String:Int]=[:]
        for (index,name) in categoryTitles.enumerated() {categoryIDs[name]=titles.count+index+1}
        let page=try table("page",columns:["page_id","page_namespace","page_title","page_is_redirect"],
                           rows:titles.map {[ids[$0]!,0,$0,redirects[$0] == nil ? 0 : 1]}+categoryTitles.map {[categoryIDs[$0]!,14,$0,0]},
                           file:"\(project)-20261001-page.sql.gz")
        let redirect=try table("redirect",columns:["rd_from","rd_namespace","rd_title","rd_interwiki"],
                               rows:redirects.sorted {$0.key<$1.key}.map {[ids[$0.key]!,0,$0.value,""]},file:"\(project)-20261001-redirect.sql.gz")
        let pagelinks=try table("pagelinks",columns:["pl_from","pl_namespace","pl_title","pl_from_namespace"],
                                rows:links.sorted {$0.key<$1.key}.flatMap {entry in entry.value.map {title -> [Any?] in [ids[entry.key]!,0,title,0]}},file:"\(project)-20261001-pagelinks.sql.gz")
        let memberships:[[Any?]]=categories.sorted {$0.key<$1.key}.flatMap {entry in entry.value.map {title -> [Any?] in [ids[title]!,entry.key,"page"]}}
        let nesting:[[Any?]]=subcategories.sorted {$0.key<$1.key}.flatMap {entry in entry.value.map {child -> [Any?] in [categoryIDs[child]!,entry.key,"subcat"]}}
        let categorylinks=memberships.isEmpty && nesting.isEmpty ? nil : try table("categorylinks",columns:["cl_from","cl_to","cl_type"],rows:memberships+nesting,
                                                                                    file:"\(project)-20261001-categorylinks.sql.gz")
        let languageRows:[[Any?]]=languages.sorted {$0.key<$1.key}.flatMap {entry in entry.value.map {link -> [Any?] in [ids[entry.key]!,link.0,link.1]}}
        let langlinks=languageRows.isEmpty ? nil : try table("langlinks",columns:["ll_from","ll_lang","ll_title"],rows:languageRows,file:"\(project)-20261001-langlinks.sql.gz")
        let directory=folder.appendingPathComponent(LinkMapLibrary.directoryName(project:project,date:"20261001"))
        _ = try LinkMapBuilder.build(.init(project:project,date:"20261001",page:page,redirect:redirect,pagelinks:pagelinks,linktarget:nil,
                                           categorylinks:categorylinks,langlinks:langlinks),into:directory)
        return try LinkMap(directory:directory)
    }
}

final class LinkMapAnswerTests:XCTestCase {
    var fixture:DumpFixture!
    override func setUpWithError() throws {fixture=try DumpFixture()}
    override func tearDown() {fixture.remove()}

    func map() throws -> LinkMap {
        try fixture.linkMap(["Ray_Charles":["Paris","Jazz"],"Louvre":["Paris"],"Lyon":["French_capital","Paris"],"Jazz":["Paris","Ray_Charles"],"Missing_article":["Paris"]],
                            redirects:["French_capital":"Paris"],
                            categories:["Jazz_pianists":["Ray_Charles"],"Musicians":["Ray_Charles","Jazz"],"Articles_with_short_description":["Ray_Charles"]])
    }

    func testWhatLinksHere() async throws {
        let map=try map()
        let paris=try XCTUnwrap(map.node("Paris"))
        XCTAssertEqual(map.backlinksByPopularity(paris).map(map.title),["Jazz","Ray_Charles","Louvre","Lyon","Missing_article"],"each article once, most linked-to first")
        XCTAssertEqual(map.linksHereAnswer(paris,list:false),"5 articles link to “Paris”, according to Wikipedia's link map (2026-10-01).")
        XCTAssertTrue(map.linksHereAnswer(paris,list:true).hasSuffix("Most linked-to first: Jazz, Ray Charles, Louvre, Lyon, Missing article."))
        XCTAssertEqual(map.linksHereAnswer(try XCTUnwrap(map.node("Louvre")),list:true),"No article links to “Louvre”, according to Wikipedia's link map (2026-10-01).")

        // The list holds only the articles this package has, at its own paths.
        let library=FakeLibrary(["Ray_Charles":("Ray Charles",""),"Jazz":("Jazz",""),"Louvre":("Louvre",""),"Lyon":("Lyon","")])
        let hits=try await map.hits(map.backlinksByPopularity(paris),in:library)
        XCTAssertEqual(hits.map(\.title),["Jazz","Ray Charles","Louvre","Lyon"])
        let older=FakeLibrary(["A/Ray_Charles":("Ray Charles",""),"A/Jazz":("Jazz","")])
        let prefixed=try await map.hits(map.backlinksByPopularity(paris),in:older,limit:1)
        XCTAssertEqual(prefixed.map(\.path),["A/Jazz"],"older ZIM files put articles under A/")
        let lowercase=try await map.node(named:"ray charles",source:library)
        XCTAssertEqual(lowercase,map.node("Ray_Charles"),"a name the map doesn't spell that way is found through the package's titles")
    }

    func testCategories() throws {
        let map=try map()
        XCTAssertTrue(map.hasCategories)
        let musicians=try XCTUnwrap(map.category("Category:Musicians"))
        XCTAssertEqual(map.categoryAnswer(musicians,list:true),"2 articles are in Category:Musicians, directly rather than through its subcategories, according to Wikipedia's link map (2026-10-01). Most linked-to first: Jazz, Ray Charles.")
        XCTAssertNil(map.category("Rock musicians"))
        let ray=try XCTUnwrap(map.node("Ray Charles"))
        XCTAssertEqual(map.categoriesAnswer(of:ray),"“Ray Charles” is in 2 categories: Jazz pianists, Musicians (plus 1 maintenance category editors use). From Wikipedia's link map (2026-10-01).")
        XCTAssertEqual(map.categoriesAnswer(of:try XCTUnwrap(map.node("Louvre"))),"“Louvre” isn't in any category in Wikipedia's link map (2026-10-01).")
    }

    func testDumpFilesAndProjects() throws {
        XCTAssertEqual(LinkMapLibrary.dumpTable("enwiki-20261001-pagelinks.sql.gz")?.table,"pagelinks")
        XCTAssertEqual(LinkMapLibrary.dumpTable("zh_yuewiki-20261001-page.sql.gz")?.project,"zh_yuewiki")
        XCTAssertNil(LinkMapLibrary.dumpTable("enwiki-20261001-pages-articles.xml.bz2"))
        XCTAssertNil(LinkMapLibrary.dumpTable("enwiki-20261001-externallinks.sql.gz"),"not a link map table")
        XCTAssertNil(LinkMapLibrary.dumpTable("enwiki-latest-pagelinks.sql.gz"))
        XCTAssertEqual(LinkMapLibrary.project(forPackageName:"wikipedia_en_all:maxi"),"enwiki")
        XCTAssertEqual(LinkMapLibrary.project(forPackageName:"imported:wikipedia_fr_all_nopic"),"frwiki")
        XCTAssertEqual(LinkMapLibrary.project(forPackageName:"wikipedia_en_simple_all"),"simplewiki")
        XCTAssertEqual(LinkMapLibrary.project(forPackageName:"wikipedia_zh-yue_all"),"zh_yuewiki")
        XCTAssertNil(LinkMapLibrary.project(forPackageName:"wiktionary_en_all"))
        XCTAssertNil(LinkMapLibrary.project(forPackageName:"gutenberg_en_all"))
        XCTAssertTrue(LinkMapLibrary.missingMap(project:"enwiki",for:"Category questions").contains("download the link map files for enwiki"))
        XCTAssertTrue(LinkMapLibrary.missingMap(project:nil,for:"Category questions").contains("only in a Wikipedia package"))
    }

    /// A failed build says why, instead of a generic "couldn't access the library files".
    func testErrorsSayWhatWentWrong() {
        for error in [LinkMapError.needsLinkTargets,.insufficientSpace,.missingTables(["redirect"])] {
            XCTAssertEqual(AtlasLog.message(error),error.errorDescription)
        }
        XCTAssertEqual(AtlasLog.message(SQLDumpError.missingColumn("page","page_title")),SQLDumpError.missingColumn("page","page_title").errorDescription)
        XCTAssertEqual(AtlasLog.message(AtlasError.notZIM),AtlasError.notZIM.errorDescription)
        let denied=AtlasLog.message(CocoaError(.fileWriteNoPermission))
        XCTAssertTrue(denied.hasPrefix("Sematrica couldn’t access the library files ("),denied)
        XCTAssertTrue(AtlasLog.message(CocoaError(.fileWriteOutOfSpace)).contains("enough free space"))
    }

    func testDumpSetsAndDownloads() throws {
        func archive(_ name:String,date:String)->WikipediaPackage {
            WikipediaPackage(id:"wikimedia:"+name,name:name,languageCode:"en",kind:.rawDump,summary:"",version:date,
                             downloadURL:URL(string:"https://dumps.wikimedia.org/enwiki/\(date)/\(name)")!,downloadBytes:100,format:.archive,source:"Wikimedia",family:name)
        }
        let catalog=["abstract.xml.gz","categorylinks.sql.gz","page.sql.gz","pagelinks.sql.gz","linktarget.sql.gz","redirect.sql.gz","externallinks.sql.gz","langlinks.sql.gz"]
            .flatMap {[archive("enwiki-20261001-"+$0,date:"20261001"),archive("enwiki-20260901-"+$0,date:"20260901")]}
        XCTAssertEqual(LinkMapLibrary.downloads(in:catalog).map(\.name),["page","redirect","pagelinks","linktarget","categorylinks","langlinks"].map {"enwiki-20261001-\($0).sql.gz"},
                       "the newest dump's link map tables, in build order")
        var records=catalog.map {PackageRecord(package:$0)}
        for index in records.indices where records[index].package.version == "20261001" {records[index].state = .installed}
        let sets=LinkMapLibrary.dumpSets(records)
        XCTAssertEqual(sets.map(\.id),["enwiki-20261001"],"only installed tables count")
        XCTAssertEqual(sets.first?.missing,[])
        XCTAssertEqual(sets.first?.readableDate,"2026-10-01")
        records.removeAll {$0.package.name.hasSuffix("-redirect.sql.gz")}
        XCTAssertEqual(LinkMapLibrary.dumpSets(records).first?.missing,["redirect"])

        // Archives say they can't be read, and what they're for.
        let table=catalog.first {$0.name == "enwiki-20261001-pagelinks.sql.gz"}!,other=catalog.first {$0.name == "enwiki-20261001-abstract.xml.gz"}!
        XCTAssertTrue(table.isLinkMapTable)
        XCTAssertFalse(other.isLinkMapTable)
        XCTAssertEqual(table.capabilities,"Not readable · Builds the link map")
        XCTAssertEqual(other.capabilities,"Not readable · Stored as a dataset")
        XCTAssertTrue(table.archiveNote?.contains("Link maps") == true)
        XCTAssertTrue(other.archiveNote?.contains("ZIM package") == true)
        let rows=try PackageCatalog.parseWikimedia(Data(#"{"jobs":{"pagelinkstable":{"status":"done","files":{"enwiki-20261001-pagelinks.sql.gz":{"size":5,"url":"/enwiki/20261001/enwiki-20261001-pagelinks.sql.gz","sha1":"da39a3ee5e6b4b0d3255bfef95601890afd80709"}}}}}"#.utf8),project:"enwiki",date:"20261001")
        XCTAssertTrue(rows.first?.summary.contains("link map") == true)
    }

    func testInstalledMapsAndPlainLinkQuestions() throws {
        _ = try map()
        XCTAssertEqual(LinkMapLibrary.installed(in:fixture.folder).map(\.manifest.project),["enwiki"])
        XCTAssertNotNil(LinkMapLibrary.open(project:"enwiki",in:fixture.folder))
        XCTAssertNil(LinkMapLibrary.open(project:"frwiki",in:fixture.folder))
        try FileManager.default.createDirectory(at:fixture.folder.appendingPathComponent("linkmap-frwiki-20261001.building"),withIntermediateDirectories:true)
        XCTAssertEqual(LinkMapLibrary.installed(in:fixture.folder).count,1,"an unfinished build isn't a map")

        var links=PageQuery(unit:"link");links.linksTo="Paris"
        XCTAssertEqual(LibraryRequest(scope:"library",measure:"list",query:links).linksHereTarget,"Paris")
        XCTAssertNil(LibraryRequest(scope:"library",measure:"total",query:links).linksHereTarget,"totals count links in each article")
        XCTAssertNil(LibraryRequest(scope:"linked",measure:"list",query:links).linksHereTarget)
        var section=links;section.section="Career"
        XCTAssertNil(LibraryRequest(scope:"library",measure:"list",query:section).linksHereTarget,"only links in a section need reading")
    }
}

final class LinkMapSubcategoryAndLanguageTests:XCTestCase {
    var fixture:DumpFixture!
    override func setUpWithError() throws {fixture=try DumpFixture()}
    override func tearDown() {fixture.remove()}

    func map() throws -> LinkMap {
        var chain:[String:[String]]=[:]
        for level in 0..<7 {chain["Level_\(level)"]=["Level_\(level+1)"]}
        return try fixture.linkMap(["Ray_Charles":["Jazz","Paris"],"Herbie_Hancock":["Jazz"],"Jazz":["Ray_Charles"]],
                                   categories:["Music":["Jazz"],"Jazz_musicians":["Ray_Charles"],"Jazz_pianists":["Ray_Charles","Herbie_Hancock"],
                                               "Pianists":["Herbie_Hancock"],"Loop_A":["Paris"],"Level_7":["Paris"],"Category_theory":["Paris"]],
                                   subcategories:chain.merging(["Music":["Jazz_musicians"],"Jazz_musicians":["Jazz_pianists"],"Pianists":["Jazz_pianists"],
                                                                "Loop_A":["Loop_B"],"Loop_B":["Loop_A"]]) {$1},
                                   languages:["Paris":[("de","Paris"),("fr","Paris"),("ja","パリ")],"Jazz":[("simple","Jazz")]])
    }

    func testCategoryTrees() throws {
        let map=try map()
        func category(_ name:String)->Int32 {map.category(name) ?? -1}
        XCTAssertTrue(map.hasSubcategories)
        XCTAssertEqual(map.subcategories(category("Music")).map(map.categoryName),["Jazz_musicians"])
        XCTAssertEqual(Set(map.parentCategories(category("Jazz pianists")).map(map.categoryName)),["Jazz_musicians","Pianists"])
        let music=map.categoryTree(category("Music"))
        XCTAssertEqual(music.categories.map(map.categoryName),["Music","Jazz_musicians","Jazz_pianists"])
        XCTAssertEqual(music.depth,2)
        XCTAssertFalse(music.cut)
        XCTAssertEqual(Set(map.members(of:music).map(map.title)),["Jazz","Ray_Charles","Herbie_Hancock"],"Ray Charles is in two of them and counts once")

        // A category inside its own subcategory is visited once.
        let loop=map.categoryTree(category("Loop A"))
        XCTAssertEqual(Set(loop.categories.map(map.categoryName)),["Loop_A","Loop_B"])
        XCTAssertFalse(loop.cut)

        // Deep or wide trees stop, and say so.
        XCTAssertNotNil(map.category("Level 0"),"a category holding only subcategories can be looked up")
        XCTAssertEqual(map.category("Category theory").map(map.categoryName),"Category_theory","a name that starts with “Category” is kept")
        XCTAssertEqual(map.category("Category:Category theory").map(map.categoryName),"Category_theory")
        XCTAssertEqual(map.category("category Music").map(map.categoryName),"Music")
        let deep=map.categoryTree(category("Level 0"))
        XCTAssertEqual(deep.depth,LinkMap.defaultTreeDepth)
        XCTAssertTrue(deep.cut)
        XCTAssertEqual(map.members(of:deep),[],"Level 7 is beyond the depth")
        XCTAssertEqual(map.members(of:map.categoryTree(category("Level 0"),maxDepth:10)).map(map.title),["Paris"])
        let small=map.categoryTree(category("Level 0"),limit:3)
        XCTAssertEqual(small.categories.count,3)
        XCTAssertTrue(small.cut)
    }

    func testCategoryAnswers() throws {
        let map=try map()
        func category(_ name:String)->Int32 {map.category(name) ?? -1}
        let music=category("Music"),tree=map.categoryTree(music)
        XCTAssertEqual(map.categoryTreeAnswer(music,tree:tree,members:map.members(of:tree),list:false),
                       "3 articles are in Category:Music or the 2 categories inside it (2 levels down), each article counted once, according to Wikipedia's link map (2026-10-01).")
        XCTAssertTrue(map.categoryTreeAnswer(category("Level 0"),tree:map.categoryTree(category("Level 0")),members:[],list:false).contains("The tree goes on further"))
        XCTAssertTrue(map.categoryAnswer(music,list:false).hasSuffix("It also has 1 subcategory; ask “including subcategories” to count their articles too."))
        XCTAssertEqual(map.subcategoriesAnswer(category("Jazz musicians")),"Category:Jazz musicians has 1 subcategory, according to Wikipedia's link map (2026-10-01): Jazz pianists.")
        XCTAssertEqual(map.subcategoriesAnswer(category("Pianists")),"Category:Pianists has 1 subcategory, according to Wikipedia's link map (2026-10-01): Jazz pianists.")
        XCTAssertEqual(map.parentsAnswer(category("Jazz pianists")),"Category:Jazz pianists is inside 2 categories: Jazz musicians, Pianists. From Wikipedia's link map (2026-10-01).")
        XCTAssertEqual(map.parentsAnswer(music),"Category:Music isn't inside any other category in Wikipedia's link map (2026-10-01).")
    }

    func testOtherLanguages() throws {
        let map=try map()
        let paris=try XCTUnwrap(map.node("Paris"))
        XCTAssertTrue(map.hasLanguages)
        let links=map.languageLinks(of:paris)
        XCTAssertEqual(Set(links.map(\.language)),["de","fr","ja"])
        XCTAssertEqual(links.first {$0.language == "fr"}?.project,"frwiki")
        let answer=map.languagesAnswer(paris,links:links,installed:["frwiki"])
        XCTAssertTrue(answer.hasPrefix("“Paris” has an article in 3 other languages, according to Wikipedia's link map (2026-10-01)."),answer)
        XCTAssertTrue(answer.contains("You can read it in \(LinkMapLibrary.languageName("fr")) (“Paris”)"),answer)
        XCTAssertTrue(map.languagesAnswer(paris,links:links,installed:[]).contains("None of them has a Wikipedia package"))
        XCTAssertEqual(map.languageLinks(of:map.node("Jazz")!).first?.name,"Simple English")
        XCTAssertEqual(map.languagesAnswer(map.node("Herbie Hancock")!,links:[],installed:[]),"“Herbie Hancock” has no article in another language in Wikipedia's link map (2026-10-01).")
    }

    func testLanguageNamesAndProjects() {
        XCTAssertEqual(LinkMapLibrary.languageCode(named:"French"),"fr")
        XCTAssertEqual(LinkMapLibrary.languageCode(named:"french Wikipedia"),"fr")
        XCTAssertEqual(LinkMapLibrary.languageCode(named:"Français"),"fr","a language's own name")
        XCTAssertEqual(LinkMapLibrary.languageCode(named:"Deutsch"),"de")
        XCTAssertEqual(LinkMapLibrary.languageCode(named:"ja"),"ja")
        XCTAssertEqual(LinkMapLibrary.languageCode(named:"Simple English"),"simple")
        XCTAssertNil(LinkMapLibrary.languageCode(named:"a new window"))
        XCTAssertEqual(LinkMapLibrary.languageCode(named:"German",among:["fr","de"]),"de")
        XCTAssertNil(LinkMapLibrary.languageCode(named:"Japanese",among:["fr","de"]),"only the article's languages count")
        XCTAssertEqual(LinkMapLibrary.languageCode(named:"zh-yue",among:["zh-yue"]),"zh-yue")
        XCTAssertEqual(LinkMapLibrary.project(forLanguage:"zh-yue"),"zh_yuewiki")
        XCTAssertEqual(LinkMapLibrary.project(forLanguage:"be-tarask"),"be_x_oldwiki")
        XCTAssertEqual(LinkMapLibrary.project(forLanguage:"simple"),"simplewiki")
        XCTAssertEqual(LinkMapLibrary.project(forPackageName:"wikipedia_fr_all_maxi"),LinkMapLibrary.project(forLanguage:"fr"),"packages and languages meet on the same name")
    }

    /// Maps built before subcategories and languages still open, without them.
    func testVersionOneMapsStillOpen() throws {
        let built=try fixture.linkMap(["Ray_Charles":["Paris"]],categories:["Musicians":["Ray_Charles"]])
        let file=built.directory.appendingPathComponent(LinkMap.manifestName)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        json["version"]=1;json["subcategoryLinks"]=nil;json["languageLinks"]=nil;json["languages"]=nil
        try JSONSerialization.data(withJSONObject:json).write(to:file)
        let old=try LinkMap(directory:built.directory)
        XCTAssertEqual(old.manifest.version,1)
        XCTAssertTrue(old.hasCategories)
        XCTAssertFalse(old.hasSubcategories)
        XCTAssertFalse(old.hasLanguages)
        XCTAssertEqual(old.languages(of:0).count,0)
        json["version"]=99
        try JSONSerialization.data(withJSONObject:json).write(to:file)
        XCTAssertThrowsError(try LinkMap(directory:built.directory)) {XCTAssertEqual($0 as? LinkMapError,.outdated)}
    }
}
