import Foundation

/// Builds a page map straight from an article's HTML, without rendering it,
/// so `PageQueryEngine` can count and find in any article of the library.
///
/// It follows the rules of the live page map (DocumentGeometryScript.pageMap):
/// text is grouped by its nearest block (p, li, td, th, figcaption, pre, dt, dd,
/// blockquote, h1–h6), sections come from h2–h6 headings, links and images keep
/// the section of the block that holds them, and script, style, noscript, nav,
/// footer and hidden elements are skipped. Styles aren't evaluated, so text that
/// only a stylesheet hides is still counted. Line breaks become "\n".
public enum ArticlePageMap {
    /// The live map's text cap, in characters.
    public static let textLimit=2_000_000
    /// The live map's cap on links and images together.
    public static let mediaLimit=30_000

    public static func make(_ article:Article)->CrawlerPageMap {
        make(html:article.html,document:article.id.path)
    }

    public static func make(html:String,document:String)->CrawlerPageMap {
        var parser=Parser(bytes:Array(html.utf8))
        parser.run()
        let zero=TerrainRect(x:0,y:0,width:0,height:0)
        let blocks=parser.groups.map {CrawlerPageItem(id:$0.id,text:$0.text,rect:zero,section:$0.section,tag:$0.tag)}
        return CrawlerPageMap(document:document,revision:0,textRevision:0,viewport:zero,documentWidth:0,documentHeight:0,
                              blocks:blocks,links:parser.links,images:parser.images,
                              truncated:parser.textTruncated || parser.mediaTruncated,
                              textTruncated:parser.textTruncated,mediaTruncated:parser.mediaTruncated)
    }

    static let blockTags:Set<String>=["p","li","td","th","figcaption","pre","dt","dd","blockquote","h1","h2","h3","h4","h5","h6"]
    static let skippedTags:Set<String>=["script","style","noscript","nav","footer","head","template","svg","math","title"]
    static let rawTextTags:Set<String>=["script","style","textarea","title","template"]
    static let voidTags:Set<String>=["area","base","br","col","embed","hr","img","input","link","meta","param","source","track","wbr"]

    struct Element {
        let tag:String
        let serial:Int
        let skipped:Bool
        /// Heading level 2–6, or nil.
        let headingLevel:Int?
    }
    struct Group {
        let id:String
        var text:String
        var section:String
        let tag:String
        /// A heading's own text is placed in its section once the heading closes.
        let heading:Int?
    }
    struct OpenLink {
        let serial:Int
        let href:String
        let section:String
        var text:String
        let index:Int
    }

    struct Parser {
        let bytes:[UInt8]
        var i=0
        var stack:[Element]=[]
        var serial=0
        var groups:[Group]=[]
        var lastBlock:Int?
        var part=0
        var sections:[(level:Int,title:String)]=[]
        var headingText:[Int:String]=[:]
        var headingGroups:[Int:[Int]]=[:]
        var blockSections:[Int:String]=[:]
        var links:[CrawlerPageItem]=[]
        var images:[CrawlerPageItem]=[]
        var openLinks:[OpenLink]=[]
        var size=0
        var textTruncated=false
        var mediaTruncated=false

        init(bytes:[UInt8]) {self.bytes=bytes}

        var currentSection:String {sections.isEmpty ? "introduction" : sections.map(\.title).joined(separator:" › ")}
        var skipping:Bool {stack.last?.skipped ?? false}

        mutating func run() {
            var textStart=0
            while i<bytes.count {
                guard bytes[i] == UInt8(ascii:"<") else {i += 1;continue}
                let next=i+1<bytes.count ? bytes[i+1] : 0
                let isTag=Self.isLetter(next) || next == UInt8(ascii:"/") || next == UInt8(ascii:"!") || next == UInt8(ascii:"?")
                guard isTag else {i += 1;continue}
                if textStart<i {text(String(decoding:bytes[textStart..<i],as:UTF8.self))}
                tag()
                textStart=i
            }
            if textStart<bytes.count {text(String(decoding:bytes[textStart..<bytes.count],as:UTF8.self))}
            while let element=stack.last {close(element)}
        }

        // MARK: Tags

