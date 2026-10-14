import Foundation

/// One action for Atlas and its spider. The model fills in only the fields the
/// action needs; everything is validated and executed by Atlas itself.
public struct CompanionStep:Codable,Sendable,Equatable {
    /// count, list, highlight, goto, clear, show, go, follow, open, back,
    /// hunt, explore, wander, pause, resume, stop, speed, rule, read, library
    public var action:String
    /// What to look for (count, list, highlight, goto).
    public var query:PageQuery?
    /// Where the spider may plant its feet while walking (goto, show), e.g. only nouns.
    public var footing:PageQuery?
    /// The user's color words, copied verbatim ("half green half yellow").
    public var color:String?
    /// Paint everything at once instead of touring it.
    public var instant:Bool?
    /// Which highlights to clear: a color or a description. Empty clears all.
    public var target:String?
    /// A saved result ID ("r2") to reuse instead of a new query.
    public var result:String?
    /// A section heading, link text or "top"/"bottom" (go, follow, rule avoid).
    public var place:String?
    /// An article title (open).
    public var title:String?
    /// An exact phrase to hunt for using only local perception (hunt).
    public var phrase:String?
    /// A topic to explore across articles (explore).
    public var topic:String?
    /// faster, slower, normal
    public var speed:String?
    /// avoid, stay, allowLinks, clearRules
    public var rule:String?
    /// The question to answer after reading the whole article (read).
    public var question:String?
    /// library: which articles. library (all), linked (linked from this article; `place` = a section),
    /// titles (the articles in `titles`), search (the best results for `topic`).
    public var scope:String?
    /// library: articles (how many contain a match), total (all matches added up), list (which articles).
    public var measure:String?
    /// library: article titles for the titles scope.
    public var titles:[String]?
    /// library: at most this many articles from the scope.
    public var articles:Int?
    /// open: an exact archive path. Set by Sematrica itself (a library result's Open button);
    /// it isn't in the model's schema.
    public var path:String?

    public init(action:String,query:PageQuery?=nil) {self.action=action;self.query=query}

