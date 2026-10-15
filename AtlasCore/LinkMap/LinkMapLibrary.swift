import Foundation

/// Where link maps live in the library, which Wikimedia table dumps make one, and which map
/// goes with an open package.
public enum LinkMapLibrary {
    /// The tables a link map is built from. linktarget is needed by dumps from 2024 on;
    /// categorylinks (categories) and langlinks (other languages) are optional.
    public static let tables=["page","redirect","pagelinks","linktarget","categorylinks","langlinks"]
    public static let requiredTables=["page","redirect","pagelinks"]

    /// "enwiki-20261001-pagelinks.sql.gz" → ("enwiki", "20261001", "pagelinks").
    public static func dumpTable(_ fileName:String)->(project:String,date:String,table:String)? {
        guard fileName.hasSuffix(".sql.gz") else {return nil}
        let parts=fileName.dropLast(".sql.gz".count).split(separator:"-")
        guard parts.count == 3,parts[1].count == 8,parts[1].allSatisfy(\.isNumber),tables.contains(String(parts[2])),
              parts[0].allSatisfy({$0.isLetter || $0.isNumber || $0 == "_"}) else {return nil}
        return (String(parts[0]),String(parts[1]),String(parts[2]))
    }

    /// The Wikimedia project a Kiwix Wikipedia package comes from: "wikipedia_en_all_maxi" → "enwiki".
    public static func project(forPackageName raw:String)->String? {
        var name=raw
        if name.hasPrefix("imported:") {name=String(name.dropFirst("imported:".count))}
        if let colon=name.firstIndex(of:":") {name=String(name[..<colon])}
        let parts=name.lowercased().split(separator:"_").map(String.init)
        guard parts.count>=2,parts[0] == "wikipedia" else {return nil}
        if parts[1] == "simple" || (parts[1] == "en" && parts.count>2 && parts[2] == "simple") {return "simplewiki"}
        let language=parts[1].replacingOccurrences(of:"-",with:"_")
        guard !language.isEmpty,language.allSatisfy({$0.isLetter || $0 == "_"}) else {return nil}
        return language+"wiki"
    }

    /// The Wikimedia project of a ZIM package, if it is a Wikipedia.
    public static func project(for package:WikipediaPackage)->String? {
        project(forPackageName:package.family) ?? project(forPackageName:package.name)
    }

    public static func directoryName(project:String,date:String)->String {"linkmap-\(project)-\(date)"}

    /// What to say when a question needs a link map that isn't built.
    public static func missingMap(project:String?,for question:String)->String {
        guard let project else {return "\(question) come from Wikipedia's link map, so I can answer them only in a Wikipedia package."}
        return "\(question) come from Wikipedia's link map, which isn't built for this package yet. Under Packages, choose Archives, download the link map files for \(project), then press Build."
    }

    /// The finished link maps in a library's indexes folder, newest first. Unfinished builds are skipped.
    public static func installed(in indexes:URL)->[(manifest:LinkMapManifest,directory:URL)] {
        let fm=FileManager.default
        guard let entries=try? fm.contentsOfDirectory(at:indexes,includingPropertiesForKeys:nil) else {return []}
        var found:[(manifest:LinkMapManifest,directory:URL)]=[]
        for entry in entries where entry.lastPathComponent.hasPrefix("linkmap-") {
            if entry.lastPathComponent.hasSuffix(".building") {continue}
            guard let data=try? Data(contentsOf:entry.appendingPathComponent(LinkMap.manifestName)),
                  let manifest=try? JSONDecoder().decode(LinkMapManifest.self,from:data) else {continue}
            found.append((manifest,entry))
        }
        return found.sorted {$0.manifest.date>$1.manifest.date}
    }

    /// The newest link map for a project, if one has been built.
    public static func open(project:String,in indexes:URL)->LinkMap? {
        for entry in installed(in:indexes) where entry.manifest.project == project {
            if let map=try? LinkMap(directory:entry.directory) {return map}
        }
        return nil
    }

