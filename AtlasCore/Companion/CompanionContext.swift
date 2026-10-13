import Foundation

/// Article text prepared for a limited-context model: either the whole
/// article, or the opening plus the passages most relevant to a question.
public struct CompanionContext:Sendable {
    public let text:String
    public let blockIDs:Set<String>
    public let included:Int
    public let total:Int
    /// True only if every rendered text block is included in full and the page map is complete.
    public let complete:Bool
    public let coverageNote:String

    private static let commonTerms:Set<String>=["a","about","all","an","and","are","article","at","be","can","could","do","does","for","from","have","here","how","i","in","is","it","me","my","of","on","or","page","please","show","tell","that","the","them","there","these","this","to","what","which","who","why","with","word","words","you"]
    static func terms(_ question:String)->[String] {
        var seen=Set<String>()
        return Array(question.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init)
            .filter {$0.count>2 && !commonTerms.contains($0) && seen.insert($0).inserted}.prefix(32))
    }
    static func render(_ block:CrawlerPageItem,text:String?=nil)->String {
        let section=block.section?.trimmingCharacters(in:.whitespacesAndNewlines)
        return "[\(block.id)]\(section.map {" § \($0)"} ?? "")\n\(text ?? block.text)"
    }
    static func note(included:Int,total:Int,complete:Bool,truncated:Bool)->String {
        if complete {return "The full rendered article text is present (\(total) text blocks)."}
        let suffix=truncated ? " The page map reached its extraction limit, so even local whole-page counts may be incomplete." : " Sematrica's page tools still inspect the whole page; use the read action to read everything."
        return "Selected excerpts from \(included) of \(total) text blocks; this is not the full article.\(suffix)"
    }

    /// The opening blocks of the article, which stay the same for every message on a page.
    public static func opening(page:CrawlerPageMap,limit:Int=1500)->Self {
        var used=0,rendered:[String]=[],ids:Set<String>=[]
        for block in page.blocks where !block.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let text=render(block,text:String(block.text.prefix(max(0,limit-used))))
            guard used<limit else {break}
            rendered.append(text);ids.insert(block.id);used += text.count+2
        }
        let complete=ids.count == page.blocks.count && page.isTextComplete && !page.blocks.contains {$0.text.count>limit}
        return .init(text:rendered.joined(separator:"\n\n"),blockIDs:ids,included:ids.count,total:page.blocks.count,complete:complete,coverageNote:"")
    }

    public static func make(page:CrawlerPageMap,question:String,limit:Int=9000,excluding:Set<String>=[])->Self {
        let budget=max(800,limit)
        let textTruncated = !page.isTextComplete
        let candidates=page.blocks.enumerated().filter {!excluding.contains($0.element.id)}
        let all=page.blocks.map {render($0)}
        let allText=candidates.map {all[$0.offset]}.joined(separator:"\n\n")
        if allText.count<=budget {
            let complete = !textTruncated && excluding.isEmpty
            let note=note(included:page.blocks.count,total:page.blocks.count,complete:!textTruncated,truncated:textTruncated)
            return .init(text:allText,blockIDs:Set(candidates.map {$0.element.id}),included:candidates.count,total:page.blocks.count,complete:complete,coverageNote:note)
        }
        let query=terms(question)
        var documentFrequency:[String:Int]=[:]
        for term in query {
            var count=0
            for block in page.blocks where block.text.localizedCaseInsensitiveContains(term) || (block.section ?? "").localizedCaseInsensitiveContains(term) {count += 1}
            documentFrequency[term]=count
        }
        var scored:[(index:Int,score:Double)]=[]
        for (index,block) in candidates {
            let body=block.text.lowercased()
            let heading=(block.section ?? "").lowercased()
            var relevance=0.0
            for term in query {
                let count=documentFrequency[term] ?? 0
                let documentWeight=log(Double(page.blocks.count+1)/Double(count+1))+1
                let bodyMatches=body.components(separatedBy:term).count-1
                let headingMatches=heading.contains(term) ? 3:0
                relevance += documentWeight*Double(min(3,bodyMatches)+headingMatches)
            }
            scored.append((index,relevance))
        }
        scored.sort {left,right in left.score == right.score ? left.index<right.index : left.score>right.score}
        var selected=Set<Int>(),used=0,rendered:[Int:String]=[:]
        func add(_ index:Int,maxCharacters:Int) {
            guard index>=0,index<page.blocks.count,!selected.contains(index),!excluding.contains(page.blocks[index].id),used<budget else {return}
            let available=min(maxCharacters,budget-used)
            let full=all[index]
            guard available>80 else {return}
            let excerpt:String
            if full.count<=available {excerpt=full}
            else {
                let block=page.blocks[index]
                let term=query.first {block.text.localizedCaseInsensitiveContains($0)}
                let text=block.text
                var start=0
                if let term,let range=text.range(of:term,options:.caseInsensitive) {
                    start=max(0,text.distance(from:text.startIndex,to:range.lowerBound)-available/4)
                }
                let from=text.index(text.startIndex,offsetBy:min(start,text.count))
                let snippet=String(text[from...].prefix(max(1,available-80)))
                excerpt=render(block,text:(start>0 ? "…" : "")+snippet+(start+snippet.count<text.count ? "…" : ""))
            }
            guard excerpt.count<=budget-used else {return}
            selected.insert(index);rendered[index]=excerpt;used += excerpt.count+2
        }
        if excluding.isEmpty {for index in 0..<min(2,page.blocks.count) {add(index,maxCharacters:min(1400,budget/5))}}
        let evidenceBudget=Int(Double(budget)*0.72)
        for (index,score) in scored where score>0 && used<evidenceBudget {add(index,maxCharacters:min(1600,budget/4))}
        // Spread remaining excerpts through the article when the question is broad.
        let stride=max(1,page.blocks.count/max(1,(budget-used)/650))
        for index in Swift.stride(from:0,to:page.blocks.count,by:stride) {add(index,maxCharacters:1000)}
        for (index,_) in scored {add(index,maxCharacters:900)}
        let indices=selected.sorted()
        let note=note(included:indices.count,total:page.blocks.count,complete:false,truncated:textTruncated)
        return .init(text:indices.compactMap {rendered[$0]}.joined(separator:"\n\n"),blockIDs:Set(indices.map {page.blocks[$0].id}),included:indices.count,total:page.blocks.count,complete:false,coverageNote:note)
    }

    /// Partition the entire rendered page for sequential reading by a limited-context model.
    /// A long individual block can appear in more than one chunk with the same source ID.
    public static func chunks(page:CrawlerPageMap,limit:Int=7000)->[Self] {
        let budget=max(800,limit),total=page.blocks.count
        let textTruncated = !page.isTextComplete
        guard !page.blocks.isEmpty else {
            let note=note(included:0,total:0,complete:!textTruncated,truncated:textTruncated)
            return [.init(text:note,blockIDs:[],included:0,total:0,complete:!textTruncated,coverageNote:note)]
        }
        var groups:[[(String,String)]]=[],current:[(String,String)]=[],used=0
        func flush() {if !current.isEmpty {groups.append(current);current=[];used=0}}
        for block in page.blocks {
            let prefix="[\(block.id)]\(block.section.map {" § \($0)"} ?? "")\n"
            let maxBody=max(200,budget-prefix.count-20)
            var remainder=block.text[...]
            repeat {
                let part=String(remainder.prefix(maxBody))
                let rendered=prefix+part+(remainder.count>part.count ? "… [continues]" : "")
                if used+rendered.count+2>budget {flush()}
                current.append((block.id,rendered));used += rendered.count+2
                remainder=remainder.dropFirst(part.count)
            } while !remainder.isEmpty
        }
        flush()
        return groups.map {group in
            let ids=Set(group.map(\.0)),complete=groups.count == 1 && !textTruncated
            let note=note(included:ids.count,total:total,complete:complete,truncated:textTruncated)
            return .init(text:note+"\n\n"+group.map(\.1).joined(separator:"\n\n"),blockIDs:ids,included:ids.count,total:total,complete:complete,coverageNote:note)
        }
    }
}
