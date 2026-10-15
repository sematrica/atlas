import Foundation
import NaturalLanguage

/// One thing a query found: a text range inside a block, or a whole link/image element.
public struct PageMatch:Codable,Sendable,Equatable {
    /// Set for text matches (block ID plus UTF-16 offsets).
    public let range:CrawlerPageRange?
    /// Set for link, image and heading-element matches.
    public let elementID:String?
    public let text:String
    /// The containing block or element. Exact geometry is resolved in the page when needed.
    public let rect:TerrainRect
    /// Reading order across the article.
    public let order:Int
    public init(range:CrawlerPageRange?,elementID:String?,text:String,rect:TerrainRect,order:Int) {
        self.range=range;self.elementID=elementID;self.text=text;self.rect=rect;self.order=order
    }
}
public struct WordFrequency:Codable,Sendable,Equatable {
    public let text:String
    public let count:Int
}
public struct PageQueryResult:Sendable {
    public let query:PageQuery
    /// Matches after ordering and limits, in reading order.
    public let matches:[PageMatch]
    /// Number of matching items before order/rank/limit were applied.
    public let total:Int
    /// False when the page map was cut off, so totals may be low.
    public let complete:Bool
    /// Spelling frequencies for frequent/rare queries, most relevant first.
    public let frequencies:[WordFrequency]
    /// The requested section, when no heading matched it.
    public let unknownSection:String?
    public let sections:[String]
    public var count:Int {query.order == nil ? total : matches.count}
}

/// Executes `PageQuery` deterministically over the complete rendered page map.
public enum PageQueryEngine {
    /// - Parameter allowed: when set, only these spellings (lowercased) can match. Used after a
    ///   semantic judgment so ordering ("the longest word about music") applies to approved words.
    public static func run(_ raw:PageQuery,on page:CrawlerPageMap,allowed:Set<String>?=nil)->PageQueryResult {
        var query=raw.normalized()
        let sections=sectionNames(page)
        let unit=query.unit ?? "word"
        let complete=["link","image"].contains(unit) ? page.isMediaComplete : page.isTextComplete

        var blocks=page.blocks
        if let section=query.section {
            let selected=blocks.filter {matchesSection($0.section,section)}
            guard !selected.isEmpty else {
                return .init(query:query,matches:[],total:0,complete:complete,frequencies:[],unknownSection:section,sections:sections)
            }
            blocks=selected
            // Describe the section with the article's own spelling ("career" → "Career").
            if section != "introduction",let path=selected.first?.section {
                let parts=path.components(separatedBy:" › ").map {$0.trimmingCharacters(in:.whitespaces)}
                if let name=parts.first(where:{$0.range(of:section,options:[.caseInsensitive,.diacriticInsensitive]) != nil}) {query.section=name}
            }
        }
        if let excluded=query.excludeSections {
            blocks=blocks.filter {block in !excluded.contains {matchesSection(block.section,$0)}}
        }

        var candidates:[PageMatch]
        switch unit {
        case "letter","character": candidates=characters(blocks,query:query)
        case "word": candidates=words(blocks,query:query)
        case "name": candidates=names(blocks,query:query)
        case "number": candidates=numbers(blocks)
        case "sentence": candidates=sentences(blocks.filter {!$0.isHeading})
        case "paragraph": candidates=wholeBlocks(blocks.filter {$0.tag == nil ? !$0.isHeading : ["p","blockquote","dd"].contains($0.tag!)})
        case "heading": candidates=wholeBlocks(blocks.filter(\.isHeading))
        case "link":
            candidates=elements(page.links,query:query)
            if let title=query.linksTo {
                let pointing=Set(page.links.filter {ArticleLinks.points($0.href,to:title)}.map(\.id))
                candidates=candidates.filter {$0.elementID.map(pointing.contains) ?? false}
            }
        case "image": candidates=elements(page.images,query:query)
        case "phrase": candidates=phrases(blocks,query:query)
        default: candidates=[]
        }

        var matches=candidates.filter {passes($0.text,query:query)}
        if let exclude=query.exclude {
            let skipped=Set(exclude.map {fold($0,query:query)})
            matches=matches.filter {!skipped.contains(fold($0.text,query:query))}
        }
        if let allowed {matches=matches.filter {allowed.contains($0.text.lowercased())}}
        let rankingByLength=query.order == "longest" || query.order == "shortest"
        if query.distinct == true || (rankingByLength && query.isWordLike && query.distinct != false) {
            var seen=Set<String>()
            matches=matches.filter {seen.insert(fold($0.text,query:query)).inserted}
        }
        let total=matches.count
        var frequencies:[WordFrequency]=[]
        switch query.order {
        case "first"?:
            matches=pick(matches,query:query)
        case "last"?:
            matches=Array(pick(matches.reversed(),query:query).reversed())
        case "longest"?,"shortest"?:
            let longest=query.order == "longest"
            let measured=matches.map {(match:$0,length:measure($0.text,query:query),spelling:fold($0.text,query:query))}
            let sorted=measured.sorted {a,b in
                if a.length != b.length {return longest ? a.length>b.length : a.length<b.length}
                if a.spelling != b.spelling {return a.spelling<b.spelling}
                return a.match.order<b.match.order
            }
            matches=pick(sorted.map(\.match),query:query).sorted {$0.order<$1.order}
        case "frequent"?,"rare"?:
            var counts:[String:Int]=[:],first:[String:Int]=[:],display:[String:String]=[:]
            for (index,match) in matches.enumerated() {
                let key=fold(match.text,query:query)
                counts[key,default:0] += 1
                if first[key] == nil {first[key]=index;display[key]=match.text}
            }
            let frequent=query.order == "frequent"
            let ranked=counts.keys.sorted {a,b in
                if counts[a]! != counts[b]! {return frequent ? counts[a]!>counts[b]! : counts[a]!<counts[b]!}
                return first[a]!<first[b]!
            }
            frequencies=ranked.prefix(200).map {WordFrequency(text:display[$0] ?? $0,count:counts[$0]!)}
            let chosen:[String]
            if let rank=query.rank {chosen=rank<=ranked.count ? [ranked[rank-1]] : []}
            else {chosen=Array(ranked.prefix(query.limit ?? 1))}
            let keep=Set(chosen)
            matches=matches.filter {keep.contains(fold($0.text,query:query))}
            frequencies=chosen.map {WordFrequency(text:display[$0] ?? $0,count:counts[$0]!)}+frequencies.filter {!keep.contains(fold($0.text,query:query))}
        default:
            if let limit=query.limit {matches=Array(matches.prefix(limit))}
        }
        return .init(query:query,matches:matches,total:total,complete:complete,frequencies:frequencies,unknownSection:nil,sections:sections)
    }

