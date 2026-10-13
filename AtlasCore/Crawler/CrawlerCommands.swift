import Foundation
import NaturalLanguage

public struct CrawlerDirective: Codable, Equatable, Sendable {
    public let action:String
    public let value:String?
    public init(_ action:String,_ value:String?=nil) {self.action=action;self.value=value}
    public var isValid:Bool {
        switch action {
        case "stop","pause","resume","faster","slower","normalSpeed","stay","allowLinks","clearRules","clearHighlights","status":return value == nil
        case "direction":return ["left","right","up","down"].contains(value ?? "")
        case "words":return ["adjectives","nouns","verbs","adverbs"].contains(value ?? "")
        case "wordPrefix":return !(value?.isEmpty ?? true) && (value?.count ?? 0)<=40 && value!.unicodeScalars.allSatisfy {CharacterSet.letters.contains($0)}
        case "wordMeaning","go","avoid","mission":return !(value?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true) && (value?.count ?? 0)<=300
        default:return false
        }
    }
    public static func interpreted(json:String) throws -> Self {
        let decoded=try JSONDecoder().decode(Self.self,from:Data(json.utf8))
        if decoded.isValid {return decoded}
        // Some local models return a literal highlight instruction instead of
        // the action name. Accept only rules our deterministic parser validates.
        if decoded.action == "highlight",let value=decoded.value,value.count<=300,
           let rule=local("highlight "+value),["words","wordPrefix","wordMeaning"].contains(rule.action),rule.isValid {return rule}
        throw DecodingError.dataCorrupted(.init(codingPath:[],debugDescription:"Unsupported crawler instruction"))
    }
    public static func local(_ text:String)->Self? {
        var raw=text.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:".!?"))
        if raw.lowercased().hasPrefix("please ") {raw=String(raw.dropFirst(7))}
        let input=raw.lowercased()
        let aliases:[String:String] = ["stop":"stop","stop now":"stop","stop moving":"pause","pause":"pause","wait":"pause","freeze":"pause","resume":"resume","continue":"resume","continue hunting":"resume","keep going":"resume","faster":"faster","move faster":"faster","go faster":"faster","speed up":"faster","slower":"slower","move slowly":"slower","go slowly":"slower","slow down":"slower","move slower":"slower","normal speed":"normalSpeed","stay here":"stay","stay in this article":"stay","don't leave this article":"stay","do not leave this article":"stay","avoid links":"stay","don't follow links":"stay","allow links":"allowLinks","follow links again":"allowLinks","clear rules":"clearRules","clear restrictions":"clearRules","clear highlights":"clearHighlights","stop highlighting":"clearHighlights","status":"status","what are you doing":"status"]
        if let action=aliases[input] {return .init(action)}
        for direction in ["left","right","up","down"] where [direction,"go "+direction,"move "+direction,"head "+direction].contains(input) {return .init("direction",direction)}
        for kind in ["adjectives","nouns","verbs","adverbs"] {
            if ["find "+kind,"find only "+kind,"highlight "+kind,"highlight only "+kind,"find only "+kind+" and highlight them","find "+kind+" and highlight them"].contains(input) {return .init("words",kind)}
        }
        for prefix in ["highlight words starting with ","highlight all words starting with ","highlight words that start with ","highlight all the words that start with "] where input.hasPrefix(prefix) {
            return .init("wordPrefix",String(raw.dropFirst(prefix.count)).trimmingCharacters(in:CharacterSet(charactersIn:" \"'")))
        }
        if ["highlight words of french origin","highlight words with french origin","highlight french-origin words"].contains(input) {return .init("wordMeaning","words of French origin")}
        for prefix in ["don't go to ","do not go to ","avoid ","don't visit "] where input.hasPrefix(prefix) {
            return .init("avoid",String(raw.dropFirst(prefix.count)).trimmingCharacters(in:.whitespacesAndNewlines))
        }
        for prefix in ["go to ","head to ","follow "] where input.hasPrefix(prefix) {return .init("go",String(raw.dropFirst(prefix.count)))}
        return nil
    }
}
public struct CrawlerTravelRules:Sendable {
    public var allowLinks=true
    public var blocked:[String]=[]
    public init() {}
    public mutating func avoid(_ text:String) {
        let clean=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if !blocked.contains(where:{$0.caseInsensitiveCompare(clean) == .orderedSame}),blocked.count<20 {blocked.append(clean)}
    }
    public func permits(_ text:String)->Bool {
        let normalized=text.removingPercentEncoding?.replacingOccurrences(of:"_",with:" ") ?? text
        return !blocked.contains {normalized.range(of:$0,options:[.caseInsensitive,.diacriticInsensitive]) != nil}
    }
    public var summary:String {"Article travel: \(allowLinks ? "allowed" : "stay in current article"). Avoid destinations: \(blocked.isEmpty ? "none" : blocked.joined(separator:", "))."}
}
public struct CrawlerWordHighlight:Codable,Sendable {
    public let id:String
    public let start:Int
    public let end:Int
}
/// Tags only contiguous text already returned by local perception. No article provider or DOM access.
public enum CrawlerWordClassifier {
    public static func highlights(in observation:CrawlerObservation,kind:String)->[CrawlerWordHighlight] {
        let tags:[String:NLTag] = ["adjectives":.adjective,"nouns":.noun,"verbs":.verb,"adverbs":.adverb]
        guard let wanted=tags[kind] else {return []}
        var result:[CrawlerWordHighlight]=[]
        let groups=Dictionary(grouping:observation.terrain.filter {!$0.text.isEmpty},by:\.group)
        func classify(_ run:[CrawlerTerrain]) {
            let text=run.map(\.text).joined()
            guard !text.isEmpty else {return}
            let tagger=NLTagger(tagSchemes:[.lexicalClass]);tagger.string=text
            tagger.enumerateTags(in:text.startIndex..<text.endIndex,unit:.word,scheme:.lexicalClass,options:[.omitWhitespace,.omitPunctuation]) {tag,range in
                guard tag == wanted else {return true}
                let ns=NSRange(range,in:text);var offset=0
                for fragment in run {
                    let size=fragment.text.utf16.count
                    let start=max(ns.location-offset,0),end=min(ns.location+ns.length-offset,size)
                    if start<end {result.append(.init(id:fragment.id,start:start,end:end))}
                    offset += size
                }
                return result.count<100
            }
        }
        for group in groups.values {
            var run:[CrawlerTerrain]=[]
            for fragment in group.sorted(by:{$0.order<$1.order}) {
                if let last=run.last,fragment.order != last.order+last.text.utf16.count {classify(run);run=[]}
                run.append(fragment)
            }
            classify(run)
        }
        return Array(result.prefix(100))
    }
}