        mutating func tag() {
            // Comments, doctype and processing instructions carry no text.
            if match("<!--") {
                i=find("-->",from:i+4).map {$0+3} ?? bytes.count;return
            }
            if bytes[i+1] == UInt8(ascii:"!") || bytes[i+1] == UInt8(ascii:"?") {
                i=find(">",from:i).map {$0+1} ?? bytes.count;return
            }
            let closing=bytes[i+1] == UInt8(ascii:"/")
            var j=i+(closing ? 2 : 1)
            let nameStart=j
            while j<bytes.count,!Self.isSpace(bytes[j]),bytes[j] != UInt8(ascii:">"),bytes[j] != UInt8(ascii:"/") {j += 1}
            let name=String(decoding:bytes[nameStart..<j],as:UTF8.self).lowercased()
            // Attributes run to the first ">" outside quotes.
            var quote:UInt8?
            let attributesStart=j
            while j<bytes.count {
                let b=bytes[j]
                if let q=quote {if b == q {quote=nil}}
                else if b == UInt8(ascii:"\"") || b == UInt8(ascii:"'") {quote=b}
                else if b == UInt8(ascii:">") {break}
                j += 1
            }
            let attributes=String(decoding:bytes[attributesStart..<min(j,bytes.count)],as:UTF8.self)
            i=min(j+1,bytes.count)
            if closing {closeTag(name);return}
            let selfClosing=attributes.hasSuffix("/")
            openTag(name,attributes:attributes,selfClosing:selfClosing)
            // Script and style bodies are raw text: skip to their closing tag.
            if ArticlePageMap.rawTextTags.contains(name),!selfClosing {
                let end=findClosing(name,from:i) ?? bytes.count
                i=end
            }
        }

        mutating func openTag(_ name:String,attributes:String,selfClosing:Bool) {
            if name == "br" {
                if !skipping {text("\n",forced:true)}
                return
            }
            if name == "img" {
                guard !skipping else {return}
                if let item=mediaItem(alt:Self.attribute("alt",in:attributes) ?? "",href:nil,tag:"img") {images.append(item)}
                return
            }
            if ArticlePageMap.voidTags.contains(name) || selfClosing {return}
            impliedClose(before:name)
            let hidden=Self.hasAttribute("hidden",in:attributes) || Self.attribute("style",in:attributes).map(Self.hidesElement) == true
            let skipped=skipping || ArticlePageMap.skippedTags.contains(name) || hidden
            serial += 1
            var level:Int?
            if name.count == 2,name.hasPrefix("h"),let n=Int(name.dropFirst()),(2...6).contains(n) {level=n}
            stack.append(Element(tag:name,serial:serial,skipped:skipped,headingLevel:level))
            if name == "a",!skipped,let href=Self.attribute("href",in:attributes) {
                openLinks.append(OpenLink(serial:serial,href:Self.decodeEntities(href),section:holderSection(),text:"",index:-1))
            }
        }

        mutating func closeTag(_ name:String) {
            guard let index=stack.lastIndex(where:{$0.tag == name}) else {return}
            // Elements left open inside it close with it.
            while stack.count>index {close(stack[stack.count-1])}
        }

        mutating func close(_ element:Element) {
            stack.removeLast()
            if element.tag == "a",let index=openLinks.lastIndex(where:{$0.serial == element.serial}) {
                let link=openLinks.remove(at:index)
                if let item=mediaItem(alt:link.text,href:link.href,tag:"a",section:link.section) {links.append(item)}
            }
            if let level=element.headingLevel,!element.skipped {
                let title=String((headingText[element.serial] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).prefix(160))
                while let last=sections.last,last.level>=level {sections.removeLast()}
                sections.append((level,title))
                let section=currentSection
                blockSections[element.serial]=section
                for group in headingGroups[element.serial] ?? [] {groups[group].section=section}
                headingText[element.serial]=nil;headingGroups[element.serial]=nil
            }
        }

        /// HTML lets some end tags be left out; Wikipedia's markup closes them, but be tolerant.
        mutating func impliedClose(before name:String) {
            func closeNearest(_ tag:String,within boundaries:Set<String>) {
                for element in stack.reversed() {
                    if element.tag == tag {closeTag(tag);return}
                    if boundaries.contains(element.tag) {return}
                }
            }
            switch name {
            case "p","ul","ol","table","div","h1","h2","h3","h4","h5","h6","pre","blockquote","dl":
                closeNearest("p",within:["div","td","th","li","blockquote","section","body","dd","figcaption"])
            case "li": closeNearest("li",within:["ul","ol"])
            case "dt","dd": closeNearest("dd",within:["dl"]);closeNearest("dt",within:["dl"])
            case "td","th": closeNearest("td",within:["tr","table"]);closeNearest("th",within:["tr","table"])
            case "tr": closeNearest("tr",within:["table","tbody","thead","tfoot"])
            default: break
            }
        }

        // MARK: Text