    enum CodingKeys:String,CodingKey {
        case action,query,footing,color,instant,target,result,place,title,phrase,topic,speed,rule,question
        case scope,measure,titles,articles,path
    }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        action=c.lenientString(.action) ?? ""
        query=try? c.decodeIfPresent(PageQuery.self,forKey:.query)
        footing=try? c.decodeIfPresent(PageQuery.self,forKey:.footing)
        color=c.lenientString(.color)
        instant=c.lenientBool(.instant)
        target=c.lenientString(.target)
        result=c.lenientString(.result)
        place=c.lenientString(.place)
        title=c.lenientString(.title)
        phrase=c.lenientString(.phrase,trim:false)
        topic=c.lenientString(.topic)
        speed=c.lenientString(.speed)
        rule=c.lenientString(.rule)
        question=c.lenientString(.question)
        scope=c.lenientString(.scope)
        measure=c.lenientString(.measure)
        titles=c.lenientStrings(.titles)
        articles=c.lenientInt(.articles)
        path=c.lenientString(.path)
    }

    public static let actions=["count","list","highlight","goto","clear","show","go","follow","open","back","hunt","explore","wander","pause","resume","stop","speed","rule","read","library"]
    static let queryActions:Set<String>=["count","list","highlight","goto"]

    /// Maps synonyms a model might use onto the executable action names.
    public func normalized()->CompanionStep? {
        var step=self
        let raw=PageQuery.fold(action).replacingOccurrences(of:" ",with:"")
        step.query=query?.normalized()
        step.footing=footing?.normalized()
        if let value=speed {step.speed=Self.normalizeSpeed(value)}
        if let value=rule {step.rule=Self.normalizeRule(value)}
        if let value=scope {step.scope=Self.normalizeScope(value)}
        if let value=measure {step.measure=Self.normalizeMeasure(value)}
        switch raw {
        case "count","howmany","measure","tally","number": step.action="count"
        case "list","tell","name","enumerate","what","which","show list","answerwith": step.action="list"
        case "highlight","find","mark","color","colour","paint","underline","select","search","locate","showall","markall","highlightall":
            step.action="highlight"
        case "goto","walkto","moveto","crawlto","pointto","pointat","point","take","takemeto","bring","approach","seek":
            step.action=step.query == nil && step.result == nil ? "go" : "goto"
        case "go","navigate","scroll","scrollto","jump","jumpto","move","walk","visit":
            step.action=step.query != nil ? "goto" : "go"
        case "show","demonstrate","replay","again","prove","repeat","showagain","showresult":
            step.action=step.result == nil && step.query != nil ? "highlight" : "show"
        case "clear","remove","unhighlight","erase","reset","clearhighlights","delete","removehighlights": step.action="clear"
        case "follow","followlink","openlink","click","clicklink","enter": step.action="follow"
        case "open","openarticle","search_article","searcharticle","lookup","read article","openpage","findarticle","gotoarticle": step.action="open"
        case "back","goback","previous","return": step.action="back"
        case "hunt","huntphrase","findphrase","searchphrase","exacthunt","stringhunt": step.action="hunt"
        case "explore","semantic","semantichunt","topichunt","research","investigate","mission": step.action="explore"
        case "wander","freecrawl","crawl","roam","explorepage","walkaround","crawlaround","play": step.action="wander"
        case "pause","wait","hold","freeze": step.action="pause"
        case "resume","continue","keepgoing","goon","unpause": step.action="resume"
        case "stop","halt","quit","end","cancel": step.action="stop"
        case "speed","faster","slower","speedup","slowdown","normalspeed":
            step.action="speed"
            if step.speed == nil {step.speed=["faster","speedup"].contains(raw) ? "faster" : ["slower","slowdown"].contains(raw) ? "slower" : raw == "normalspeed" ? "normal" : nil}
        case "rule","avoid","stay","stayinarticle","allowlinks","clearrules","restrict":
            step.action="rule"
            if step.rule == nil {step.rule=Self.normalizeRule(raw)}
        case "read","summarize","summarise","summary","opinion","review","readarticle","readall","analyze","analyse": step.action="read"
        case "library","acrosslibrary","allarticles","searchlibrary","libraryquery","countarticles","acrossarticles","articles","everyarticle","otherarticles":
            step.action="library"
            if step.scope == nil && step.titles?.isEmpty == false {step.scope="titles"}
        case "answer","reply","say","chat","respond","talk","none","noop","nothing","": return nil
        default: step.action=raw
        }
        // A count or list over a scope of articles is a library question.
        if ["count","list"].contains(step.action),step.scope != nil || step.titles?.isEmpty == false || step.measure != nil {
            if step.measure == nil {step.measure=step.action == "list" ? "list" : "articles"}
            step.action="library"
        }
        return step
    }

    static func normalizeSpeed(_ raw:String)->String {
        switch PageQuery.fold(raw) {
        case "faster","fast","quicker","quick","speed up","up","increase","hurry": return "faster"
        case "slower","slow","slow down","down","decrease","gentle","calm": return "slower"
        case "normal","default","regular","reset","normal speed","medium": return "normal"
        default: return PageQuery.fold(raw)
        }
    }
    static func normalizeScope(_ raw:String)->String {
        switch PageQuery.fold(raw).replacingOccurrences(of:" ",with:"") {
        case "library","all","allarticles","everything","everywhere","wholelibrary","package","archive","wikipedia","every","everyarticle": return "library"
        case "linked","links","linkedarticles","linkedfromhere","fromthispage","thispage","outlinks","linkedpages": return "linked"
        case "titles","title","named","these","list","articles","specific": return "titles"
        case "search","results","searchresults","about","topic","related": return "search"
        default: return PageQuery.fold(raw)
        }
    }
    static func normalizeMeasure(_ raw:String)->String {
        switch PageQuery.fold(raw).replacingOccurrences(of:" ",with:"") {
        case "articles","count","howmanyarticles","articlecount","number","howmany","mentions": return "articles"
        case "total","sum","occurrences","times","all","matches","howmanytimes","totalcount": return "total"
        case "list","which","names","titles","whicharticles","show","rank","ranking","most": return "list"
        default: return PageQuery.fold(raw)
        }
    }
    static func normalizeRule(_ raw:String)->String {
        switch PageQuery.fold(raw).replacingOccurrences(of:" ",with:"") {
        case "avoid","block","exclude","skip","dontgo","never": return "avoid"
        case "stay","stayinarticle","stayhere","nolinks","dontleave","staylocal": return "stay"
        case "allowlinks","allow","links","leave","followlinks": return "allowLinks"
        case "clearrules","clear","reset","norules","removerules": return "clearRules"
        default: return raw
        }
    }

    /// The library question this step asks, if it is a library step with a query.
    public var libraryRequest:LibraryRequest? {
        guard action == "library",let query else {return nil}
        let scope=self.scope ?? ((titles ?? []).isEmpty ? "library" : "titles")
        return LibraryRequest(scope:scope,measure:measure ?? "articles",query:query,section:scope == "linked" ? place : nil,
                              titles:titles,search:scope == "search" ? (topic ?? place) : nil,articleLimit:articles)
    }

    /// Problems that stop this step from running. Empty means executable.
    public var problems:[String] {
        var issues:[String]=[]
        guard Self.actions.contains(action) else {return ["unknown action “\(action)”; use one of \(Self.actions.joined(separator:", "))"]}
        if Self.queryActions.contains(action) {
            if query == nil && result == nil {issues.append("\(action) needs a query (or a saved result)")}
            issues += (query?.problems ?? []).map {"query: "+$0}
        }
        if action == "library",result != "more" {
            if let request=libraryRequest {issues += request.problems}
            else {issues.append("library needs a query: what to count or find in each article")}
        }
        issues += (footing?.problems ?? []).map {"footing: "+$0}
        if footing != nil && footing?.isWordLike != true {issues.append("footing must describe words")}
        switch action {
        case "show": if result == nil && query == nil {issues.append("show needs a saved result id")}
        case "go": if place == nil {issues.append("go needs a place")}
        case "follow": if place == nil {issues.append("follow needs the link text in place")}
        case "open": if title == nil && path == nil {issues.append("open needs an article title")}
        case "hunt": if phrase == nil {issues.append("hunt needs a phrase")}
        case "explore": if topic == nil {issues.append("explore needs a topic")}
        case "speed": if !["faster","slower","normal"].contains(speed ?? "") {issues.append("speed must be faster, slower or normal")}
        case "rule":
            if !["avoid","stay","allowLinks","clearRules"].contains(rule ?? "") {issues.append("rule must be avoid, stay, allowLinks or clearRules")}
            if rule == "avoid" && place == nil {issues.append("rule avoid needs a place")}
        default: break
        }
        for value in [color,target,place,title,phrase,topic,question].compactMap({$0})+(titles ?? []) where value.count>500 {
            issues.append("a field is longer than 500 characters")
        }
        return issues
    }
}