    /// A dump's tables found among the installed packages, grouped by project and date.
    public struct DumpSet:Identifiable,Sendable,Equatable {
        public var id:String {project+"-"+date}
        public let project:String
        public let date:String
        /// Table → package ID.
        public let records:[String:String]
        public var missing:[String] {LinkMapLibrary.requiredTables.filter {records[$0] == nil}}
        public var readableDate:String {LinkMapManifest(project:project,date:date,articles:0,links:0,categories:0,memberships:0).readableDate}
    }
    public static func dumpSets(_ records:[PackageRecord])->[DumpSet] {
        var grouped:[String:(project:String,date:String,records:[String:String])]=[:]
        for record in records where record.state == .installed && record.package.format == .archive {
            guard let table=dumpTable(record.package.name) else {continue}
            let key=table.project+"-"+table.date
            var entry=grouped[key] ?? (table.project,table.date,[:])
            entry.records[table.table]=record.id
            grouped[key]=entry
        }
        return grouped.values.map {DumpSet(project:$0.project,date:$0.date,records:$0.records)}.sorted {($0.project,$1.date)<($1.project,$0.date)}
    }

    /// The link map tables of the newest dump in a loaded archive catalog, to download together.
    public static func downloads(in catalog:[WikipediaPackage])->[WikipediaPackage] {
        let found=catalog.compactMap {package in dumpTable(package.name).map {(package,$0)}}
        guard let date=found.map(\.1.date).max() else {return []}
        return found.filter {$0.1.date == date}.sorted {order($0.1.table)<order($1.1.table)}.map(\.0)
    }
    static func order(_ table:String)->Int {tables.firstIndex(of:table) ?? tables.count}
}

// MARK: - Other languages

/// An article's counterpart in another language's Wikipedia.
public struct LanguageLink:Sendable,Equatable,Identifiable {
    public var id:String {language}
    /// Wikipedia's language code: "fr", "zh-yue", "simple".
    public let language:String
    /// The article's title there, with spaces.
    public let title:String
    public init(language:String,title:String) {self.language=language;self.title=title.replacingOccurrences(of:"_",with:" ")}
    /// That Wikipedia's Wikimedia project: "frwiki".
    public var project:String {LinkMapLibrary.project(forLanguage:language)}
    /// The language's name for the reader: "French".
    public var name:String {LinkMapLibrary.languageName(language)}
}

extension LinkMapLibrary {
    /// "fr" → "frwiki", "zh-yue" → "zh_yuewiki": Wikimedia's project names, as packages are matched by.
    public static func project(forLanguage code:String)->String {
        let special=["be-tarask":"be_x_oldwiki"]
        return special[code] ?? code.lowercased().replacingOccurrences(of:"-",with:"_")+"wiki"
    }

    /// A language's name in the reader's language ("French"), or its code when there's no name for it.
    public static func languageName(_ code:String,locale:Locale = .current)->String {
        if code == "simple" {return "Simple English"}
        guard let name=locale.localizedString(forLanguageCode:code),!name.isEmpty,name.lowercased() != code.lowercased() else {return code}
        return name.prefix(1).uppercased()+name.dropFirst()
    }

    /// Language names a reader might type, folded, with their codes: English names ("french"),
    /// each language's own name ("français") and names in the reader's language.
    static let knownLanguages:[String:String]={
        var names:[String:String]=["simple":"simple","simple english":"simple"]
        let english=Locale(identifier:"en_US")
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count<=3 {
            names[code]=code
            for name in [english.localizedString(forLanguageCode:code),Locale(identifier:code).localizedString(forLanguageCode:code),
                         Locale.current.localizedString(forLanguageCode:code)].compactMap({$0}) {
                let folded=foldLanguage(name)
                if !folded.isEmpty,names[folded] == nil {names[folded]=code}
            }
        }
        return names
    }()

    static func foldLanguage(_ text:String)->String {
        var folded=text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US"))
            .trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
        for prefix in ["the "] where folded.hasPrefix(prefix) {folded=String(folded.dropFirst(prefix.count))}
        for suffix in [" wikipedia"," version"," language"," edition"] where folded.hasSuffix(suffix) {folded=String(folded.dropLast(suffix.count))}
        return folded.split(whereSeparator:\.isWhitespace).joined(separator:" ")
    }