public struct CrawlerWordCandidate:Sendable {
    public let text:String
    public let marks:[CrawlerWordHighlight]
}

public enum CrawlerWordSelection {
    /// Tokenize only contiguous locally observed text, retaining exact bridge ranges.
    public static func candidates(in observation:CrawlerObservation)->[CrawlerWordCandidate] {
        var result:[CrawlerWordCandidate]=[]
        func tokenize(_ run:[CrawlerTerrain]) {
            let text=run.map(\.text).joined()
            let tokenizer=NLTokenizer(unit:.word);tokenizer.string=text
            tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) {range,_ in
                guard result.count<64 else {return false}
                let ns=NSRange(range,in:text);var offset=0;var marks:[CrawlerWordHighlight]=[]
                for fragment in run {
                    let size=fragment.text.utf16.count
                    let start=max(0,ns.location-offset),end=min(size,ns.location+ns.length-offset)
                    if start<end {marks.append(.init(id:fragment.id,start:start,end:end))}
                    offset += size
                }
                result.append(.init(text:String(text[range]),marks:marks));return true
            }
        }
        for group in Dictionary(grouping:observation.terrain.filter {!$0.text.isEmpty},by:\.group).values.sorted(by: {($0.first?.order ?? 0)<($1.first?.order ?? 0)}) {
            var run:[CrawlerTerrain]=[]
            for fragment in group.sorted(by:{$0.order<$1.order}) {
                if let last=run.last,fragment.order != last.order+last.text.utf16.count {tokenize(run);run=[]}
                run.append(fragment)
            }
            tokenize(run)
        }
        return result
    }
    public static func prefixMarks(_ prefix:String,in observation:CrawlerObservation)->[CrawlerWordHighlight] {
        candidates(in:observation).filter {$0.text.lowercased().hasPrefix(prefix.lowercased())}.flatMap(\.marks)
    }
    public static func modelMarks(json:String,candidates:[CrawlerWordCandidate]) throws -> [CrawlerWordHighlight] {
        struct Reply:Decodable {let matches:[Int]}
        let reply=try JSONDecoder().decode(Reply.self,from:Data(json.utf8))
        guard reply.matches.count<=64,reply.matches.allSatisfy({candidates.indices.contains($0)}) else {
            throw DecodingError.dataCorrupted(.init(codingPath:[],debugDescription:"Model selected an unobserved word"))
        }
        return Set(reply.matches).sorted().flatMap {candidates[$0].marks}
    }
}
