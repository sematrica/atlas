import Foundation

/// The Wikimedia table dumps a link map is built from.
public struct LinkMapSources:Sendable,Equatable {
    public var project:String
    public var date:String
    public var page:URL
    public var redirect:URL
    public var pagelinks:URL
    /// Needed by dumps from 2024 on, whose links point into this table instead of naming titles.
    public var linktarget:URL?
    /// Optional: without it there are no categories.
    public var categorylinks:URL?
    /// Optional: each article's title in other languages' Wikipedias.
    public var langlinks:URL?
    public init(project:String,date:String,page:URL,redirect:URL,pagelinks:URL,linktarget:URL?=nil,categorylinks:URL?=nil,langlinks:URL?=nil) {
        self.project=project;self.date=date;self.page=page;self.redirect=redirect;self.pagelinks=pagelinks;self.linktarget=linktarget
        self.categorylinks=categorylinks;self.langlinks=langlinks
    }
}

public struct LinkMapProgress:Sendable,Equatable {
    public var step:Int
    public var steps:Int
    public var stage:String
    /// Progress within the stage, 0–1.
    public var fraction:Double
    public var overall:Double {(Double(step-1)+min(1,max(0,fraction)))/Double(max(1,steps))}
}

/// Builds a link map from Wikimedia's table dumps:
///
/// 1. `page`: every article (namespace 0, not a redirect) gets a number; redirects are noted.
/// 2. `redirect`: each redirect is pointed at the article it leads to.
/// 3. `linktarget` (2024-on dumps): link targets are matched to articles and categories.
/// 4. `pagelinks`: links between articles, with links to redirects counted as links to their articles.
/// 5. Links are sorted into per-article lists, in both directions.
/// 6. `categorylinks` (optional): which articles are in which categories, and which categories
///    are subcategories of which.
/// 7. `langlinks` (optional): each article's title in other languages' Wikipedias.
///
/// Files are written into a `.building` folder that is renamed into place only when complete.
public enum LinkMapBuilder {
    /// Edges sorted per pass when building adjacency lists (256 MB of UInt32s).
    static var chunkEdges=64*1024*1024