    /// The language code a name means: a code ("fr"), an English name ("French"), the language's
    /// own name ("français") or its name in the reader's language. With `codes`, only those count,
    /// and Wikipedia's own codes that aren't ISO languages ("zh-yue", "simple") are matched too.
    public static func languageCode(named raw:String,among codes:[String]?=nil)->String? {
        let folded=foldLanguage(raw)
        guard !folded.isEmpty else {return nil}
        if let codes {
            if let code=codes.first(where:{$0.lowercased() == folded}) {return code}
            if let known=knownLanguages[folded],codes.contains(known) {return known}
            for code in codes {
                var names:[String]=[languageName(code),languageName(code,locale:Locale(identifier:"en_US"))]
                if let own=Locale(identifier:code).localizedString(forLanguageCode:code) {names.append(own)}
                if names.contains(where:{foldLanguage($0) == folded}) {return code}
            }
            return nil
        }
        return knownLanguages[folded]
    }
}

extension LinkMap {
    /// The article's counterparts in other languages, sorted by language name.
    public func languageLinks(of node:Int32)->[LanguageLink] {
        languages(of:node).map {LanguageLink(language:$0.language,title:$0.title)}.sorted {$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending}
    }

    /// "“Paris” is in 250 other languages, according to …. You have packages for French (“Paris”) and German (“Paris”)."
    public func languagesAnswer(_ node:Int32,links:[LanguageLink],installed:Set<String>)->String {
        let title=readableTitle(node)
        guard !links.isEmpty else {return "“\(title)” has no article in another language in \(sourceName)."}
        var text="“\(title)” has an article in \(LibraryRun.format(links.count)) other language\(links.count == 1 ? "" : "s"), according to \(sourceName)."
        let readable=links.filter {installed.contains($0.project)}
        if readable.isEmpty {
            let common=["fr","de","es","ja","zh","ru","it","pt","ar"].compactMap {code in links.first {$0.language == code}}
            let named:[String]=common.prefix(5).map {"\($0.name) (“\($0.title)”)"}
            if !named.isEmpty {text += " Among them: \(named.joined(separator:", "))."}
            text += " None of them has a Wikipedia package in your library yet."
        } else {
            let named:[String]=readable.map {"\($0.name) (“\($0.title)”)"}
            text += " You can read it in \(named.joined(separator:", ")): use the Languages menu, or say “open this in \(readable[0].name)”."
        }
        return text
    }

    // MARK: Subcategories

    /// "Category:Jazz musicians has 14 subcategories: …" (the fullest first).
    public func subcategoriesAnswer(_ category:Int32)->String {
        let name=categoryName(category).replacingOccurrences(of:"_",with:" ")
        let sized:[(id:Int32,size:Int)]=subcategories(category).map {($0,memberCount($0))}
        let children=sized.sorted {$0.size != $1.size ? $0.size>$1.size : $0.id<$1.id}
        guard !children.isEmpty else {return "Category:\(name) has no subcategories in \(sourceName)."}
        let shown:[String]=children.prefix(25).map {categoryName($0.id).replacingOccurrences(of:"_",with:" ")}
        let more=children.count>25 ? ", …" : ""
        let noun=children.count == 1 ? "subcategory" : "subcategories"
        return "Category:\(name) has \(LibraryRun.format(children.count)) \(noun), according to \(sourceName): \(shown.joined(separator:", "))\(more)."
    }

    /// "Category:Jazz pianists is filed in 2 categories: Jazz musicians, Pianists."
    public func parentsAnswer(_ category:Int32)->String {
        let name=categoryName(category).replacingOccurrences(of:"_",with:" ")
        let names=parentCategories(category).map(categoryName)
        let shown=names.filter {!LinkMap.isMaintenance($0)}.map {$0.replacingOccurrences(of:"_",with:" ")}.sorted()
        guard !names.isEmpty else {return "Category:\(name) isn't inside any other category in \(sourceName)."}
        var text="Category:\(name) is inside \(shown.count) categor\(shown.count == 1 ? "y" : "ies")"
        if !shown.isEmpty {
            let more=shown.count>25 ? ", …" : ""
            text += ": \(shown.prefix(25).joined(separator:", "))\(more)"
        }
        let hidden=names.count-shown.count
        if hidden>0 {text += " (plus \(hidden) maintenance categor\(hidden == 1 ? "y" : "ies"))"}
        return text+". From \(sourceName)."
    }