        mutating func text(_ raw:String,forced:Bool=false) {
            guard !skipping,!textTruncated else {return}
            let value=forced ? raw : Self.decodeEntities(raw)
            guard !value.isEmpty else {return}
            let block=stack.last(where:{ArticlePageMap.blockTags.contains($0.tag)})
            // Whitespace between blocks has no rendered box; inside a block it separates words.
            if block == nil,value.allSatisfy(\.isWhitespace) {return}
            if size+value.count>ArticlePageMap.textLimit {textTruncated=true;return}
            size += value.count
            for index in openLinks.indices {openLinks[index].text += value}
            if let heading=stack.last(where:{$0.headingLevel != nil}) {headingText[heading.serial,default:""] += value}
            let holder=block ?? stack.last
            let base=holder?.serial ?? 0
            if lastBlock != base {part += 1;lastBlock=base}
            if blockSections[base] == nil {blockSections[base]=currentSection}
            let id="b\(base):block-\(part)"
            if let last=groups.indices.last,groups[last].id == id {
                groups[last].text += value
            } else {
                let heading=holder?.headingLevel
                groups.append(Group(id:id,text:value,section:blockSections[base] ?? currentSection,tag:holder?.tag ?? "body",heading:heading))
                if let holder,heading != nil {headingGroups[holder.serial,default:[]].append(groups.count-1)}
            }
        }

        func holderSection()->String {
            if let block=stack.last(where:{ArticlePageMap.blockTags.contains($0.tag)}),let section=blockSections[block.serial] {return section}
            return currentSection
        }

        mutating func mediaItem(alt:String,href:String?,tag:String,section:String?=nil)->CrawlerPageItem? {
            guard links.count+images.count<ArticlePageMap.mediaLimit else {mediaTruncated=true;return nil}
            serial += 1
            let zero=TerrainRect(x:0,y:0,width:0,height:0)
            let text=tag == "img" ? Self.decodeEntities(alt) : alt
            return CrawlerPageItem(id:"\(tag)\(serial)",text:text,rect:zero,href:href,section:section ?? holderSection(),tag:tag)
        }

        // MARK: Scanning helpers

        func match(_ literal:String)->Bool {
            let pattern=Array(literal.utf8)
            guard i+pattern.count<=bytes.count else {return false}
            return Array(bytes[i..<i+pattern.count]) == pattern
        }
        func find(_ literal:String,from start:Int)->Int? {
            let pattern=Array(literal.utf8)
            guard !pattern.isEmpty,start<bytes.count else {return nil}
            var k=start
            while k+pattern.count<=bytes.count {
                if bytes[k] == pattern[0],Array(bytes[k..<k+pattern.count]) == pattern {return k}
                k += 1
            }
            return nil
        }
        /// The start of `</name` (case-insensitive) at or after `start`.
        func findClosing(_ name:String,from start:Int)->Int? {
            let pattern=Array(("</"+name).utf8)
            var k=start
            while k+pattern.count<=bytes.count {
                if bytes[k] == UInt8(ascii:"<"),k+1<bytes.count,bytes[k+1] == UInt8(ascii:"/") {
                    var same=true
                    for (offset,b) in pattern.enumerated() where Self.lower(bytes[k+offset]) != b {same=false;break}
                    if same {return k}
                }
                k += 1
            }
            return nil
        }
        static func isLetter(_ b:UInt8)->Bool {(b >= 65 && b <= 90) || (b >= 97 && b <= 122)}
        static func isSpace(_ b:UInt8)->Bool {b == 32 || b == 9 || b == 10 || b == 13 || b == 12}
        static func lower(_ b:UInt8)->UInt8 {b >= 65 && b <= 90 ? b+32 : b}

        static func attribute(_ name:String,in attributes:String)->String? {
            // name="value", name='value' or name=value
            let scalars=Array(attributes.unicodeScalars)
            var k=0
            while k<scalars.count {
                while k<scalars.count,CharacterSet.whitespacesAndNewlines.contains(scalars[k]) || scalars[k] == "/" {k += 1}
                let start=k
                while k<scalars.count,scalars[k] != "=",!CharacterSet.whitespacesAndNewlines.contains(scalars[k]),scalars[k] != "/" {k += 1}
                let key=String(String.UnicodeScalarView(scalars[start..<k])).lowercased()
                while k<scalars.count,CharacterSet.whitespacesAndNewlines.contains(scalars[k]) {k += 1}
                guard k<scalars.count,scalars[k] == "=" else {
                    if key.isEmpty {k += 1}
                    continue
                }
                k += 1
                while k<scalars.count,CharacterSet.whitespacesAndNewlines.contains(scalars[k]) {k += 1}
                var value=""
                if k<scalars.count,scalars[k] == "\"" || scalars[k] == "'" {
                    let q=scalars[k];k += 1;let s=k
                    while k<scalars.count,scalars[k] != q {k += 1}
                    value=String(String.UnicodeScalarView(scalars[s..<k]));k += 1
                } else {
                    let s=k
                    while k<scalars.count,!CharacterSet.whitespacesAndNewlines.contains(scalars[k]) {k += 1}
                    value=String(String.UnicodeScalarView(scalars[s..<k]))
                }
                if key == name {return value}
            }
            return nil
        }
        static func hasAttribute(_ name:String,in attributes:String)->Bool {
            attributes.lowercased().split(whereSeparator:{$0.isWhitespace || $0 == "/"}).contains {
                let key=$0.split(separator:"=",maxSplits:1).first.map(String.init) ?? ""
                return key == name
            }
        }
        static func hidesElement(_ style:String)->Bool {
            let compact=style.lowercased().replacingOccurrences(of:" ",with:"")
            return compact.contains("display:none") || compact.contains("visibility:hidden")
        }

