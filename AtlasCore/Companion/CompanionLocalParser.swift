import Foundation

/// Understands common requests instantly, without a language model:
/// "how many capital letters are in this article", "find all adjectives that
/// end with w and highlight them in green", "go to the second longest word",
/// "take me to the Early life section", "faster", "clear highlights".
///
/// It accepts a request only when every word is understood. Anything else,
/// however small, goes to the model, so the parser never guesses.
public enum CompanionLocalParser {
    public static func parse(_ request:String)->CompanionPlan? {
        let tokens=tokenize(normalize(request))
        guard !tokens.isEmpty,tokens.count<=40 else {return nil}
        var cursor=Cursor(tokens:stripPoliteness(tokens))
        guard !cursor.done else {return nil}
        if let plan=control(cursor.rest) {return plan}
        if let plan=goPlace(&cursor) {return plan}
        cursor.i=0
        return taskRequest(&cursor)
    }

    // MARK: Tokens

    struct Token:Equatable {
        let text:String
        let quoted:Bool
    }
    struct Cursor {
        var tokens:[Token]
        var i=0
        var done:Bool {i>=tokens.count}
        var rest:String {tokens[min(i,tokens.count)...].map(\.text).joined(separator:" ")}
        func peek(_ offset:Int=0)->String? {i+offset<tokens.count ? tokens[i+offset].text : nil}
        func token(_ offset:Int=0)->Token? {i+offset<tokens.count ? tokens[i+offset] : nil}
        mutating func accept(_ word:String)->Bool {
            guard peek() == word,token()?.quoted == false else {return false}
            i += 1;return true
        }
        mutating func accept(_ words:Set<String>)->String? {
            guard let word=peek(),token()?.quoted == false,words.contains(word) else {return nil}
            i += 1;return word
        }
        /// Accepts the exact sequence or nothing.
        mutating func accept(sequence words:[String])->Bool {
            for (offset,word) in words.enumerated() where peek(offset) != word || token(offset)?.quoted == true {return false}
            i += words.count;return true
        }
        mutating func skip(_ words:Set<String>) {while accept(words) != nil {}}
    }