    /// The articles in a category's whole tree: "2,345 articles are in Category:Jazz musicians or the 312 categories inside it…"
    public func categoryTreeAnswer(_ category:Int32,tree:CategoryTree,members:[Int32],list:Bool)->String {
        let name=categoryName(category).replacingOccurrences(of:"_",with:" ")
        let inside=tree.categories.count-1
        var text="\(LibraryRun.format(members.count)) article\(members.count == 1 ? " is" : "s are") in Category:\(name)"
        if inside>0 {
            let noun=inside == 1 ? "category" : "categories",levels=tree.depth == 1 ? "1 level" : "\(tree.depth) levels"
            text += " or the \(LibraryRun.format(inside)) \(noun) inside it (\(levels) down)"
        }
        else {text += ", which has no subcategories"}
        text += ", each article counted once, according to \(sourceName)."
        if tree.cut {text += " The tree goes on further: I followed it \(tree.depth) levels down and \(LibraryRun.format(LinkMap.defaultTreeLimit)) categories at most, because Wikipedia's categories drift into neighbouring topics the deeper they go."}
        if list,!members.isEmpty {
            let ranked:[(id:Int32,links:Int)]=members.map {($0,inDegree($0))}
            let top:[String]=ranked.sorted {$0.links != $1.links ? $0.links>$1.links : $0.id<$1.id}.prefix(5).map {readableTitle($0.id)}
            text += " Most linked-to first: \(top.joined(separator:", "))."
        }
        return text
    }
}

// MARK: - Answers

extension LibraryRequest {
    /// The article a plain "which articles link to X" question across the whole library asks about.
    /// A link map answers it outright, from every article rather than only those that mention X.
    public var linksHereTarget:String? {
        guard scope == "library",measure != "total" else {return nil}
        let q=query.normalized()
        guard let target=q.linksTo else {return nil}
        var plain=PageQuery(unit:"link");plain.linksTo=target
        return plain.normalized() == q ? target : nil
    }
}

extension LinkMap {
    /// This package's articles for map nodes, after the package's redirects. Nodes it lacks are left out.
    /// New ZIM files name articles "Paris", older ones "A/Paris"; `prefix` is tried first.
    public func articles(_ nodes:[Int32],in source:any LibraryArticleSource,prefix:String="") async throws -> [Int32:SearchResult] {
        let other=prefix.isEmpty ? "A/" : ""
        let found=try await source.resolve(paths:nodes.flatMap {[prefix+title($0),other+title($0)]})
        var result:[Int32:SearchResult]=[:]
        for node in nodes {
            if let article=found[prefix+title(node)] ?? found[other+title(node)] {result[node]=article}
        }
        return result
    }

    /// The first `limit` of `nodes` that this package has, as library hits in the same order.
    /// Each hit's count is how many links point to it.
    public func hits(_ nodes:[Int32],in source:any LibraryArticleSource,prefix:String="",limit:Int=200) async throws -> [LibraryHit] {
        var hits:[LibraryHit]=[],seen=Set<String>(),offset=0
        while hits.count<limit,offset<nodes.count,offset<limit*4 {
            try Task.checkCancellation()
            let chunk=Array(nodes[offset..<min(nodes.count,offset+max(64,limit-hits.count))])
            offset += chunk.count
            let found=try await articles(chunk,in:source,prefix:prefix)
            for node in chunk where hits.count<limit {
                guard let article=found[node],seen.insert(article.articleID.path).inserted else {continue}
                hits.append(.init(path:article.articleID.path,title:article.title.isEmpty ? readableTitle(node) : article.title,count:inDegree(node),sample:nil))
            }
        }
        return hits
    }

    /// The article a name means: a title, an archive path, or failing those the package's best title match.
    public func node(named name:String,source:any LibraryArticleSource) async throws -> Int32? {
        if let node=node(name) {return node}
        guard let found=try await LibraryEngine.resolveTitle(name,source:source) else {return nil}
        return node(found.articleID.path) ?? node(found.title)
    }

    /// "Wikipedia's link map (2026-10-01)", dated by the dump.
    public var sourceName:String {"Wikipedia's link map (\(manifest.readableDate))"}
    /// A title as readers write it: spaces, not underscores.
    public func readableTitle(_ node:Int32)->String {title(node).replacingOccurrences(of:"_",with:" ")}