    public static func build(_ sources:LinkMapSources,into directory:URL,progress:@escaping @Sendable (LinkMapProgress) -> Void={_ in}) throws -> LinkMapManifest {
        let fm=FileManager.default
        let building=directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent+".building")
        if fm.fileExists(atPath:building.path) {try fm.removeItem(at:building)}
        try fm.createDirectory(at:building,withIntermediateDirectories:true)
        do {
            let manifest=try Builder(sources:sources,folder:building,progress:progress).run()
            try JSONEncoder().encode(manifest).write(to:building.appendingPathComponent(LinkMap.manifestName),options:.atomic)
            if fm.fileExists(atPath:directory.path) {try fm.removeItem(at:directory)}
            try fm.moveItem(at:building,to:directory)
            return manifest
        } catch {
            try? fm.removeItem(at:building)
            throw error
        }
    }

    /// Roughly the most disk space a build uses while it runs: the link lists in both directions
    /// plus a temporary copy of every link, judged from the compressed tables' sizes.
    public static func estimatedSpace(_ sources:LinkMapSources)->Int64 {
        func size(_ url:URL?)->Int64 {Int64((try? url?.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
        return 3*size(sources.pagelinks)+size(sources.categorylinks)+size(sources.page)+size(sources.linktarget)+2*size(sources.langlinks)+(256<<20)
    }

    /// Which schema a dump's links use, from its column list.
    public static func needsLinkTargets(pagelinks:URL) throws -> Bool {
        try SQLDump.columns(of:pagelinks,table:"pagelinks").contains("pl_target_id")
    }
}

private final class Builder {
    let sources:LinkMapSources
    let folder:URL
    let report:@Sendable (LinkMapProgress) -> Void
    let steps:Int
    var step=0

    // Articles and redirects in namespace 0.
    var pageNode:[Int32]=[]           // page_id → article number, or -(redirect+2), or -1
    var titles=StringArena()          // article number → title
    var redirectTitles=StringArena()  // redirect → its own title
    var redirectTarget:[Int32]=[]     // redirect → article number, or -1
    var titleNode:[String:Int32]=[:]  // title → article number (redirect titles included once resolved)
    // Link targets (2024-on schema).
    var targetNode:[Int32]=[]         // lt_id → article number, or -1
    var targetCategory:[Int32]=[]     // lt_id → category number, or -1
    // Categories.
    var categoryNames=StringArena()
    var categoryIndex:[String:Int32]=[:]
    var categoryPage:[Int32:Int32]=[:]   // a category page's page_id → category number
    var populatedCategories=0
    var subcategoryLinks=0

    init(sources:LinkMapSources,folder:URL,progress:@escaping @Sendable (LinkMapProgress) -> Void) {
        self.sources=sources;self.folder=folder;report=progress
        steps=4+(sources.linktarget == nil ? 0 : 1)+(sources.categorylinks == nil ? 0 : 1)+(sources.langlinks == nil ? 0 : 1)
    }

    func begin(_ stage:String) {step += 1;report(.init(step:step,steps:steps,stage:stage,fraction:0))}
    func fraction(_ stage:String)->(Double) -> Void {
        let step=self.step,steps=self.steps,report=self.report
        return {report(.init(step:step,steps:steps,stage:stage,fraction:$0))}
    }
    func file(_ name:String)->URL {folder.appendingPathComponent(name)}

    func run() throws -> LinkMapManifest {
        let newLinks=try LinkMapBuilder.needsLinkTargets(pagelinks:sources.pagelinks)
        if newLinks,sources.linktarget == nil {throw LinkMapError.needsLinkTargets}
        var newCategories=false
        if let categorylinks=sources.categorylinks {
            let columns=try SQLDump.columns(of:categorylinks,table:"categorylinks")
            newCategories = !columns.contains("cl_to") && columns.contains("cl_target_id")
            if newCategories,sources.linktarget == nil {throw LinkMapError.needsLinkTargets}
        }
        try readPages()
        try readRedirects()
        try writeLookup()
        if let linktarget=sources.linktarget {try readLinkTargets(linktarget,categories:newCategories)}
        let (edges,linkCount,outDegree,inDegree)=try readLinks(newSchema:newLinks)
        begin("Sorting links")
        try writeAdjacency(edges:edges,count:linkCount,keyIsFirst:true,degrees:outDegree,offsets:file("links.offsets"),targets:file("links.targets"),fraction:fraction("Sorting links"))
        try writeAdjacency(edges:edges,count:linkCount,keyIsFirst:false,degrees:inDegree,offsets:file("backlinks.offsets"),targets:file("backlinks.targets"),fraction:{_ in})
        try? FileManager.default.removeItem(at:edges)
        titleNode=[:];targetNode=[]
        var memberships=0
        if let categorylinks=sources.categorylinks {memberships=try readCategories(categorylinks,newSchema:newCategories)}
        categoryPage=[:]
        var languages=(links:0,count:0)
        if let langlinks=sources.langlinks {languages=try readLanguageLinks(langlinks)}
        try titles.write(to:file("titles.strings"))
        var manifest=LinkMapManifest(project:sources.project,date:sources.date,articles:titles.count,links:linkCount,
                                     categories:memberships>0 || subcategoryLinks>0 ? populatedCategories : 0,memberships:memberships)
        manifest.subcategoryLinks=subcategoryLinks
        manifest.languageLinks=languages.links;manifest.languages=languages.count
        return manifest
    }

    static func setting(_ array:inout [Int32],_ index:Int,_ value:Int32) {
        if index>=array.count {array.append(contentsOf:repeatElement(-1,count:max(index+1-array.count,array.count/2+1024)))}
        array[index]=value
    }
    func pageValue(_ id:Int64?)->Int32 {
        guard let id,id>=0,Int(id)<pageNode.count else {return -1}
        return pageNode[Int(id)]
    }

    // 1. page
    func readPages() throws {
        begin("Reading article titles")
        let categories=sources.categorylinks != nil
        try SQLDump.read(sources.page,table:"page",wanted:["page_id","page_namespace","page_title","page_is_redirect"],progress:fraction("Reading article titles")) {row in
            guard let id=row[0].int,id>=0,let title=row[2].bytes else {return}
            // Category pages, so subcategory entries can name the category they're about.
            if row[1].int == 14,categories,row[3].int != 1,id<=Int64(Int32.max) {categoryPage[Int32(id)]=categoryID(title);return}
            guard row[1].int == 0 else {return}
            if row[3].int == 1 {
                Self.setting(&pageNode,Int(id),-Int32(redirectTitles.count)-2)
                redirectTitles.append(title)
                redirectTarget.append(-1)
            } else {
                let node=Int32(titles.count)
                Self.setting(&pageNode,Int(id),node)
                titles.append(title)
                titleNode[String(decoding:title,as:UTF8.self)]=node
            }
        }
    }

    // 2. redirect
    func readRedirects() throws {
        begin("Following redirects")
        try SQLDump.read(sources.redirect,table:"redirect",wanted:["rd_from","rd_namespace","rd_title","rd_interwiki"],optional:["rd_interwiki"],
                         progress:fraction("Following redirects")) {row in
            let value=pageValue(row[0].int)
            guard value <= -2,row[1].int == 0,(row[3].bytes ?? []).isEmpty,let title=row[2].bytes else {return}
            if let target=titleNode[String(decoding:title,as:UTF8.self)] {redirectTarget[Int(-value-2)]=target}
        }
        for index in 0..<redirectTitles.count where redirectTarget[index]>=0 {
            titleNode[String(decoding:redirectTitles.slice(index),as:UTF8.self)]=redirectTarget[index]
        }
    }

    /// Every title (articles and redirects), sorted by its bytes, with the article it means.
    func writeLookup() throws {
        var entries=Array(0..<titles.count)
        entries.append(contentsOf:(0..<redirectTitles.count).filter {redirectTarget[$0]>=0}.map {titles.count+$0})
        let articleCount=titles.count
        func key(_ entry:Int)->ArraySlice<UInt8> {entry<articleCount ? titles.slice(entry) : redirectTitles.slice(entry-articleCount)}
        entries.sort {key($0).lexicographicallyPrecedes(key($1))}
        var keys=StringArena(),nodes:[UInt32]=[]
        keys.reserve(entries.count)
        nodes.reserveCapacity(entries.count)
        var previous:ArraySlice<UInt8>?
        for entry in entries {
            let title=key(entry)
            if let previous,previous == title {continue}
            keys.append(title)
            nodes.append(UInt32(entry<articleCount ? entry : Int(redirectTarget[entry-articleCount])))
            previous=title
        }
        try keys.write(to:file("lookup.strings"))
        try NumberFile.write(nodes,to:file("lookup.nodes"))
        redirectTitles=StringArena()
    }

    // 3. linktarget
    func readLinkTargets(_ url:URL,categories:Bool) throws {
        begin("Matching link targets")
        try SQLDump.read(url,table:"linktarget",wanted:["lt_id","lt_namespace","lt_title"],progress:fraction("Matching link targets")) {row in
            guard let id=row[0].int,id>=0,let namespace=row[1].int,let title=row[2].bytes else {return}
            if namespace == 0,let node=titleNode[String(decoding:title,as:UTF8.self)] {Self.setting(&targetNode,Int(id),node)}
            else if namespace == 14,categories {Self.setting(&targetCategory,Int(id),categoryID(title))}
        }
    }
    func categoryID(_ title:[UInt8])->Int32 {
        let name=String(decoding:title,as:UTF8.self)
        if let id=categoryIndex[name] {return id}
        let id=Int32(categoryNames.count)
        categoryIndex[name]=id;categoryNames.append(title)
        return id
    }

    // 4. pagelinks
    func readLinks(newSchema:Bool) throws -> (URL,Int,[UInt32],[UInt32]) {
        begin("Reading links")
        let edges=file("edges.tmp")
        let writer=try PairWriter(edges)
        var outDegree=[UInt32](repeating:0,count:titles.count),inDegree=[UInt32](repeating:0,count:titles.count)
        let wanted=newSchema ? ["pl_from","pl_from_namespace","pl_target_id"] : ["pl_from","pl_from_namespace","pl_namespace","pl_title"]
        try SQLDump.read(sources.pagelinks,table:"pagelinks",wanted:wanted,optional:["pl_from_namespace"],progress:fraction("Reading links")) {row in
            if let namespace=row[1].int,namespace != 0 {return}
            let from=pageValue(row[0].int)
            guard from>=0 else {return}
            var to:Int32 = -1
            if newSchema {
                if let id=row[2].int,id>=0,Int(id)<targetNode.count {to=targetNode[Int(id)]}
            } else if row[2].int == 0,let title=row[3].bytes {
                to=titleNode[String(decoding:title,as:UTF8.self)] ?? -1
            }
            guard to>=0,to != from else {return}
            try writer.append(UInt32(from),UInt32(to))
            outDegree[Int(from)] += 1;inDegree[Int(to)] += 1
        }
        try writer.close()
        return (edges,writer.count,outDegree,inDegree)
    }

    // 6. categorylinks
    func readCategories(_ url:URL,newSchema:Bool) throws -> Int {
        begin("Reading categories")
        let pairs=file("categories.tmp")
        let writer=try PairWriter(pairs)
        let nested=file("subcategories.tmp")
        let nesting=try PairWriter(nested)
        var perArticle=[UInt32](repeating:0,count:titles.count),perCategory:[UInt32]=[],children:[UInt32]=[],parents:[UInt32]=[]
        func count(_ array:inout [UInt32],_ index:Int32) {
            if Int(index)>=array.count {array.append(contentsOf:repeatElement(0,count:Int(index)+1-array.count))}
            array[Int(index)] += 1
        }
        let page=Array("page".utf8),subcategory=Array("subcat".utf8)
        let wanted=newSchema ? ["cl_from","cl_type","cl_target_id"] : ["cl_from","cl_type","cl_to"]
        try SQLDump.read(url,table:"categorylinks",wanted:wanted,optional:["cl_type"],progress:fraction("Reading categories")) {row in
            let type=row[1].bytes
            if let type,type != page,type != subcategory {return}
            var category:Int32 = -1
            if newSchema {
                if let id=row[2].int,id>=0,Int(id)<targetCategory.count {category=targetCategory[Int(id)]}
            } else if let name=row[2].bytes {
                category=categoryID(name)
            }
            guard category>=0 else {return}
            if type == subcategory {
                // A category page filed in another category: a subcategory.
                guard let id=row[0].int,id>=0,id<=Int64(Int32.max),let child=categoryPage[Int32(id)],child != category else {return}
                try nesting.append(UInt32(category),UInt32(child))
                count(&children,category);count(&parents,child)
                return
            }
            let article=pageValue(row[0].int)
            guard article>=0 else {return}
            try writer.append(UInt32(category),UInt32(article))
            perArticle[Int(article)] += 1
            count(&perCategory,category)
        }
        try writer.close();try nesting.close()
        func padded(_ array:[UInt32])->[UInt32] {array.count<categoryNames.count ? array+repeatElement(0,count:categoryNames.count-array.count) : array}
        perCategory=padded(perCategory);children=padded(children);parents=padded(parents)
        subcategoryLinks=nesting.count
        if nesting.count>0 {
            try writeAdjacency(edges:nested,count:nesting.count,keyIsFirst:true,degrees:children,offsets:file("subcategories.offsets"),targets:file("subcategories.targets"),fraction:{_ in})
            try writeAdjacency(edges:nested,count:nesting.count,keyIsFirst:false,degrees:parents,offsets:file("supercategories.offsets"),targets:file("supercategories.targets"),fraction:{_ in})
        }
        try? FileManager.default.removeItem(at:nested)
        try writeAdjacency(edges:pairs,count:writer.count,keyIsFirst:true,degrees:perCategory,offsets:file("members.offsets"),targets:file("members.targets"),fraction:fraction("Reading categories"))
        try writeAdjacency(edges:pairs,count:writer.count,keyIsFirst:false,degrees:perArticle,offsets:file("articlecategories.offsets"),targets:file("articlecategories.targets"),fraction:{_ in})
        try? FileManager.default.removeItem(at:pairs)
        try categoryNames.write(to:file("categories.strings"))
        // Only categories with articles or subcategories in them can be looked up, whichever dump layout listed them.
        var order=(0..<categoryNames.count).filter {perCategory[$0]>0 || children[$0]>0}
        order.sort {categoryNames.slice($0).lexicographicallyPrecedes(categoryNames.slice($1))}
        populatedCategories=order.count
        var keys=StringArena()
        keys.reserve(order.count)
        for index in order {keys.append(categoryNames.slice(index))}
        try keys.write(to:file("categorylookup.strings"))
        try NumberFile.write(order.map {UInt32($0)},to:file("categorylookup.ids"))
        return writer.count
    }

    // 7. langlinks
    /// Each article's title in other languages, grouped by article: the language of each entry in
    /// `languagelinks.offsets/targets` (numbers into `languages.strings`), its title in `languagelinks.strings`.
    func readLanguageLinks(_ url:URL) throws -> (links:Int,count:Int) {
        begin("Reading other languages")
        var codes:[String:UInt32]=[:],codeNames=StringArena()
        var nodes:[Int32]=[],languages:[UInt32]=[],names=StringArena()
        try SQLDump.read(url,table:"langlinks",wanted:["ll_from","ll_lang","ll_title"],progress:fraction("Reading other languages")) {row in
            let node=pageValue(row[0].int)
            guard node>=0,let language=row[1].bytes,!language.isEmpty,let title=row[2].bytes,!title.isEmpty else {return}
            let key=String(decoding:language,as:UTF8.self)
            let code:UInt32
            if let known=codes[key] {code=known} else {code=UInt32(codes.count);codes[key]=code;codeNames.append(language)}
            nodes.append(node);languages.append(code);names.append(title)
        }
        // Group the entries by article, keeping each article's own order (the dump's, by language).
        var starts=[UInt64](repeating:0,count:titles.count+1)
        for node in nodes {starts[Int(node)+1] += 1}
        for index in 0..<titles.count {starts[index+1] += starts[index]}
        var cursor=Array(starts.dropLast()),order=[Int32](repeating:0,count:nodes.count)
        for (entry,node) in nodes.enumerated() {order[Int(cursor[Int(node)])]=Int32(entry);cursor[Int(node)] += 1}
        nodes=[]
        try NumberFile.write(starts,to:file("languagelinks.offsets"))
        try NumberFile.write(order.map {languages[Int($0)]},to:file("languagelinks.targets"))
        try names.write(to:file("languagelinks.strings"),order:order)
        try codeNames.write(to:file("languages.strings"))
        return (order.count,codeNames.count)
    }

    /// Writes adjacency lists from a file of (UInt32, UInt32) pairs: grouped by the first value
    /// (`keyIsFirst`) or the second. Rows are filled a range at a time, so memory stays bounded.
    func writeAdjacency(edges:URL,count:Int,keyIsFirst:Bool,degrees:[UInt32],offsets:URL,targets:URL,fraction:(Double) -> Void) throws {
        var starts=[UInt64](repeating:0,count:degrees.count+1)
        for index in degrees.indices {starts[index+1]=starts[index]+UInt64(degrees[index])}
        try NumberFile.write(starts,to:offsets)
        let output=try NumberFile.Writer<UInt32>(targets,count:count)
        let rows=degrees.count
        var low=0
        while low<rows {
            // The largest range of rows whose lists fit in one chunk (at least one row).
            var high=low+1
            while high<rows,starts[high+1]-starts[low]<=UInt64(LinkMapBuilder.chunkEdges) {high += 1}
            let base=starts[low],size=Int(starts[high]-base)
            var buffer=[UInt32](repeating:0,count:size)
            var cursor=[UInt64](starts[low..<high])
            try PairReader.forEach(edges) {a,b in
                let key=Int(keyIsFirst ? a : b)
                guard key>=low,key<high else {return}
                buffer[Int(cursor[key-low]-base)]=keyIsFirst ? b : a
                cursor[key-low] += 1
            }
            try output.append(buffer)
            fraction(Double(high)/Double(max(1,degrees.count)))
            low=high
        }
        try output.close()
    }
}

/// Byte strings collected in one array, as titles are read.
struct StringArena {
    var bytes:[UInt8]=[]
    var offsets:[UInt64]=[0]
    var count:Int {offsets.count-1}
    mutating func reserve(_ count:Int) {offsets.reserveCapacity(count+1)}
    mutating func append<S:Collection>(_ string:S) where S.Element == UInt8 {bytes.append(contentsOf:string);offsets.append(UInt64(bytes.count))}
    func slice(_ index:Int)->ArraySlice<UInt8> {bytes[Int(offsets[index])..<Int(offsets[index+1])]}
    /// [count:UInt64][offsets:UInt64 × (count+1)][bytes], as `MappedStrings` reads it.
    func write(to url:URL) throws {
        let writer=try NumberFile.Writer<UInt64>(url,count:count,header:true)
        try writer.append(offsets)
        try writer.appendBytes(bytes)
        try writer.close(checkCount:false)
    }
    /// The same, with the strings in another order: `order[i]` is the string written i-th.
    func write(to url:URL,order:[Int32]) throws {
        let writer=try NumberFile.Writer<UInt64>(url,count:order.count,header:true)
        var positions=[UInt64](repeating:0,count:order.count+1)
        for (index,entry) in order.enumerated() {positions[index+1]=positions[index]+offsets[Int(entry)+1]-offsets[Int(entry)]}
        try writer.append(positions)
        var buffer:[UInt8]=[]
        buffer.reserveCapacity(8<<20)
        for entry in order {
            buffer.append(contentsOf:slice(Int(entry)))
            if buffer.count>=8<<20 {try writer.appendBytes(buffer);buffer.removeAll(keepingCapacity:true)}
        }
        try writer.appendBytes(buffer)
        try writer.close(checkCount:false)
    }
}

enum NumberFile {
    /// [count:UInt64][values].
    static func write<Number:FixedWidthInteger>(_ values:[Number],to url:URL) throws {
        let writer=try Writer<Number>(url,count:values.count)
        try writer.append(values)
        try writer.close()
    }
    final class Writer<Number:FixedWidthInteger> {
        let handle:FileHandle
        let expected:Int
        var written=0
        init(_ url:URL,count:Int,header:Bool=true) throws {
            guard FileManager.default.createFile(atPath:url.path,contents:nil) else {throw LinkMapError.insufficientSpace}
            handle=try FileHandle(forWritingTo:url)
            expected=count
            if header {try handle.write(contentsOf:withUnsafeBytes(of:UInt64(count).littleEndian) {Data($0)})}
        }
        func append(_ values:[Number]) throws {
            try values.withUnsafeBytes {try handle.write(contentsOf:Data($0))}
            written += values.count
        }
        func appendBytes(_ bytes:[UInt8]) throws {try handle.write(contentsOf:Data(bytes))}
        func close(checkCount:Bool=true) throws {
            try handle.close()
            if checkCount,written != expected {throw LinkMapError.damaged}
        }
    }
}

/// A file of (UInt32, UInt32) pairs, written in large blocks.
final class PairWriter {
    let handle:FileHandle
    var buffer:[UInt32]=[]
    private(set) var count=0
    init(_ url:URL) throws {
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else {throw LinkMapError.insufficientSpace}
        handle=try FileHandle(forWritingTo:url)
        buffer.reserveCapacity(1<<21)
    }
    func append(_ a:UInt32,_ b:UInt32) throws {
        buffer.append(a);buffer.append(b);count += 1
        if buffer.count>=1<<21 {try flush()}
    }
    func flush() throws {
        try buffer.withUnsafeBytes {try handle.write(contentsOf:Data($0))}
        buffer.removeAll(keepingCapacity:true)
    }
    func close() throws {try flush();try handle.close()}
}

enum PairReader {
    static func forEach(_ url:URL,_ body:(UInt32,UInt32) -> Void) throws {
        let handle=try FileHandle(forReadingFrom:url)
        defer {try? handle.close()}
        var carry=Data()
        while let read=try handle.read(upToCount:8<<20),!read.isEmpty {
            try Task.checkCancellation()
            var data=read
            if !carry.isEmpty {carry.append(read);data=carry;carry=Data()}
            let pairs=data.count/8
            data.withUnsafeBytes {raw in
                for index in 0..<pairs {
                    body(raw.loadUnaligned(fromByteOffset:index*8,as:UInt32.self),raw.loadUnaligned(fromByteOffset:index*8+4,as:UInt32.self))
                }
            }
            // A short read can split a pair; keep the rest for the next block.
            if data.count%8 != 0 {carry=data.suffix(data.count%8)}
        }
    }
}