    private static func pick<S:Sequence>(_ matches:S,query:PageQuery)->[PageMatch] where S.Element == PageMatch {
        let all=Array(matches)
        if let rank=query.rank {return rank<=all.count ? [all[rank-1]] : []}
        return Array(all.prefix(query.limit ?? all.count))
    }

    // MARK: Sections

    /// Distinct section names in reading order ("introduction" first).
    public static func sectionNames(_ page:CrawlerPageMap)->[String] {
        var seen=Set<String>(),names:[String]=[]
        for block in page.blocks {
            let name=block.section ?? "introduction"
            if seen.insert(name).inserted {names.append(name)}
        }
        return names
    }
    /// Section paths look like "Career › Early recordings". A request matches
    /// any component, so "Career" includes its subsections.
    static func matchesSection(_ blockSection:String?,_ requested:String)->Bool {
        let name=blockSection ?? "introduction"
        let wanted=requested.trimmingCharacters(in:.whitespacesAndNewlines)
        if wanted.caseInsensitiveCompare("introduction") == .orderedSame {return name == "introduction"}
        return name.range(of:wanted,options:[.caseInsensitive,.diacriticInsensitive]) != nil
    }

    // MARK: Units

    static func characters(_ blocks:[CrawlerPageItem],query:PageQuery)->[PageMatch] {
        var result:[PageMatch]=[]
        var order=0
        let letterOnly=query.unit == "letter"
        let literal=query.equals
        for block in blocks {
            var offset=0
            for character in block.text {
                let width=character.utf16.count
                defer {offset += width;order += 1}
                if letterOnly && !character.isLetter {continue}
                if let literal {
                    let same=query.caseSensitive == true ? String(character) == literal : String(character).caseInsensitiveCompare(literal) == .orderedSame
                    if !same {continue}
                }
                if let characterClass=query.characterClass,!belongs(character,to:characterClass) {continue}
                switch query.letterCase {
                case "uppercase"?,"capitalized"?: if !character.isUppercase {continue}
                case "lowercase"?: if !character.isLowercase {continue}
                default: break
                }
                result.append(.init(range:.init(id:block.id,start:offset,end:offset+width,text:String(character)),elementID:nil,text:String(character),rect:block.rect,order:order))
            }
        }
        return result
    }