    /// The articles that link to `node`, most linked-to first.
    public func backlinksByPopularity(_ node:Int32)->[Int32] {
        links(to:node).map {($0,inDegree($0))}.sorted {$0.1 != $1.1 ? $0.1>$1.1 : $0.0<$1.0}.map(\.0)
    }
    /// The articles in a category, most linked-to first.
    public func membersByPopularity(_ category:Int32)->[Int32] {
        members(category).map {($0,inDegree($0))}.sorted {$0.1 != $1.1 ? $0.1>$1.1 : $0.0<$1.0}.map(\.0)
    }
    /// The articles anywhere in a category tree, most linked-to first.
    public func membersByPopularity(of tree:CategoryTree)->[Int32] {
        let ranked:[(id:Int32,links:Int)]=members(of:tree).map {($0,inDegree($0))}
        return ranked.sorted {$0.links != $1.links ? $0.links>$1.links : $0.id<$1.id}.map(\.id)
    }
    /// Why a map can't answer subcategory questions.
    public var subcategoriesMissing:String {
        manifest.version<2 ? "This link map was built before Sematrica knew subcategories. Build it again under Packages → Installed → Link maps to add them."
                           : "This link map has no subcategories: its categorylinks table listed none."
    }
    /// Why a map can't answer questions about other languages.
    public var languagesMissing:String {
        manifest.version<2 ? "This link map was built before Sematrica knew other languages. Download the langlinks table of the same dump under Packages, then build the map again."
                           : "This link map was built without the langlinks table, so it doesn't know other languages. Download that table under Packages, then build the map again."
    }

    /// "1,234 articles link to “Paris”, according to Wikipedia's link map (2026-10-01). Most linked-to: …"
    /// - Parameter sources: `backlinksByPopularity(node)`, if already worked out.
    public func linksHereAnswer(_ node:Int32,sources known:[Int32]?=nil,list:Bool)->String {
        let sources=known ?? backlinksByPopularity(node),name=readableTitle(node)
        guard !sources.isEmpty else {return "No article links to “\(name)”, according to \(sourceName)."}
        var text="\(LibraryRun.format(sources.count)) article\(sources.count == 1 ? "" : "s") link\(sources.count == 1 ? "s" : "") to “\(name)”, according to \(sourceName)."
        if list {text += " Most linked-to first: "+sources.prefix(5).map(readableTitle).joined(separator:", ")+"."}
        return text
    }

    /// "There are 312 articles in Category:Jazz pianists (directly, not counting subcategories)…"
    /// - Parameter members: `membersByPopularity(category)`, if already worked out.
    public func categoryAnswer(_ category:Int32,members known:[Int32]?=nil,list:Bool)->String {
        let articles=known ?? membersByPopularity(category),name=categoryName(category).replacingOccurrences(of:"_",with:" ")
        var text="\(LibraryRun.format(articles.count)) article\(articles.count == 1 ? " is" : "s are") in Category:\(name), directly rather than through its subcategories, according to \(sourceName)."
        if list,!articles.isEmpty {text += " Most linked-to first: "+articles.prefix(5).map(readableTitle).joined(separator:", ")+"."}
        let inside=subcategories(category).count
        if inside>0 {text += " It also has \(LibraryRun.format(inside)) subcategor\(inside == 1 ? "y" : "ies"); ask “including subcategories” to count their articles too."}
        return text
    }

    /// "“Ray Charles” is in 23 categories: …" (maintenance categories counted, not listed).
    public func categoriesAnswer(of node:Int32)->String {
        let names=categories(of:node).map(categoryName)
        let shown=names.filter {!LinkMap.isMaintenance($0)}.map {$0.replacingOccurrences(of:"_",with:" ")}.sorted()
        let hidden=names.count-shown.count
        let title=readableTitle(node)
        guard !names.isEmpty else {return "“\(title)” isn't in any category in \(sourceName)."}
        var text="“\(title)” is in \(shown.count) categor\(shown.count == 1 ? "y" : "ies")"
        text += shown.isEmpty ? "" : ": "+shown.prefix(25).joined(separator:", ")+(shown.count>25 ? ", …" : "")
        if hidden>0 {text += " (plus \(hidden) maintenance categor\(hidden == 1 ? "y" : "ies") editors use)"}
        return text+". From \(sourceName)."
    }
}