    static func normalize(_ request:String)->String {
        var text=request.lowercased()
            .replacingOccurrences(of:"’",with:"'")
            .replacingOccurrences(of:"‘",with:"'")
        text=text.trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:".!?…")))
        return text
    }

    static func tokenize(_ text:String)->[Token] {
        var tokens:[Token]=[]
        let characters=Array(text)
        var index=0
        var word=""
        func flush() {if !word.isEmpty {tokens.append(.init(text:word,quoted:false));word=""}}
        let openers:[Character:Character]=["\"":"\"","“":"”","'":"'","«":"»","`":"`"]
        while index<characters.count {
            let character=characters[index]
            if let closer=openers[character],word.isEmpty,let end=characters[(index+1)...].firstIndex(of:closer),end>index+1,end-index<=40 {
                // An apostrophe opens a quote only at the start of a token ('a'), never inside one (don't).
                tokens.append(.init(text:String(characters[(index+1)..<end]),quoted:true))
                index=end+1;continue
            }
            if character.isLetter || character.isNumber || character == "#" {word.append(character)}
            else if character == "'" && !word.isEmpty && index+1<characters.count && characters[index+1].isLetter {word.append(character)}
            else {
                flush()
                if !character.isWhitespace && character != "-" {tokens.append(.init(text:String(character),quoted:false))}
            }
            index += 1
        }
        flush()
        // "don't" → "dont", "doesn't" → "doesnt": simpler negation matching.
        return tokens.map {$0.quoted ? $0 : .init(text:$0.text.replacingOccurrences(of:"'",with:""),quoted:false)}
    }

    static func stripPoliteness(_ tokens:[Token])->[Token] {
        var cursor=Cursor(tokens:tokens)
        var changed=true
        while changed && !cursor.done {
            changed=false
            if cursor.accept([",","please","pls","plz","kindly","hey","hi","ok","okay","so","now","atlas","spider","alright","then","just","also"]) != nil {changed=true;continue}
            for phrase in [["can","you"],["could","you"],["would","you"],["will","you"],["can","u"],["i","want","you","to"],["i","need","you","to"],["id","like","you","to"],["i","would","like","you","to"],["lets"],["let","us"],["i","want","to","see"],["i","want"]] where cursor.accept(sequence:phrase) {
                changed=true;break
            }
        }
        var rest=Array(cursor.tokens[cursor.i...])
        while let last=rest.last,!last.quoted {
            if ["please","pls","now","thanks",","].contains(last.text) {rest.removeLast();continue}
            if rest.count>=2,!rest[rest.count-2].quoted,[["thank","you"],["for","me"]].contains([rest[rest.count-2].text,last.text]) {rest.removeLast(2);continue}
            break
        }
        return rest
    }

    // MARK: Control

    static func control(_ text:String)->CompanionPlan? {
        let table:[String:CompanionStep]={
            func step(_ action:String,speed:String?=nil,rule:String?=nil)->CompanionStep {
                var value=CompanionStep(action:action);value.speed=speed;value.rule=rule;return value
            }
            var table:[String:CompanionStep]=[:]
            for phrase in ["stop","stop it","stop moving","stop now","halt","stop the spider","stop crawling","stop walking"] {table[phrase]=step("stop")}
            for phrase in ["pause","wait","hold on","freeze","hold","pause the spider","pause for a moment"] {table[phrase]=step("pause")}
            for phrase in ["resume","continue","keep going","go on","carry on","unpause","continue crawling","keep crawling","next","find next","next one","the next one","keep hunting","find the next one"] {table[phrase]=step("resume")}
            for phrase in ["faster","go faster","move faster","speed up","hurry","hurry up","quicker","be faster","walk faster","crawl faster","a bit faster","move quicker"] {table[phrase]=step("speed",speed:"faster")}
            for phrase in ["slower","slow down","go slower","move slower","move slowly","go slowly","walk slower","crawl slower","slowly","more slowly","a bit slower","walk slowly","crawl slowly"] {table[phrase]=step("speed",speed:"slower")}
            for phrase in ["normal speed","regular speed","normal pace","default speed","reset speed","usual speed"] {table[phrase]=step("speed",speed:"normal")}
            for phrase in ["clear","clear highlights","clear all highlights","clear the highlights","clear all","clear everything","clear all the highlights","remove highlights","remove all highlights","remove the highlights","remove all the highlights","unhighlight","unhighlight everything","unhighlight all","erase highlights","erase all highlights","erase the highlights","clear the page","reset highlights","remove highlighting","remove all highlighting","clear highlighting","clear the highlighting","remove all colors","clear colors"] {table[phrase]=step("clear")}
            for phrase in ["go back","back","previous article","go back to the previous article","go to the previous article"] {table[phrase]=step("back")}
            for phrase in ["wander","wander around","free crawl","crawl around","walk around","roam","roam around","crawl","explore the page","explore this page","wander the page","go explore"] {table[phrase]=step("wander")}
            for phrase in ["stay in this article","stay here","dont leave this article","do not leave this article","stay on this page","dont follow links","do not follow links","stay in the article"] {table[phrase]=step("rule",rule:"stay")}
            for phrase in ["allow links","you can follow links","follow links again","you may follow links"] {table[phrase]=step("rule",rule:"allowLinks")}
            for phrase in ["clear rules","clear restrictions","remove restrictions","reset rules","remove all restrictions","clear all rules"] {table[phrase]=step("rule",rule:"clearRules")}
            return table
        }()
        guard let step=table[text] else {return nil}
        return .init(steps:[step],local:true)
    }

    /// "take me to the Early life section", "go to the top".
    static func goPlace(_ cursor:inout Cursor)->CompanionPlan? {
        let start=cursor.i
        let verbs:[[String]]=[["go","to"],["take","me","to"],["bring","me","to"],["jump","to"],["scroll","to"],["head","to"],["walk","to"],["crawl","to"],["move","to"],["skip","to"]]
        guard verbs.contains(where:{cursor.accept(sequence:$0)}) else {cursor.i=start;return nil}
        _ = cursor.accept("the")
        let remaining=Array(cursor.tokens[cursor.i...])
        guard !remaining.isEmpty,!remaining.contains(where:\.quoted) else {cursor.i=start;return nil}
        let words=remaining.map(\.text)
        let simple:[String:String]=["top":"top","beginning":"top","start":"top","bottom":"bottom","end":"bottom","introduction":"introduction","intro":"introduction",
                                   "top of the page":"top","bottom of the page":"bottom","end of the article":"bottom","start of the article":"top","beginning of the article":"top"]
        if let place=simple[words.joined(separator:" ")] {
            var step=CompanionStep(action:"go");step.place=place
            return .init(steps:[step],local:true)
        }
        guard let last=words.last,["section","part","chapter","heading"].contains(last),words.count>=2,words.count<=8 else {cursor.i=start;return nil}
        var step=CompanionStep(action:"go");step.place=words.dropLast().joined(separator:" ")
        return .init(steps:[step],local:true)
    }

    // MARK: Find, count, list, go to

    static let countLeads:[[String]]=[["how","many"],["count"],["count","up"],["count","all"],["number","of"],["what","is","the","number","of"],["whats","the","number","of"],["total","number","of"],["tell","me","how","many"],["give","me","the","number","of"],["what","is","the","count","of"],["whats","the","count","of"]]
    static let highlightLeads:[[String]]=[["highlight"],["find"],["mark"],["show","me"],["show"],["color"],["colour"],["paint"],["underline"],["locate"],["point","out"],["select"],["spot"],["search","for"],["look","for"],["find","and","highlight"],["identify"]]
    static let listLeads:[[String]]=[["list"],["what","is"],["whats"],["what","are"],["which","is"],["which","are"],["tell","me"],["name"],["give","me"],["what","word","is"],["which","word","is"]]
    static let gotoLeads:[[String]]=[["go","to"],["walk","to"],["crawl","to"],["move","to"],["take","me","to"],["bring","me","to"],["point","to"],["point","at"],["jump","to"],["head","to"],["show","me","where"],["where","is"],["where","are"],["navigate","to"]]

    static func taskRequest(_ cursor:inout Cursor)->CompanionPlan? {
        var action:String?
        for (name,leads) in [("count",countLeads),("goto",gotoLeads),("highlight",highlightLeads),("list",listLeads)] {
            // Longest lead first so "show me where" beats "show me".
            for lead in leads.sorted(by:{$0.count>$1.count}) where cursor.accept(sequence:lead) {action=name;break}
            if action != nil {break}
        }
        guard var action else {return nil}
        if action == "goto",cursor.peek() == "is" || cursor.peek() == "are" {cursor.i += 1}
        cursor.skip(["me","all","every","each","any","of","for"])
        var query=PageQuery()
        guard target(&cursor,&query) else {return nil}
        var color:String?
        var highlightTail=false
        guard conditions(&cursor,&query,color:&color,highlight:&highlightTail) else {return nil}
        guard cursor.done else {return nil}
        if highlightTail || color != nil {
            if action == "count" || action == "list" || action == "goto" {action="highlight"}
        }
        let normalized=query.normalized()
        guard normalized.problems.isEmpty,normalized.unit != "phrase" else {return nil}
        // "Where is the longest word" goes there; "where are the verbs" shows them all.
        if action == "goto",normalized.limit != 1 && normalized.rank == nil {action="highlight"}
        var step=CompanionStep(action:action,query:normalized)
        step.color=color
        return .init(steps:[step],local:true)
    }

    static let ordinals:[String:Int]=["first":1,"second":2,"third":3,"fourth":4,"fifth":5,"sixth":6,"seventh":7,"eighth":8,"ninth":9,"tenth":10,
                                      "1st":1,"2nd":2,"3rd":3,"4th":4,"5th":5,"6th":6,"7th":7,"8th":8,"9th":9,"10th":10]
    static let orderWords:[[String]:String]=[["longest"]:"longest",["largest"]:"longest",["biggest"]:"longest",["shortest"]:"shortest",["smallest"]:"shortest",
                                              ["most","common"]:"frequent",["most","frequent"]:"frequent",["most","used"]:"frequent",["commonest"]:"frequent",["most","repeated"]:"frequent",
                                              ["least","common"]:"rare",["least","frequent"]:"rare",["rarest"]:"rare",["least","used"]:"rare"]

    static func number(_ token:String?)->Int? {
        guard let token else {return nil}
        if let value=Int(token),value>0,value<=100_000 {return value}
        return ["one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,"eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12,"fifteen":15,"twenty":20,"thirty":30,"fifty":50,"hundred":100][token]
    }

    static func acceptOrder(_ cursor:inout Cursor)->String? {
        for (words,order) in orderWords.sorted(by:{$0.key.count>$1.key.count}) where cursor.accept(sequence:words) {return order}
        return nil
    }

    /// [the] [top] [N | ordinal] [longest…] [unique] [capital] [N-letter] unit
    static func target(_ cursor:inout Cursor,_ query:inout PageQuery)->Bool {
        _ = cursor.accept("the")
        _ = cursor.accept("top")
        if let rank=cursor.peek().flatMap({ordinals[$0]}) {
            cursor.i += 1
            if let order=acceptOrder(&cursor) {query.order=order;query.rank=rank}
            else if let count=number(cursor.peek()),cursor.peek(1) != "letter" && cursor.peek(1) != "letters" {
                // "first 5 sentences"
                cursor.i += 1
                query.order=rank == 1 ? "first" : nil;query.limit=count
                if query.order == nil {return false}
            } else {query.order="first";query.rank=rank}
        } else if cursor.accept("last") {
            query.order="last"
            if let count=number(cursor.peek()) {cursor.i += 1;query.limit=count}
        } else if let count=number(cursor.peek()),cursor.peek(1) != "letter" && cursor.peek(1) != "letters" && cursor.peek(1) != "character" {
            cursor.i += 1
            guard let order=acceptOrder(&cursor) else {return false}
            query.order=order;query.limit=count
        } else if let order=acceptOrder(&cursor) {
            query.order=order
        }
        // Modifiers before the unit noun.
        var letterCase:String?
        while !cursor.done {
            if let word=cursor.accept(["unique","distinct","different"]) {_ = word;query.distinct=true;continue}
            if cursor.accept(sequence:["all","caps"]) || cursor.accept(sequence:["all","capital"]) {letterCase="uppercase";continue}
            if cursor.accept(sequence:["upper","case"]) || cursor.accept("uppercase") {letterCase="uppercase";continue}
            if cursor.accept(sequence:["lower","case"]) || cursor.accept("lowercase") {letterCase="lowercase";continue}
            if cursor.accept(["capitalized","capitalised"]) != nil {letterCase="capitalized";continue}
            if let length=number(cursor.peek()),["letter","letters","character","characters"].contains(cursor.peek(1) ?? ""),cursor.peek(2) != nil,
               unitPhrase(cursor,from:cursor.i+2) != nil {
                query.length=length;cursor.i += 2;continue
            }
            break
        }
        // The unit noun, longest phrase first ("question marks", "capital letters").
        guard let (phrase,width)=unitPhrase(cursor,from:cursor.i) else {return false}
        cursor.i += width
        query.applyUnit(phrase)
        if let letterCase {query.letterCase=PageQuery.normalizeLetterCase(letterCase,unit:query.unit)}
        return true
    }

    /// The longest token run starting at `index` that names a known unit.
    static func unitPhrase(_ cursor:Cursor,from index:Int)->(String,Int)? {
        for width in stride(from:3,through:1,by:-1) where index+width<=cursor.tokens.count {
            let slice=cursor.tokens[index..<(index+width)]
            guard !slice.contains(where:\.quoted) else {continue}
            let phrase=slice.map(\.text).joined(separator:" ")
            var probe=PageQuery();probe.applyUnit(phrase)
            guard let unit=probe.unit,PageQuery.units.contains(unit),unit != "phrase" else {continue}
            if width == 1 && ambiguousUnits.contains(phrase) {continue}
            return (phrase,width)
        }
        return nil
    }

    /// Common English words that name a unit only in context ("text", "places", "times").
    static let ambiguousUnits:Set<String>=["text","string","strings","title","titles","figure","figures","entity","entities","block","blocks","anchor","anchors",
                                          "blank","blanks","token","tokens","place","places","country","countries","city","cities","human","humans","vocabulary",
                                          "name","times","mention","mentions","occurrence","occurrences","caps"]

    static let fillers:Set<String>=["are","is","there","in","on","this","the","article","page","text","does","do","have","has","contain","contains","you","see","can","find",
                                    "exist","appear","here","within","whole","entire","of","current","document","total","altogether","overall","in","it","we","i","now","inside","used","written"]

    /// Conditions after the unit, plus scope words, a highlight tail and color.
    static func conditions(_ cursor:inout Cursor,_ query:inout PageQuery,color:inout String?,highlight:inout Bool)->Bool {
        var progress=true
        while !cursor.done && progress {
            progress=false
            let before=cursor.i
            // A trailing color phrase consumes the rest of the request.
            if let word=cursor.peek(),!(cursor.token()?.quoted ?? true),
               ["in","with","using","as","colored","coloured","to"].contains(word) || HighlightStyle.parse(word) != nil || ["half","alternating","alternate","rainbow","gradient"].contains(word) {
                let rest=cursor.rest
                if HighlightStyle.recognizes(rest) {color=rest;cursor.i=cursor.tokens.count;progress=true;continue}
            }
            if cursor.accept([",","and","but","&","then","also"]) != nil {
                // "and highlight them (in green)"
                if cursor.accept(["highlight","mark","color","colour","paint","show","underline","shade"]) != nil {
                    highlight=true
                    cursor.skip(["them","it","those","these","all","each","one","ones","up","for","me"])
                }
                progress=true;continue
            }
            if cursor.accept(["highlighted","marked","shown","underlined","painted"]) != nil {highlight=true;progress=true;continue}
            // "are there in the Career section", "is in this article"
            let lead=cursor.i
            _ = cursor.accept(["are","is","appear","appears","exist","exists"])
            _ = cursor.accept("there")
            if scope(&cursor) {progress=true;continue}
            if section(&cursor,&query) {progress=true;continue}
            cursor.i=lead
            _ = cursor.accept(["that","which","who","whose","where"])
            _ = cursor.accept(["are","is","have","has","having"]) // "that are longer than", "that have 5 letters"
            if length(&cursor,&query) {progress=true;continue}
            if textCondition(&cursor,&query) {progress=true;continue}
            if cursor.i != before {
                // Only relative words were consumed; they must lead to a condition.
                cursor.i=before
            }
            // Trailing count phrasing: "are there", "does this article have", "in total".
            let remaining=cursor.tokens[cursor.i...]
            if !remaining.isEmpty,remaining.allSatisfy({!$0.quoted && fillers.contains($0.text)}) {cursor.i=cursor.tokens.count;progress=true;continue}
        }
        return cursor.done
    }

    static func scope(_ cursor:inout Cursor)->Bool {
        let start=cursor.i
        if cursor.accept("here") || cursor.accept(sequence:["in","here"]) {return true}
        guard cursor.accept(["in","on","of","from","across","throughout"]) != nil else {return false}
        _ = cursor.accept(["this","the","that","whole","entire","current"])
        _ = cursor.accept(["whole","entire"])
        if cursor.accept(["article","page","text","document","wikipedia","entry","one"]) != nil {return true}
        cursor.i=start
        return false
    }

    static func section(_ cursor:inout Cursor,_ query:inout PageQuery)->Bool {
        let start=cursor.i
        var excluded=false
        if cursor.accept(sequence:["not","in"]) || cursor.accept(sequence:["except","in"]) || cursor.accept(sequence:["outside","of"]) || cursor.accept("outside") ||
            cursor.accept(["excluding","avoiding","avoid","skipping","skip","ignoring","ignore"]) != nil {excluded=true}
        else if cursor.accept(["in","within","under","inside","from"]) == nil {return false}
        _ = cursor.accept("the")
        if !excluded,cursor.accept(["introduction","intro","lead","opening"]) != nil {
            _ = cursor.accept(["section","part","paragraph","paragraphs"])
            query.section="introduction";return true
        }
        var name:[String]=[]
        while let token=cursor.token(),name.count<7 {
            if !token.quoted && ["section","part","chapter","heading"].contains(token.text) {
                guard !name.isEmpty else {break}
                cursor.i += 1
                let value=name.joined(separator:" ")
                if excluded {query.excludeSections=(query.excludeSections ?? [])+[value]} else {query.section=value}
                return true
            }
            name.append(token.text);cursor.i += 1
        }
        if excluded && name.count == 1,["introduction","intro","lead"].contains(name[0]) {
            query.excludeSections=(query.excludeSections ?? [])+["introduction"];return true
        }
        cursor.i=start;return false
    }

    static func length(_ cursor:inout Cursor,_ query:inout PageQuery)->Bool {
        let start=cursor.i
        func unitWord()->String? {cursor.accept(["letters","letter","characters","character","chars","words","word"])}
        func apply(min:Int?,max:Int?,exact:Int?,unit:String?)->Bool {
            let words=unit == "words" || unit == "word"
            if words {
                guard ["sentence","paragraph","heading","link"].contains(query.unit ?? "") || query.unit == nil else {return false}
                if let exact {query.minWords=exact;query.maxWords=exact}
                if let min {query.minWords=min}
                if let max {query.maxWords=max}
            } else {
                if let exact {query.length=exact}
                if let min {query.minLength=min}
                if let max {query.maxLength=max}
            }
            return true
        }
        _ = cursor.accept(["with","of","having","that"])
        _ = cursor.accept(["are","have","has"])
        if cursor.accept(sequence:["longer","than"]) || cursor.accept(sequence:["more","than"]) || cursor.accept(sequence:["over"]) || cursor.accept(sequence:["greater","than"]) {
            if let value=number(cursor.peek()) {cursor.i += 1;let unit=unitWord();_ = cursor.accept("long");if apply(min:value+1,max:nil,exact:nil,unit:unit) {return true}}
        } else if cursor.accept(sequence:["shorter","than"]) || cursor.accept(sequence:["fewer","than"]) || cursor.accept(sequence:["less","than"]) || cursor.accept(sequence:["under"]) {
            if let value=number(cursor.peek()),value>1 {cursor.i += 1;let unit=unitWord();_ = cursor.accept("long");if apply(min:nil,max:value-1,exact:nil,unit:unit) {return true}}
        } else if cursor.accept(sequence:["at","least"]) {
            if let value=number(cursor.peek()) {cursor.i += 1;let unit=unitWord();_ = cursor.accept("long");if apply(min:value,max:nil,exact:nil,unit:unit) {return true}}
        } else if cursor.accept(sequence:["at","most"]) || cursor.accept(sequence:["no","more","than"]) || cursor.accept(sequence:["up","to"]) {
            if let value=number(cursor.peek()) {cursor.i += 1;let unit=unitWord();_ = cursor.accept("long");if apply(min:nil,max:value,exact:nil,unit:unit) {return true}}
        } else if cursor.accept("between") {
            if let low=number(cursor.peek()),cursor.peek(1) == "and",let high=number(cursor.peek(2)),low<=high {
                cursor.i += 3;let unit=unitWord();_ = cursor.accept("long");if apply(min:low,max:high,exact:nil,unit:unit) {return true}
            }
        } else {
            _ = cursor.accept("exactly")
            if let value=number(cursor.peek()),let unit=cursor.peek(1),["letters","letter","characters","character","chars","words","word"].contains(unit) {
                cursor.i += 2;_ = cursor.accept("long")
                if apply(min:nil,max:nil,exact:value,unit:unit) {return true}
            }
        }
        cursor.i=start;return false
    }

    static func textCondition(_ cursor:inout Cursor,_ query:inout PageQuery)->Bool {
        let start=cursor.i
        let negated=cursor.accept(sequence:["dont"]) || cursor.accept(sequence:["do","not"]) || cursor.accept(sequence:["doesnt"]) || cursor.accept(sequence:["does","not"]) || cursor.accept("not")
        var kind:String?
        if cursor.accept(["start","starts","starting","begin","begins","beginning"]) != nil {
            guard cursor.accept("with") else {cursor.i=start;return false}
            kind="start"
        } else if cursor.accept(["end","ends","ending","finish","finishes","finishing"]) != nil {
            guard cursor.accept(["with","in"]) != nil else {cursor.i=start;return false}
            kind="end"
        } else if cursor.accept(["contain","contains","containing","include","includes","including"]) != nil {
            kind="contain"
        } else if !negated,cursor.accept("without") {
            if let value=spec(&cursor) {query.notContains=value;return true}
            cursor.i=start;return false
        } else if !negated,cursor.peek() == "with" {
            let letterNext=cursor.peek(1) == "the" && (cursor.peek(2) == "letter" || cursor.peek(2) == "letters")
            let quotedNext=cursor.token(1)?.quoted == true
            if letterNext || quotedNext || cursor.peek(1) == "letter" {cursor.i += 1;kind="contain"}
        }
        guard let kind,let value=spec(&cursor) else {cursor.i=start;return false}
        switch (kind,negated) {
        case ("start",false): query.startsWith=value
        case ("start",true): query.notStartsWith=value
        case ("end",false): query.endsWith=value
        case ("end",true): query.notEndsWith=value
        case ("contain",false): query.contains=value
        default: query.notContains=value
        }
        return true
    }

    /// A letter or spelling: a, the letter a, "ab", a or e.
    static func spec(_ cursor:inout Cursor)->String? {
        let keywords:Set<String>=["and","or","but","that","which","in","with","start","starts","starting","end","ends","ending","contain","contains","containing","longer","shorter","more","less","fewer","at","highlight","mark","color","colour","the","not","dont","without"]
        func value()->String? {
            if let token=cursor.token(),token.quoted {cursor.i += 1;return token.text}
            _ = cursor.accept("the")
            _ = cursor.accept(["letter","letters","character","characters","prefix","suffix","string","sequence","syllable"])
            if (cursor.peek() == "an" || cursor.peek() == "a"),let next=cursor.peek(1),next.count == 1,next.first?.isLetter == true,cursor.token(1)?.quoted == false {cursor.i += 1}
            if let token=cursor.token(),token.quoted {cursor.i += 1;return token.text}
            guard let word=cursor.peek(),cursor.token()?.quoted == false,word.count<=12,word.allSatisfy({$0.isLetter || $0.isNumber}) else {return nil}
            // A keyword is a value only when it is a single letter ("start with a").
            if keywords.contains(word) && word.count>1 {return nil}
            cursor.i += 1;return word
        }
        guard var result=value() else {return nil}
        while cursor.peek() == "or",let next=cursor.peek(1),next.count<=3 || cursor.token(1)?.quoted == true,!["end","ending","ends","start","starts"].contains(next) {
            cursor.i += 1
            guard let more=value() else {cursor.i -= 1;break}
            result += "|"+more
        }
        return result
    }
}