public struct CompanionPlan:Codable,Sendable,Equatable {
    public var steps:[CompanionStep]
    /// What Atlas says before running the steps. Never contains counts; Atlas reports those.
    public var reply:String?
    /// Article block IDs that support the reply.
    public var sources:[String]?
    /// True when the deterministic local parser produced the plan.
    public var local=false

    public init(steps:[CompanionStep],reply:String?=nil,sources:[String]?=nil,local:Bool=false) {
        self.steps=steps;self.reply=reply;self.sources=sources;self.local=local
    }
    enum CodingKeys:String,CodingKey {case steps,reply,sources}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        if let steps=try? c.decodeIfPresent([CompanionStep].self,forKey:.steps) {self.steps=steps}
        else if let step=try? c.decodeIfPresent(CompanionStep.self,forKey:.steps) {self.steps=[step]}
        else {self.steps=[]}
        reply=c.lenientString(.reply,trim:true)
        sources=c.lenientStrings(.sources)
    }

    public func normalized()->CompanionPlan {
        var plan=self
        plan.steps=steps.compactMap {$0.normalized()}
        return plan
    }
    public var problems:[String] {
        var issues:[String]=[]
        if steps.count>8 {issues.append("at most 8 steps")}
        for (index,step) in steps.enumerated() {
            issues += step.problems.map {"step \(index+1) (\(step.action)): "+$0}
        }
        return issues
    }

    /// Decodes a model's raw output. Small models sometimes wrap the object in prose or a code fence.
    public static func decode(_ raw:String)->CompanionPlan? {
        let decoder=JSONDecoder()
        if let plan=try? decoder.decode(CompanionPlan.self,from:Data(raw.utf8)) {return plan}
        guard let start=raw.firstIndex(of:"{"),let end=raw.lastIndex(of:"}"),start<end else {return nil}
        return try? decoder.decode(CompanionPlan.self,from:Data(raw[start...end].utf8))
    }
}