    static func belongs(_ character:Character,to characterClass:String)->Bool {
        switch characterClass {
        case "letter": return character.isLetter
        case "digit": return character.unicodeScalars.allSatisfy {CharacterSet.decimalDigits.contains($0)}
        case "punctuation": return character.isPunctuation
        case "symbol": return character.isSymbol
        case "space": return character == " " || character == "\u{00A0}"
        case "whitespace": return character.isWhitespace
        case "vowel","consonant":
            guard character.isLetter else {return false}
            let base=String(character).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            guard base.count == 1,let scalar=base.unicodeScalars.first,("a"..."z").contains(scalar) else {return false}
            let vowel="aeiou".contains(base)
            return characterClass == "vowel" ? vowel : !vowel
        case "quote": return "\"'“”‘’«»„‚‹›".contains(character)
        case "bracket": return "()[]{}⟨⟩".contains(character)
        case "dash": return "-‐‑‒–—―−".contains(character)
        default: return false
        }
    }

    static let lexicalTags:[String:NLTag]=[
        "noun":.noun,"verb":.verb,"adjective":.adjective,"adverb":.adverb,"pronoun":.pronoun,"determiner":.determiner,
        "preposition":.preposition,"conjunction":.conjunction,"interjection":.interjection
    ]

    static func words(_ blocks:[CrawlerPageItem],query:PageQuery)->[PageMatch] {
        var result:[PageMatch]=[]
        let wanted=query.partOfSpeech.flatMap {lexicalTags[$0]}
        var order=0
        for block in blocks {
            let text=block.text
            guard !text.isEmpty else {continue}
            let tokenizer=NLTokenizer(unit:.word)
            tokenizer.string=text
            var tagger:NLTagger?
            if wanted != nil {
                let value=NLTagger(tagSchemes:[.lexicalClass])
                value.string=text
                tagger=value
            }
            tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) {range,_ in
                let word=String(text[range])
                guard word.contains(where:\.isLetter) else {return true}
                order += 1
                if let wanted,let tagger {
                    let tag=tagger.tag(at:range.lowerBound,unit:.word,scheme:.lexicalClass).0
                    guard tag == wanted else {return true}
                }
                if let letterCase=query.letterCase,!wordCase(word,letterCase) {return true}
                let ns=NSRange(range,in:text)
                result.append(.init(range:.init(id:block.id,start:ns.location,end:ns.location+ns.length,text:word),elementID:nil,text:word,rect:block.rect,order:order))
                return true
            }
        }
        return result
    }

    static func wordCase(_ word:String,_ letterCase:String)->Bool {
        let letters=word.filter(\.isLetter)
        guard let first=letters.first else {return false}
        switch letterCase {
        case "uppercase": return letters.count>=2 && letters.allSatisfy {$0.isUppercase}
        case "lowercase": return letters.allSatisfy {$0.isLowercase}
        case "capitalized": return first.isUppercase
        default: return true
        }
    }

    static func names(_ blocks:[CrawlerPageItem],query:PageQuery)->[PageMatch] {
        var result:[PageMatch]=[]
        let wanted:Set<NLTag>
        switch query.entity {
        case "person"?: wanted=[.personalName]
        case "place"?: wanted=[.placeName]
        case "organization"?: wanted=[.organizationName]
        default: wanted=[.personalName,.placeName,.organizationName]
        }
        var order=0
        for block in blocks where !block.text.isEmpty {
            let text=block.text
            let tagger=NLTagger(tagSchemes:[.nameType])
            tagger.string=text
            tagger.enumerateTags(in:text.startIndex..<text.endIndex,unit:.word,scheme:.nameType,options:[.omitWhitespace,.omitPunctuation,.joinNames]) {tag,range in
                order += 1
                guard let tag,wanted.contains(tag) else {return true}
                let value=String(text[range])
                if let letterCase=query.letterCase,!wordCase(value,letterCase) {return true}
                let ns=NSRange(range,in:text)
                result.append(.init(range:.init(id:block.id,start:ns.location,end:ns.location+ns.length,text:value),elementID:nil,text:value,rect:block.rect,order:order))
                return true
            }
        }
        return result
    }

    static func numbers(_ blocks:[CrawlerPageItem])->[PageMatch] {
        guard let pattern=try? NSRegularExpression(pattern:#"\p{Nd}+(?:[.,]\p{Nd}+)*"#) else {return []}
        var result:[PageMatch]=[]
        var order=0
        for block in blocks {
            let text=block.text as NSString
            for match in pattern.matches(in:block.text,range:NSRange(location:0,length:text.length)) {
                order += 1
                let value=text.substring(with:match.range)
                result.append(.init(range:.init(id:block.id,start:match.range.location,end:match.range.location+match.range.length,text:value),elementID:nil,text:value,rect:block.rect,order:order))
            }
        }
        return result
    }

    static func sentences(_ blocks:[CrawlerPageItem])->[PageMatch] {
        var result:[PageMatch]=[]
        var order=0
        for block in blocks where !block.text.isEmpty {
            let text=block.text
            let tokenizer=NLTokenizer(unit:.sentence)
            tokenizer.string=text
            tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) {range,_ in
                var end=range.upperBound
                while end>range.lowerBound,text[text.index(before:end)].isWhitespace {end=text.index(before:end)}
                let trimmed=range.lowerBound..<end
                let value=String(text[trimmed])
                guard value.contains(where:\.isLetter) else {return true}
                order += 1
                let ns=NSRange(trimmed,in:text)
                result.append(.init(range:.init(id:block.id,start:ns.location,end:ns.location+ns.length,text:value),elementID:nil,text:value,rect:block.rect,order:order))
                return true
            }
        }
        return result
    }

    static func wholeBlocks(_ blocks:[CrawlerPageItem])->[PageMatch] {
        blocks.enumerated().compactMap {index,block in
            let trimmed=block.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !trimmed.isEmpty else {return nil}
            return .init(range:.init(id:block.id,start:0,end:block.text.utf16.count,text:block.text),elementID:nil,text:trimmed,rect:block.rect,order:index)
        }
    }

    static func elements(_ items:[CrawlerPageItem],query:PageQuery)->[PageMatch] {
        items.enumerated().compactMap {index,item in
            if let section=query.section,!matchesSection(item.section,section) {return nil}
            if let excluded=query.excludeSections,excluded.contains(where:{matchesSection(item.section,$0)}) {return nil}
            let text=item.text.trimmingCharacters(in:.whitespacesAndNewlines)
            return .init(range:nil,elementID:item.id,text:text,rect:item.rect,order:index)
        }
    }

    static func phrases(_ blocks:[CrawlerPageItem],query:PageQuery)->[PageMatch] {
        guard let needle=query.equals,!needle.isEmpty else {return []}
        var options:String.CompareOptions=[]
        if query.caseSensitive != true {options.insert(.caseInsensitive)}
        var result:[PageMatch]=[]
        var order=0
        for block in blocks {
            let text=block.text
            var search=text.startIndex..<text.endIndex
            while let range=text.range(of:needle,options:options,range:search) {
                order += 1
                let ns=NSRange(range,in:text)
                let value=String(text[range])
                result.append(.init(range:.init(id:block.id,start:ns.location,end:ns.location+ns.length,text:value),elementID:nil,text:value,rect:block.rect,order:order))
                search=range.upperBound..<text.endIndex
                if range.isEmpty {break}
            }
        }
        return result
    }

    // MARK: Conditions

    static func fold(_ value:String,query:PageQuery)->String {
        query.caseSensitive == true ? value : value.lowercased()
    }

    static func alternatives(_ value:String)->[String] {
        let parts=value.split(separator:"|").map(String.init).filter {!$0.isEmpty}
        return parts.isEmpty ? [value] : parts
    }

    static func passes(_ text:String,query:PageQuery)->Bool {
        var options:String.CompareOptions=[]
        if query.caseSensitive != true {options.insert(.caseInsensitive)}
        // Character units apply their literal while collecting; text conditions describe words and longer units.
        let textUnit = !query.isCharacterUnit
        if textUnit {
            if let value=query.startsWith,!alternatives(value).contains(where:{text.range(of:$0,options:options.union(.anchored)) != nil}) {return false}
            if let value=query.endsWith,!alternatives(value).contains(where:{text.range(of:$0,options:options.union([.anchored,.backwards])) != nil}) {return false}
            if let value=query.contains,!alternatives(value).contains(where:{text.range(of:$0,options:options) != nil}) {return false}
            if query.unit != "phrase",let value=query.equals,!alternatives(value).contains(where:{text.compare($0,options:options) == .orderedSame}) {return false}
            if let value=query.notStartsWith,alternatives(value).contains(where:{text.range(of:$0,options:options.union(.anchored)) != nil}) {return false}
            if let value=query.notEndsWith,alternatives(value).contains(where:{text.range(of:$0,options:options.union([.anchored,.backwards])) != nil}) {return false}
            if let value=query.notContains,alternatives(value).contains(where:{text.range(of:$0,options:options) != nil}) {return false}
        }
        let length=measure(text,query:query)
        if let exact=query.length,length != exact {return false}
        if let minimum=query.minLength,length<minimum {return false}
        if let maximum=query.maxLength,length>maximum {return false}
        if query.minWords != nil || query.maxWords != nil {
            let words=text.split(whereSeparator:{$0.isWhitespace}).filter {$0.contains(where:\.isLetter)}.count
            if let minimum=query.minWords,words<minimum {return false}
            if let maximum=query.maxWords,words>maximum {return false}
        }
        return true
    }

    /// Letters for words and names; characters for everything else.
    static func measure(_ text:String,query:PageQuery)->Int {
        query.isWordLike ? text.filter(\.isLetter).count : text.count
    }
}