        static let entities:[String:String]=[
            "amp":"&","lt":"<","gt":">","quot":"\"","apos":"'","nbsp":"\u{00A0}","ndash":"–","mdash":"—","hellip":"…",
            "lsquo":"‘","rsquo":"’","ldquo":"“","rdquo":"”","laquo":"«","raquo":"»","copy":"©","reg":"®","trade":"™",
            "deg":"°","times":"×","divide":"÷","minus":"−","middot":"·","bull":"•","plusmn":"±","para":"¶","sect":"§",
            "thinsp":"\u{2009}","ensp":"\u{2002}","emsp":"\u{2003}","zwj":"\u{200D}","zwnj":"\u{200C}","shy":"\u{00AD}",
            "prime":"′","Prime":"″","frac12":"½","frac14":"¼","frac34":"¾","sup2":"²","sup3":"³","micro":"µ","euro":"€","pound":"£","yen":"¥","cent":"¢"
        ]
        static func decodeEntities(_ text:String)->String {
            guard text.contains("&") else {return text}
            var result=""
            result.reserveCapacity(text.count)
            var index=text.startIndex
            while index<text.endIndex {
                let character=text[index]
                guard character == "&",let semicolon=text[index...].prefix(32).firstIndex(of:";") else {
                    result.append(character);index=text.index(after:index);continue
                }
                let name=String(text[text.index(after:index)..<semicolon])
                var decoded:String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {decoded=UInt32(name.dropFirst(2),radix:16).flatMap(UnicodeScalar.init).map {String(Character($0))}}
                else if name.hasPrefix("#") {decoded=UInt32(name.dropFirst()).flatMap(UnicodeScalar.init).map {String(Character($0))}}
                else {decoded=entities[name]}
                if let decoded {result += decoded;index=text.index(after:semicolon)}
                else {result.append(character);index=text.index(after:index)}
            }
            return result
        }
    }
}

/// Resolving article links to archive paths.
public enum ArticleLinks {
    /// The archive path an href in the article at `articlePath` points to, or nil for
    /// in-page anchors and anything outside the offline library.
    public static func path(_ href:String,from articlePath:String)->String? {
        let trimmed=href.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty,!trimmed.hasPrefix("#"),let base=OfflineURL.make(host:"library",path:articlePath),
              let url=URL(string:trimmed,relativeTo:base)?.absoluteURL else {return nil}
        let path:String?
        if url.scheme == "atlas",url.host == "library" {path=String(url.path.dropFirst())}
        else {path=OfflineURL.localWikipediaPath(url)}
        guard let path,!path.isEmpty,path != articlePath,!path.hasPrefix("-/"),!path.hasPrefix("I/") else {return nil}
        return path
    }

    /// The title a link's destination names: "./Atlantic_Records#History" → "Atlantic Records".
    public static func destinationTitle(_ href:String)->String {
        var value=href
        if let hash=value.firstIndex(of:"#") {value=String(value[..<hash])}
        if let query=value.firstIndex(of:"?") {value=String(value[..<query])}
        let last=value.split(separator:"/").last.map(String.init) ?? value
        return (last.removingPercentEncoding ?? last).replacingOccurrences(of:"_",with:" ")
    }

    /// Whether a link points to the article titled `title` (ignoring case, accents and underscores).
    public static func points(_ href:String?,to title:String)->Bool {
        guard let href,!href.hasPrefix("#") else {return false}
        let wanted=PageQuery.stripQuotes(title.trimmingCharacters(in:.whitespacesAndNewlines)).replacingOccurrences(of:"_",with:" ")
        guard !wanted.isEmpty else {return false}
        return destinationTitle(href).compare(wanted,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame
    }
}