// MARK: - JSON schema for constrained decoding

/// A JSON value that keeps object keys in order. Ollama's grammar-constrained
/// decoding emits properties in schema order, so the order is deliberate:
/// the model chooses the action before its details, and the unit before its filters.
public indirect enum OrderedJSON:Sendable {
    case object([(String,OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(Int)
    case bool(Bool)

    public var serialized:String {
        switch self {
        case .object(let pairs): return "{"+pairs.map {Self.quote($0.0)+":"+$0.1.serialized}.joined(separator:",")+"}"
        case .array(let values): return "["+values.map(\.serialized).joined(separator:",")+"]"
        case .string(let value): return Self.quote(value)
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
    static func quote(_ value:String)->String {
        var result="\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value<0x20 {result += String(format:"\\u%04x",scalar.value)} else {result.unicodeScalars.append(scalar)}
            }
        }
        return result+"\""
    }
}

extension CompanionPlan {
    static func enumeration(_ values:[String])->OrderedJSON {.object([("type",.string("string")),("enum",.array(values.map {.string($0)}))])}
    static let text=OrderedJSON.object([("type",.string("string"))])
    static let integer=OrderedJSON.object([("type",.string("integer"))])
    static let boolean=OrderedJSON.object([("type",.string("boolean"))])
    static let texts=OrderedJSON.object([("type",.string("array")),("items",text)])

    static var querySchema:OrderedJSON {
        .object([
            ("type",.string("object")),
            ("properties",.object([
                ("unit",enumeration(PageQuery.units)),
                ("partOfSpeech",enumeration(PageQuery.partsOfSpeech)),
                ("entity",enumeration(PageQuery.entities)),
                ("letterCase",enumeration(PageQuery.letterCases)),
                ("characterClass",enumeration(PageQuery.characterClasses)),
                ("startsWith",text),("endsWith",text),("contains",text),("equals",text),
                ("notStartsWith",text),("notEndsWith",text),("notContains",text),("exclude",texts),
                ("minLength",integer),("maxLength",integer),("length",integer),("minWords",integer),("maxWords",integer),
                ("section",text),("excludeSections",texts),("distinct",boolean),("caseSensitive",boolean),
                ("order",enumeration(PageQuery.orders)),("rank",integer),("limit",integer),("meaning",text),("linksTo",text)
            ])),
            ("additionalProperties",.bool(false))
        ])
    }

    /// The JSON schema passed to Ollama's `format`, which constrains decoding so
    /// even small local models can only produce a well-formed plan.
    public static var schema:OrderedJSON {
        let step=OrderedJSON.object([
            ("type",.string("object")),
            ("properties",.object([
                ("action",enumeration(CompanionStep.actions)),
                ("query",querySchema),
                ("color",text),("instant",boolean),("footing",querySchema),
                ("result",text),("target",text),("place",text),("title",text),("phrase",text),("topic",text),
                ("speed",enumeration(["faster","slower","normal"])),
                ("rule",enumeration(["avoid","stay","allowLinks","clearRules"])),
                ("question",text),
                ("scope",enumeration(LibraryRequest.scopes)),("measure",enumeration(LibraryRequest.measures)),
                ("titles",texts),("articles",integer)
            ])),
            ("required",.array([.string("action")])),
            ("additionalProperties",.bool(false))
        ])
        return .object([
            ("type",.string("object")),
            ("properties",.object([
                ("steps",.object([("type",.string("array")),("items",step),("maxItems",.number(6))])),
                ("reply",text),
                ("sources",.object([("type",.string("array")),("items",text),("maxItems",.number(6))]))
            ])),
            ("required",.array([.string("steps"),.string("reply")])),
            ("additionalProperties",.bool(false))
        ])
    }
    public static var schemaJSON:String {schema.serialized}
}