// MARK: - Places

extension PageQueryEngine {
    /// Resolves a place the user named ("Early life", "the References section",
    /// "top", a link's text) to a location on the current page.
    public static func locate(_ rawPlace:String,on page:CrawlerPageMap)->PageMatch? {
        let place=PageQuery.normalizeSection(rawPlace)
        let lowered=place.lowercased()
        if ["top","beginning","start","top of the page","start of the article","the top","title"].contains(lowered),let first=page.blocks.first(where:{!$0.text.isEmpty}) {
            return wholeBlocks([first]).first
        }
        if ["bottom","end","end of the article","bottom of the page","the end","the bottom"].contains(lowered),let last=page.blocks.last(where:{!$0.text.isEmpty}) {
            return wholeBlocks([last]).first
        }
        if lowered == "introduction",let first=page.blocks.first(where:{($0.section ?? "introduction") == "introduction" && !$0.isHeading && !$0.text.isEmpty}) {
            return wholeBlocks([first]).first
        }
        let headings=page.blocks.filter(\.isHeading)
        if let heading=bestMatch(place,in:headings,text:{$0.text}) {return wholeBlocks([heading]).first}
        // Older page maps have no tags; fall back to the first block of a matching section.
        if let block=page.blocks.first(where:{($0.section ?? "").split(separator:"›").last.map {String($0).trimmingCharacters(in:.whitespaces).caseInsensitiveCompare(place) == .orderedSame} ?? false}) {
            return wholeBlocks([block]).first
        }
        if let link=findLink(place,on:page) {
            return .init(range:nil,elementID:link.id,text:link.text,rect:link.rect,order:0)
        }
        var phrase=PageQuery(unit:"phrase");phrase.equals=place
        return run(phrase,on:page).matches.first
    }

    /// A link by its visible text or its destination's title.
    public static func findLink(_ rawName:String,on page:CrawlerPageMap)->CrawlerPageItem? {
        let name=PageQuery.stripQuotes(rawName.trimmingCharacters(in:.whitespacesAndNewlines))
        guard !name.isEmpty else {return nil}
        func destination(_ item:CrawlerPageItem)->String {
            let href=item.href ?? ""
            let last=href.split(separator:"/").last.map(String.init) ?? href
            return (last.removingPercentEncoding ?? last).replacingOccurrences(of:"_",with:" ")
        }
        let candidates=page.links.filter {!$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !($0.href ?? "").hasPrefix("#")}
        return bestMatch(name,in:candidates,text:{$0.text}) ?? bestMatch(name,in:candidates,text:destination)
    }

    static func bestMatch<T>(_ name:String,in items:[T],text:(T)->String)->T? {
        let wanted=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !wanted.isEmpty else {return nil}
        func clean(_ value:String)->String {value.trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))}
        if let exact=items.first(where:{clean(text($0)).compare(wanted,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame}) {return exact}
        if let prefix=items.first(where:{clean(text($0)).range(of:wanted,options:[.caseInsensitive,.diacriticInsensitive,.anchored]) != nil}) {return prefix}
        if let contained=items.first(where:{clean(text($0)).range(of:wanted,options:[.caseInsensitive,.diacriticInsensitive]) != nil}) {return contained}
        return nil
    }
}
