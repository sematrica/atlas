import Foundation
import WebKit
import Observation
import AtlasCore

struct CompanionLine:Identifiable {
    let id=UUID()
    let user:Bool
    var text:String
    var isError=false
    /// Small notes under a reply: "understood instantly", "llama3.1 · 3.2 s", "42 highlighted".
    var trail:[String]=[]
    /// The articles a library question found, shown under the reply with Open buttons.
    var library:LibraryLine?
    /// The chain of links between two articles, drawn as a constellation under the reply.
    var connection:ConnectionLine?
}

/// A connection answer: the chain (or just its two ends while searching), and the walk along it.
struct ConnectionLine {
    var chain:[ConnectionStop]
    var found:Bool
    var proven:Bool
    /// Articles read so far; the map shows them as faint stars.
    var read:Int
    /// The search stopped early and can keep looking.
    var canContinue:Bool
    /// The stop the spider has reached while walking the route.
    var reached:Int?
    var walking=false
}

/// A library answer's article list.
struct LibraryLine {
    /// Matching articles, most matches first (the first 200).
    let hits:[LibraryHit]
    let matchingArticles:Int
    /// What each Open button highlights in the article it opens.
    let query:PageQuery
    /// More articles remain to be read.
    var canContinue:Bool
}

/// A colored highlight layer currently painted on the page.
struct HighlightLayer:Identifiable {
    let id:String
    let label:String
    let style:HighlightStyle
    var count:Int
    let document:String
}

/// Something Atlas found that the user can refer back to ("show them again").
struct CompanionResult:Identifiable {
    let id:String
    let label:String
    let query:PageQuery?
    let footing:PageQuery?
    let matches:[PageMatch]
    let count:Int
    let complete:Bool
    let frequencies:[WordFrequency]
    let document:String
    let fingerprint:String
    var canDemonstrate:Bool {!matches.isEmpty}
}

/// The companion conversation. Each message becomes a plan (instantly from the
/// local parser, or from one model call); every step is then carried out by
/// Atlas itself, with the spider as its hands.
@MainActor @Observable
final class CrawlerConversation {
    @ObservationIgnored weak var crawler:CrawlerController?
    var panelOpen=true
    var input=""
    var lines:[CompanionLine]=[]
    var busy=false
    /// The spider is demonstrating (walking to matches and painting them).
    var touring=false
    /// A long sweep is running; "Finish now" paints the rest at once.
    var canFinish=false
    var status="Ready to read with you"
    var layers:[HighlightLayer]=[]
    var results:[CompanionResult]=[]
    var focusResult:String?
    /// Wandering pace in points per second: unhurried by default.
    static let normalSpeed=200.0
    var speed=normalSpeed
    var rules=CrawlerTravelRules()
    var excludedSections:[String]=[]
    /// True while a plan moves the spider, so wandering and hunting yield to it.
    var guiding=false
    var isGuiding:Bool {guiding || touring}
    var companionTitle:String {crawler?.ready == true ? (crawler?.intelligence.browser?.title ?? "Article") : "No article open"}
    var focused:CompanionResult? {focusResult.flatMap {id in results.first {$0.id == id}}}

    @ObservationIgnored private var task:Task<Void,Never>?
    @ObservationIgnored private var generation=UUID()
    @ObservationIgnored private var resultSerial=0
    @ObservationIgnored private var layerSerial=0
    @ObservationIgnored private var articleNotes:[String:String]=[:]
    @ObservationIgnored private var planNavigation=false
    @ObservationIgnored private var finishRequested=false
    @ObservationIgnored private var announcedHunt:String?
    /// A result Atlas just offered to highlight ("Want me to highlight them?").
    @ObservationIgnored private var offeredResult:String?
    /// The last library question, kept so "check more articles" can continue it.
    @ObservationIgnored private var libraryRun:LibraryRun?
    /// The last connection search, kept so "keep looking" can continue it.
    @ObservationIgnored private var connectionRun:ConnectionRun?

    init(crawler:CrawlerController) {self.crawler=crawler}

    // MARK: Lines

    @discardableResult func say(_ text:String,user:Bool=false,isError:Bool=false)->UUID {
        let line=CompanionLine(user:user,text:text,isError:isError)
        lines.append(line)
        if lines.count>60 {lines.removeFirst(lines.count-60)}
        return line.id
    }
    private func amend(_ id:UUID?,text:String?=nil,trail:String?=nil) {
        guard let id,let index=lines.firstIndex(where:{$0.id == id}) else {return}
        if let text {lines[index].text=text}
        if let trail {lines[index].trail.append(trail)}
    }

    // MARK: Lifecycle

    /// Cancels the running request. Highlights and saved results stay.
    func interrupt() {
        generation=UUID();task?.cancel();task=nil;offeredResult=nil
        endRequest()
    }
    private func endRequest() {
        busy=false;touring=false;canFinish=false;finishRequested=false
        if guiding {guiding=false;crawler?.releaseControl()}
    }
    /// The Stop button: cancel everything and hold the spider still.
    func stopAll() {
        interrupt();crawler?.pauseCreature()
        status="Stopped · highlights and results kept"
    }
    /// Paints the rest of a long sweep at once.
    func finishTour() {finishRequested=true}
    /// The page is about to change. A plan that is itself navigating keeps running.
    func pageWillChange() {
        if !planNavigation {interrupt()}
        layers=[];touring=false;announcedHunt=nil
    }
    func pageArrived() {
        if !planNavigation {status=lines.isEmpty ? "Ready to read with you" : "New article · conversation kept"}
    }
    /// Called by the crawler when a phrase hunt reaches its target.
    func huntFound(_ text:String) {
        guard announcedHunt != text else {return}
        announcedHunt=text
        say("Found “\(text)”! It's highlighted where I'm standing. Say “next” to keep hunting, or “stop”.")
    }

    // MARK: Requests

    func send(_ supplied:String?=nil) {
        let request=(supplied ?? input).trimmingCharacters(in:.whitespacesAndNewlines)
        guard !request.isEmpty,let crawler else {return}
        input=""
        let offer=offeredResult
        interrupt()
        say(request,user:true)
        guard request.count<=4000 else {say("Please keep messages under 4,000 characters.");return}
        var local=CompanionLocalParser.parse(request)
        // "Yes" right after "Want me to highlight them?" needs no model.
        if local == nil,let offer,Self.affirmative(request) {
            var step=CompanionStep(action:"show");step.result=offer
            local=CompanionPlan(steps:[step],local:true)
        }
        let model=crawler.intelligence.model
        if local == nil && model.isEmpty {
            say("Choose a chat model in Ask so I can understand that. Without one I still follow direct requests like “how many links are here”, “highlight nouns in green” or “go to the longest word”.")
            return
        }
        start(request,local:local)
    }
    /// Runs a ready-made plan as if the user had asked for it.
    func run(_ plan:CompanionPlan,saying request:String) {
        interrupt()
        say(request,user:true)
        start(request,local:plan)
    }
    private func start(_ request:String,local:CompanionPlan?) {
        busy=true
        status=local == nil ? "Thinking with \(crawler?.intelligence.model ?? "the model")…" : "On it…"
        let token=generation
        task=Task { [weak self] in await self?.handle(request,local:local,token:token)}
    }
    static func affirmative(_ text:String)->Bool {
        let cleaned=text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
        return ["yes","yes please","yeah","yep","sure","ok","okay","please","please do","do it","go ahead","go for it","show me","show them","highlight them","yes highlight them","sure thing","why not"].contains(cleaned)
    }
    /// Kept for callers of the previous companion API.
    func talk(_ supplied:String?=nil) {send(supplied)}

    private func handle(_ request:String,local:CompanionPlan?,token:UUID) async {
        guard let crawler else {return}
        defer {if token == generation {endRequest()}}
        do {
            var page:CrawlerPageMap?
            if crawler.ready {page=try await readPage()}
            try checkpoint(token)
            let plan:CompanionPlan
            if let local {
                plan=local
            } else {
                let context=promptContext(page:page,request:request)
                let result=try await CompanionPlanner.plan(request:request,context:context,history:history(),provider:crawler.intelligence.provider,model:crawler.intelligence.model)
                try checkpoint(token)
                plan=result.plan
                let timing=String(format:"%@ · %.1f s",crawler.intelligence.model,result.seconds)+(result.repaired ? " · retried" : "")
                if let reply=plan.reply,!reply.isEmpty {
                    let line=say(reply);amend(line,trail:timing)
                } else if plan.steps.isEmpty {
                    say("I'm not sure what you'd like me to do. Could you say it another way?")
                }
                if !result.rejected.isEmpty {
                    say("I couldn't do part of that (\(result.rejected.joined(separator:"; "))). Try asking for that part differently.",isError:true)
                }
                if let page,let sources=plan.sources,!sources.isEmpty {saveSources(sources,page:page,reply:plan.reply ?? "")}
            }
            for step in plan.steps {
                try checkpoint(token)
                page=try await perform(step,page:page,local:plan.local,token:token)
            }
            if token == generation && !touring {status="Listening"}
        } catch is CancellationError {
        } catch {
            guard token == generation,!Task.isCancelled else {return}
            status="Couldn't finish that"
            say(error.localizedDescription,isError:true)
        }
    }

    private func checkpoint(_ token:UUID) throws {
        try Task.checkCancellation()
        guard token == generation else {throw CancellationError()}
    }

    private func history()->[AIMessage] {
        // The latest user line is the request itself and is sent separately.
        lines.dropLast().filter {!$0.isError}.suffix(8).map {AIMessage($0.user ? "user" : "assistant",String($0.text.prefix(600)))}
    }

    private func promptContext(page:CrawlerPageMap?,request:String)->CompanionPromptContext {
        let highlights=layers.map {"\($0.style.label): \($0.label) (\($0.count))"}
        var saved=results.suffix(8).map {"\($0.id): \(Self.format($0.count)) \($0.label)"}
        if let run=libraryRun,!run.hits.isEmpty {
            saved.append("library: "+run.ranked.prefix(5).map {"\($0.title) (\($0.count))"}.joined(separator:", ")+(run.isComplete ? "" : "; more articles remain, \"result\":\"more\" continues"))
        }
        if let run=connectionRun {
            let chain=run.chain.map {$0.map(\.title).joined(separator:" → ")} ?? "\(run.start.title) … \(run.target.title), not connected yet"
            saved.append("connection: "+chain+(run.isComplete ? "" : "; the search stopped early, connect with \"result\":\"more\" keeps looking"))
        }
        guard let page,crawler?.ready == true else {return CompanionPromptContext(state:spiderState(),highlights:highlights,results:saved)}
        return CompanionPromptContext(page:page,title:companionTitle,request:request,state:spiderState(),highlights:highlights,results:saved)
    }

    private func spiderState()->String {
        guard let crawler else {return ""}
        var parts=[crawler.active ? crawler.status.rawValue : "resting"]
        parts.append("speed \(Int(speed))")
        parts.append(rules.allowLinks ? "may follow links" : "staying in this article")
        if !rules.blocked.isEmpty {parts.append("avoiding "+rules.blocked.joined(separator:", "))}
        if !excludedSections.isEmpty {parts.append("skipping sections "+excludedSections.joined(separator:", "))}
        return parts.joined(separator:"; ")
    }

    // MARK: Steps

    private func perform(_ step:CompanionStep,page:CrawlerPageMap?,local:Bool,token:UUID) async throws -> CrawlerPageMap? {
        guard let crawler else {throw CancellationError()}
        switch step.action {
        case "count","list","highlight","goto":
            guard let page=try await currentPage(page) else {return nil}
            guard let result=try await resolve(step,page:page,token:token) else {return page}
            switch step.action {
            case "count": report(count:result,local:local)
            case "list": report(list:result,local:local)
            case "highlight": try await highlight(result,color:step.color,instant:step.instant == true,page:page,local:local,token:token)
            default: try await walkTo(result,color:step.color,page:page,local:local,token:token)
            }
            return page
        case "show":
            guard let page=try await currentPage(page) else {return nil}
            let saved=step.result.flatMap {savedResult($0)} ?? focused
            guard let saved else {say("Which result should I show? I haven't found anything on this page yet.");return page}
            guard let current=try await refreshed(saved,page:page,token:token) else {return page}
            if current.matches.count == 1 {try await walkTo(current,color:step.color,page:page,local:local,token:token)}
            else {try await highlight(current,color:step.color,instant:step.instant == true,page:page,local:local,token:token)}
            return page
        case "clear":
            await clear(step.target)
        case "go":
            try await go(to:step.place ?? "",page:page,token:token)
        case "follow":
            return try await follow(step.place ?? "",page:page,token:token)
        case "open":
            if let path=step.path {
                say("Opening “\(step.title ?? path)”.")
                return try await navigate(path:path,token:token)
            }
            return try await open(step.title ?? "",page:page,token:token)
        case "back":
            return try await back(page:page,token:token)
        case "hunt":
            hunt(step.phrase ?? "")
        case "explore":
            explore(step.topic ?? "")
        case "wander":
            guard crawler.ready else {say("Open an article first, then I'll wander around it.");return page}
            crawler.start(hunt:false,preservingConversation:true)
            say("Wandering around the page. Say “pause” or “stop” anytime.")
        case "pause":
            crawler.pauseCreature();say("Paused. Say “resume” when you're ready.")
        case "resume":
            resume()
        case "stop":
            say("Stopped.");crawler.stopCreature(preserveExpedition:false)
        case "speed":
            switch step.speed {
            case "faster": speed=min(540,speed*1.5)
            case "slower": speed=max(45,speed/1.5)
            default: speed=Self.normalSpeed
            }
            say(step.speed == "normal" ? "Back to my normal pace." : "Speed: \(Int(speed)) points per second.")
        case "rule":
            applyRule(step,page:page)
        case "read":
            try await read(question:step.question ?? "Summarize the article",page:page,token:token)
        case "library":
            try await library(step,page:page,local:local,token:token)
        case "connect":
            try await connect(step,local:local,token:token)
        default:
            say("I don't know how to “\(step.action)” yet.")
        }
        return page
    }

    private func currentPage(_ page:CrawlerPageMap?) async throws -> CrawlerPageMap? {
        if let page {return page}
        guard crawler?.ready == true else {
            say("Open an article first, then I can do that on its page.")
            return nil
        }
        return try await readPage()
    }

    private func savedResult(_ id:String)->CompanionResult? {
        results.first {$0.id.caseInsensitiveCompare(id) == .orderedSame}
    }

    /// A saved result on the current page; re-runs its query if the page changed.
    private func refreshed(_ saved:CompanionResult,page:CrawlerPageMap,token:UUID) async throws -> CompanionResult? {
        if saved.fingerprint == page.fingerprint {return saved}
        guard let query=saved.query else {say("Those passages belong to another article.");return nil}
        return try await run(query,footing:saved.footing,page:page,token:token)
    }

    private func resolve(_ step:CompanionStep,page:CrawlerPageMap,token:UUID) async throws -> CompanionResult? {
        if step.query == nil,let id=step.result {
            guard let saved=savedResult(id) else {say("I don't have a saved result called \(id).");return nil}
            return try await refreshed(saved,page:page,token:token)
        }
        guard var query=step.query else {return nil}
        if !excludedSections.isEmpty {query.excludeSections=(query.excludeSections ?? [])+excludedSections}
        return try await run(query,footing:step.footing,page:page,token:token)
    }

    private func run(_ query:PageQuery,footing:PageQuery?,page:CrawlerPageMap,token:UUID) async throws -> CompanionResult? {
        status="Looking through the page…"
        var allowed:Set<String>?
        if let meaning=query.normalized().meaning {
            allowed=try await judge(query,meaning:meaning,page:page,token:token)
        }
        let approved=allowed
        let outcome=await Task.detached(priority:.userInitiated) {PageQueryEngine.run(query,on:page,allowed:approved)}.value
        try checkpoint(token)
        if let missing=outcome.unknownSection {
            let names=outcome.sections.filter {$0 != "introduction"}.prefix(14).joined(separator:", ")
            say("I couldn't find a section called “\(missing)”."+(names.isEmpty ? "" : " Sections here: \(names)."))
            return nil
        }
        resultSerial += 1
        let result=CompanionResult(id:"r\(resultSerial)",label:outcome.query.summary,query:outcome.query,footing:footing,matches:outcome.matches,
                                   count:outcome.count,complete:outcome.complete,frequencies:outcome.frequencies,document:page.document,fingerprint:page.fingerprint)
        results.append(result)
        if results.count>12 {results.removeFirst(results.count-12)}
        if result.canDemonstrate {focusResult=result.id}
        return result
    }

    /// Asks the model which candidate spellings satisfy a semantic condition.
    private func judge(_ query:PageQuery,meaning:String,page:CrawlerPageMap,token:UUID) async throws -> Set<String> {
        guard let crawler,!crawler.intelligence.model.isEmpty else {
            throw AIError.message("Judging meaning (“\(meaning)”) needs a chat model. Choose one in Ask.")
        }
        var broad=query
        broad.meaning=nil;broad.order=nil;broad.rank=nil;broad.limit=nil
        let candidates=broad
        let pool=await Task.detached {PageQueryEngine.run(candidates,on:page)}.value
        var seen=Set<String>()
        let spellings=pool.matches.map(\.text).filter {seen.insert($0.lowercased()).inserted}
        let capped=Array(spellings.prefix(600))
        status="Judging \(capped.count) candidates for “\(meaning)”…"
        let chosen=try await CompanionSemanticFilter.select(capped,meaning:meaning,provider:crawler.intelligence.provider,model:crawler.intelligence.model) {[weak self] done,total in
            Task {@MainActor in self?.status="Judging meaning · batch \(min(done+1,total)) of \(total)"}
        }
        try checkpoint(token)
        if spellings.count>capped.count {say("There were \(Self.format(spellings.count)) candidates; I judged the first 600.")}
        return Set(chosen.map {$0.lowercased()})
    }

    // MARK: Reports

    private func report(count result:CompanionResult,local:Bool) {
        let n=result.count
        var text:String
        if result.query?.unit == "phrase",let phrase=result.query?.equals {
            text=n == 0 ? "“\(phrase)” doesn't appear on this page." : "“\(phrase)” appears \(Self.format(n)) time\(n == 1 ? "" : "s") on this page."
        } else if n == 0 {
            text="I couldn't find any \(result.label) on this page."
        } else if n == 1,let only=result.matches.first,result.query?.order == nil {
            text="There's exactly one: “\(Self.clip(only.text,200))”."
        } else {
            text=result.label.hasPrefix("the ") ? "I found \(result.label)." : "There are \(Self.format(n)) \(result.label) on this page."
        }
        if !result.complete {text += " The page was too long to map completely, so the real number may be higher."}
        if n>1,n<=3000,result.canDemonstrate {text += " Want me to highlight them?";offeredResult=result.id}
        let line=say(text)
        if local {amend(line,trail:"understood instantly")}
    }

    private func report(list result:CompanionResult,local:Bool) {
        let query=result.query
        var text:String
        if let query,query.order == "frequent" || query.order == "rare" {
            let shown=Array(result.frequencies.prefix(max(1,min(query.rank == nil ? (query.limit ?? 1) : 1,25))))
            if shown.isEmpty {text="I couldn't find any \(query.nounPhrase(plural:true)) on this page."}
            else if shown.count == 1,let top=shown.first {
                text="The \(query.order == "frequent" ? "most" : "least") common \(query.nounPhrase(plural:false)) is “\(top.text)”: it appears \(Self.format(top.count)) time\(top.count == 1 ? "" : "s")."
            } else {
                text=(query.order == "frequent" ? "Most common: " : "Least common: ")+shown.map {"\($0.text) (\(Self.format($0.count)))"}.joined(separator:", ")+"."
            }
        } else if result.matches.isEmpty {
            text="I couldn't find \(result.label) on this page."
        } else if result.matches.count == 1,let match=result.matches.first {
            let measure=query?.isWordLike == true ? "\(match.text.filter(\.isLetter).count) letters" : "\(match.text.count) characters"
            text=Self.capitalized(result.label)+" is “\(Self.clip(match.text,400))” (\(measure))."
        } else {
            var seen=Set<String>()
            let items=result.matches.map(\.text).filter {seen.insert($0.lowercased()).inserted}
            let shown=items.prefix(40).map {"“\(Self.clip($0,120))”"}.joined(separator:", ")
            let heading=result.label.hasPrefix("the ") ? result.label : "the \(Self.format(result.matches.count)) \(result.label)"
            text="Here are \(heading): \(shown)"+(items.count>40 ? ", and \(Self.format(items.count-40)) more." : ".")
        }
        let line=say(text)
        if local {amend(line,trail:"understood instantly")}
    }

    // MARK: Highlighting and touring

    private func highlight(_ result:CompanionResult,color:String?,instant:Bool,page:CrawlerPageMap,local:Bool,token:UUID) async throws {
        let n=result.matches.count
        guard n>0 else {say("I couldn't find any \(result.label) on this page.");return}
        layerSerial += 1
        let style=HighlightStyle.parse(color) ?? HighlightStyle.automatic(layerSerial-1)
        let layer=HighlightLayer(id:"l\(layerSerial)",label:result.label,style:style,count:n,document:page.document)
        layers.append(layer)
        let plan:String
        if instant || crawler?.ready != true {plan="Highlighting them in \(style.label)."}
        else if n<=15 {plan="I'll walk to each one and mark it in \(style.label)."}
        else {plan="I'll sweep down the page and light them up in \(style.label). Tap Finish to do the rest at once."}
        let opening=n == 1 ? "Found it: “\(Self.clip(result.matches[0].text,160))”. " : "Found \(Self.counted(n,result.label)). "
        let line=say(opening+(n>25_000 ? "I'll mark the first 25,000. " : "")+plan)
        if local {amend(line,trail:"understood instantly")}
        try await paint(result,layer:layer,page:page,instant:instant,token:token)
        amend(line,trail:"\(Self.format(min(n,25_000))) highlighted")
        status=Self.capitalized(Self.counted(min(n,25_000),result.label))+" highlighted"
    }

    /// Adaptive tour: a few matches are visited one by one; many are revealed
    /// as the spider sweeps down the page; "instant" paints everything at once.
    private func paint(_ result:CompanionResult,layer:HighlightLayer,page:CrawlerPageMap,instant:Bool,token:UUID) async throws {
        let matches=Array(result.matches.prefix(25_000))
        let groups=layer.style.paintsByMatch(for:matches)
        guard let crawler,crawler.ready,!instant else {
            try await send(groups.flatMap {$0},layer:layer,page:page)
            if let first=matches.first,crawler?.ready == true,let rect=try await rects([first],page:page).first ?? nil {
                try await walk(to:rect.center,token:token,refresh:{[weak self] in await self?.freshCenter(first,page:page)})
            }
            return
        }
        ensureSpider()
        touring=true
        defer {touring=false;canFinish=false;finishRequested=false}
        let boxes=try await rects(matches,page:page)
        if matches.count<=15 {
            for (index,match) in matches.enumerated() {
                try checkpoint(token)
                if finishRequested {try await send(groups[index...].flatMap {$0},layer:layer,page:page);break}
                status="\(Self.capitalized(layer.label)) · \(index+1) of \(matches.count)"
                if let box=boxes[index] {
                    if let footing=result.footing {try await walkRestricted(to:box.center,label:match.text,footing:footing,page:page,token:token)}
                    else {try await walk(to:box.center,token:token,refresh:{[weak self] in await self?.freshCenter(match,page:page)})}
                }
                try await send(groups[index],layer:layer,page:page)
                try await Task.sleep(for:.milliseconds(140))
            }
            return
        }
        canFinish=true
        let located=matches.indices.filter {boxes[$0] != nil}.sorted {a,b in
            let first=boxes[a]!,second=boxes[b]!
            return first.y == second.y ? first.x<second.x : first.y<second.y
        }
        let hidden=matches.indices.filter {boxes[$0] == nil}
        // One waypoint per 180-point band of the page, at the middle of that band's matches.
        var bands:[(y:Double,xs:[Double])]=[]
        for index in located {
            let box=boxes[index]!
            if let last=bands.last,floor(last.y/180) == floor(box.center.y/180) {bands[bands.count-1].xs.append(box.center.x)}
            else {bands.append((box.center.y,[box.center.x]))}
        }
        let waypoints=bands.map {band in DocumentPosition(x:band.xs.sorted()[band.xs.count/2],y:band.y)}
        var revealed=0
        crawler.travelSpeed=max(speed,700)
        defer {crawler.travelSpeed=nil}
        for waypoint in waypoints {
            if finishRequested {break}
            try checkpoint(token)
            crawler.guide(to:waypoint)
            let began=Date()
            while !finishRequested {
                try checkpoint(token)
                let reach=crawler.agent.state.position.y+60
                var batch:[HighlightPaint]=[]
                while revealed<located.count,boxes[located[revealed]]!.y<=reach {batch += groups[located[revealed]];revealed += 1}
                try await send(batch,layer:layer,page:page)
                status="\(Self.capitalized(layer.label)) · \(Self.format(revealed)) of \(Self.format(located.count))"
                if crawler.agent.state.position.distance(to:waypoint)<16 || Date().timeIntervalSince(began)>5 {break}
                try await Task.sleep(for:.milliseconds(80))
            }
        }
        try await send(located[revealed...].flatMap {groups[$0]}+hidden.flatMap {groups[$0]},layer:layer,page:page)
    }

    private func send(_ paints:[HighlightPaint],layer:HighlightLayer,page:CrawlerPageMap) async throws {
        guard !paints.isEmpty else {return}
        let colors=layer.style.palette.map {["bg":$0,"ink":HighlightStyle.ink(for:$0)]}
        // Large layers go across in slices so a single call never carries megabytes.
        for start in stride(from:0,to:paints.count,by:4000) {
            let slice=Array(paints[start..<min(paints.count,start+4000)])
            let encoded=try jsonObject(slice)
            let spec:[String:Any]=["layer":layer.id,"colors":colors,"underline":layer.style.underline,"textOnly":layer.style.textOnly,
                                   "priority":layerSerial,"textRevision":page.textRevision.map {$0 as Any} ?? NSNull(),"paints":encoded]
            let painted=try await call("return window.atlasTerrain.paintLayer(spec)",["spec":spec]) as? Int
            if painted == -1 {throw AIError.message("The article text changed while I was working. Ask me again and I'll map it fresh.")}
        }
    }

    private func walkTo(_ result:CompanionResult,color:String?,page:CrawlerPageMap,local:Bool,token:UUID) async throws {
        guard let match=result.matches.first else {say("I couldn't find \(result.label) on this page.");return}
        let line=say("Walking to “\(Self.clip(match.text,160))”, \(result.label).")
        if local {amend(line,trail:"understood instantly")}
        guard let box=try await rects([match],page:page).first ?? nil else {say("I found it, but it isn't visible on the page right now.");return}
        if let footing=result.footing {try await walkRestricted(to:box.center,label:match.text,footing:footing,page:page,token:token)}
        else {try await walk(to:box.center,token:token,refresh:{[weak self] in await self?.freshCenter(match,page:page)})}
        layerSerial += 1
        let style=HighlightStyle.parse(color) ?? HighlightStyle(colors:["#f5da7b"],label:"spotlight")
        let layer=HighlightLayer(id:"l\(layerSerial)",label:result.label,style:style,count:1,document:page.document)
        layers.append(layer)
        try await send(style.paints(for:[match]),layer:layer,page:page)
        amend(line,trail:"arrived")
    }

    // MARK: Spider movement

    private func ensureSpider() {
        guard let crawler,crawler.ready else {return}
        if !crawler.active {crawler.start(hunt:false,preservingConversation:true)}
        guiding=true
        crawler.takeControl()
    }

    /// Walks to a point. If the article reflows on the way, the target is
    /// re-resolved instead of failing; a slow walk never fails the request.
    private func walk(to point:DocumentPosition,token:UUID,refresh:(() async -> DocumentPosition?)?=nil) async throws {
        guard let crawler,crawler.ready else {return}
        ensureSpider()
        var target=point
        var layout=crawler.agent.observation?.revision
        let distance=crawler.agent.state.position.distance(to:target)
        // Long trips become a quick dash; short ones keep the chosen pace.
        let pace=min(1100,max(speed,distance/2.2))
        crawler.travelSpeed=pace
        defer {crawler.travelSpeed=nil}
        crawler.guide(to:target)
        let deadline=Date().addingTimeInterval(6+distance/max(60,pace)*2.5)
        while Date()<deadline {
            try checkpoint(token)
            if crawler.agent.state.position.distance(to:target)<12 {break}
            if let refresh,let current=crawler.agent.observation?.revision,current != layout {
                layout=current
                if let fresh=await refresh() {target=fresh;crawler.guide(to:target)}
            }
            if crawler.agent.guidedGoal == nil {crawler.guide(to:target)}
            try await Task.sleep(for:.milliseconds(60))
        }
    }

    /// Walks with every foot landing on words matched by `footing` (e.g. only nouns).
    private func walkRestricted(to point:DocumentPosition,label:String,footing:PageQuery,page:CrawlerPageMap,token:UUID) async throws {
        guard let crawler else {return}
        ensureSpider()
        let holds=await Task.detached {PageQueryEngine.run(footing,on:page).matches}.value
        try checkpoint(token)
        let boxes=try await rects(holds,page:page)
        let anchors=zip(holds,boxes).flatMap {match,box -> [TerrainAnchor] in
            guard let box,let range=match.range else {return []}
            let count=max(1,Int(ceil(box.width/25)))
            return (0...count).map {index in
                TerrainAnchor(id:range.id+":\(range.start):\(index)",position:.init(x:box.x+min(box.width/2,1)+max(0,box.width-2)*Double(index)/Double(count),y:box.y+box.height/2),kind:.text)
            }
        }
        let name=footing.summary
        guard let route=CrawlerPageAnalysis.route(from:crawler.agent.state.position,to:point,footholds:anchors.map(\.position)),crawler.plantPageFeet(anchors) else {
            throw AIError.message("I found “\(Self.clip(label,80))”, but no connected path of \(name) reaches it from here. I kept your rule; move me closer or allow other footholds.")
        }
        say("My feet will land only on \(name) (\(route.count) steps). Grammar tags are estimates.")
        defer {crawler.pageFootholds=nil}
        for waypoint in route {try await walk(to:waypoint,token:token)}
    }

    // MARK: Navigation

    private func go(to place:String,page:CrawlerPageMap?,token:UUID) async throws {
        guard let page=try await currentPage(page) else {return}
        guard rules.permits(place) else {say("You asked me to avoid “\(place)”. Say “clear rules” if you've changed your mind.");return}
        guard let match=PageQueryEngine.locate(place,on:page) else {
            let names=PageQueryEngine.sectionNames(page).filter {$0 != "introduction"}.prefix(14).joined(separator:", ")
            say("I couldn't find “\(place)” on this page."+(names.isEmpty ? "" : " Sections here: \(names)."))
            return
        }
        let line=say("Heading to “\(Self.clip(match.text,80))”.")
        guard let box=try await rects([match],page:page).first ?? nil else {say("That part of the page isn't visible right now.");return}
        // Stand at the start of the heading or link, not in the middle of a long block.
        let spot=DocumentPosition(x:box.x+min(box.width/2,40),y:box.y+min(box.height/2,14))
        try await walk(to:spot,token:token,refresh:{[weak self] in
            guard let fresh=await self?.freshRect(match,page:page) else {return nil}
            return DocumentPosition(x:fresh.x+min(fresh.width/2,40),y:fresh.y+min(fresh.height/2,14))
        })
        amend(line,trail:"arrived")
    }

    private func follow(_ name:String,page:CrawlerPageMap?,token:UUID) async throws -> CrawlerPageMap? {
        guard let page=try await currentPage(page) else {return nil}
        guard let link=PageQueryEngine.findLink(name,on:page) else {say("I can't see a link called “\(name)” on this page.");return page}
        guard rules.allowLinks else {say("You asked me to stay in this article, so I won't follow links. Say “allow links” to change that.");return page}
        guard rules.permits(link.text+" "+(link.href ?? "")) else {say("That link leads somewhere you asked me to avoid.");return page}
        guard let path=try await articlePath(link.href) else {say("“\(link.text)” leads outside your offline library, so I can't open it.");return page}
        let match=PageMatch(range:nil,elementID:link.id,text:link.text,rect:link.rect,order:0)
        let line=say("Walking to the “\(Self.clip(link.text,80))” link.")
        if let box=try await rects([match],page:page).first ?? nil {try await walk(to:box.center,token:token)}
        amend(line,trail:"following")
        return try await navigate(path:path,token:token)
    }

    private func open(_ title:String,page:CrawlerPageMap?,token:UUID) async throws -> CrawlerPageMap? {
        guard let browser=crawler?.intelligence.browser,let provider=browser.provider else {say("Open a package in Library first.");return page}
        let wanted=title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !wanted.isEmpty else {say("Which article should I open?");return page}
        status="Searching for “\(wanted)”…"
        var found=try await provider.search(wanted,limit:8)
        if found.isEmpty {
            // The title index can be case-sensitive: try "Paris", "Ray Charles".
            let titled=wanted.split(separator:" ").map {$0.prefix(1).uppercased()+$0.dropFirst()}.joined(separator:" ")
            if titled != wanted {found=try await provider.search(titled,limit:8)}
        }
        try checkpoint(token)
        guard let best=found.first(where:{$0.title.caseInsensitiveCompare(wanted) == .orderedSame}) ?? found.first else {
            say("I couldn't find an article called “\(wanted)” in this package.");return page
        }
        say("Opening “\(best.title)”.")
        return try await navigate(path:best.articleID.path,token:token)
    }

    private func back(page:CrawlerPageMap?,token:UUID) async throws -> CrawlerPageMap? {
        guard let browser=crawler?.intelligence.browser,browser.canGoBack else {say("There's no previous article to go back to.");return page}
        return try await navigate(path:nil,token:token)
    }

    /// Navigates (to a path, or back when nil) and waits for the new article to be ready.
    private func navigate(path:String?,token:UUID) async throws -> CrawlerPageMap? {
        guard let crawler,let browser=crawler.intelligence.browser else {return nil}
        let previous=browser.webView?.url
        planNavigation=true
        defer {planNavigation=false}
        if let path {browser.navigate(path)} else {browser.back()}
        let deadline=Date().addingTimeInterval(20)
        while Date()<deadline {
            try checkpoint(token)
            if crawler.ready,browser.webView?.url != previous,!browser.loading {break}
            try await Task.sleep(for:.milliseconds(120))
        }
        guard crawler.ready,browser.webView?.url != previous else {say("The article didn't open in time.");return nil}
        status="Reading “\(browser.title)”"
        return try await readPage()
    }

    private func articlePath(_ href:String?)async throws -> String? {
        guard let href,let browser=crawler?.intelligence.browser,let base=browser.webView?.url,
              let url=URL(string:href,relativeTo:base)?.absoluteURL,let provider=browser.provider else {return nil}
        let path:String
        if url.scheme == "atlas",url.host == base.host {path=String(url.path.dropFirst())}
        else if let local=OfflineURL.localWikipediaPath(url) {path=local}
        else {return nil}
        let info=try await provider.info(path:path)
        return info.mimeType.contains("html") ? info.path : nil
    }

    // MARK: Across the library

    /// Counts or finds across many articles: search proposes candidates, then every
    /// candidate is read and counted exactly. Long questions stop after a batch and can continue.
    private func library(_ step:CompanionStep,page:CrawlerPageMap?,local:Bool,token:UUID) async throws {
        guard let browser=crawler?.intelligence.browser,let record=browser.record,let source=browser.provider as? any LibraryArticleSource else {
            say("Open a package in Library first.");return
        }
        var run:LibraryRun
        if step.result == "more" {
            guard let previous=libraryRun,previous.packageID == record.id else {say("There's no library question to continue.");return}
            guard !previous.isComplete else {say("I've already read every article for that question.");return}
            run=previous
        } else {
            guard let request=step.libraryRequest else {say("What should I count or find in each article?");return}
            var index:(any LibraryTextIndex)?
            if request.scope == "library",!request.searchTexts.isEmpty {
                let fullText=try await source.hasArchiveFullText()
                if !fullText {index=await browser.libraryTextIndex()}
            }
            var current:(id:ArticleID,page:CrawlerPageMap)?
            if request.scope == "linked" {
                guard let id=browser.currentArticleID,let page=try await currentPage(page) else {say("Open an article first: I'll read the articles it links to.");return}
                current=(id,page)
            }
            status="Finding the articles to read…"
            run=try await LibraryEngine.start(request,packageID:record.id,source:source,index:index,current:current)
        }
        try checkpoint(token)
        let line=say(step.result == "more" ? "Reading more articles…" : "Reading articles…")
        if local {amend(line,trail:"understood instantly")}
        let began=Date()
        run=try await LibraryEngine.advance(run,source:source) {@MainActor [weak self] progress in
            guard let self,token == self.generation else {return}
            let remaining=progress.remaining.map {", about \(Self.format($0)) to go"} ?? ""
            self.status="Read \(Self.format(progress.checked)) articles · \(Self.format(progress.hits)) with matches"
            self.amend(line,text:"Reading articles… \(Self.format(progress.checked)) read\(remaining).")
        }
        try checkpoint(token)
        libraryRun=run
        amend(line,text:run.answer,trail:String(format:"%.1f s",Date().timeIntervalSince(began)))
        if let index=lines.firstIndex(where:{$0.id == line}) {
            lines[index].library=LibraryLine(hits:Array(run.ranked.prefix(200)),matchingArticles:run.hits.count,query:run.request.countingQuery,canContinue:!run.isComplete)
        }
    }

    /// Opens an article from a library answer and highlights what was counted there.
    func openLibraryHit(_ hit:LibraryHit,query:PageQuery) {
        var open=CompanionStep(action:"open");open.title=hit.title;open.path=hit.path
        let highlight=CompanionStep(action:"highlight",query:query)
        run(CompanionPlan(steps:[open,highlight],local:true),saying:"Open “\(hit.title)” and show the matches")
    }
    /// Continues the last library question with the next batch of articles.
    func continueLibrary() {
        var step=CompanionStep(action:"library");step.result="more"
        if let index=lines.lastIndex(where:{$0.library?.canContinue == true}) {lines[index].library?.canContinue=false}
        run(CompanionPlan(steps:[step],local:true),saying:"Check more articles")
    }

    // MARK: Connect the dots

    /// Finds the shortest chain of links between two articles, then walks it with the spider:
    /// in each article it goes to the link that leads on, lights it and follows it.
    private func connect(_ step:CompanionStep,local:Bool,token:UUID) async throws {
        guard let browser=crawler?.intelligence.browser,let record=browser.record,let source=browser.provider as? any LibraryArticleSource else {
            say("Open a package in Library first.");return
        }
        var run:ConnectionRun
        if step.result == "more" {
            guard let previous=connectionRun,previous.packageID == record.id else {say("There's no connection search to continue.");return}
            guard !previous.isComplete else {say(previous.proven ? "That's already the shortest chain." : "I've looked as far as I can for that one.");return}
            run=previous
        } else {
            status="Finding both articles…"
            var index:(any LibraryTextIndex)?
            if !(try await source.hasArchiveFullText()) {index=await browser.libraryTextIndex()}
            run=try await ConnectionEngine.start(from:step.from,to:step.title ?? "",current:browser.currentArticleID,packageID:record.id,source:source,index:index)
        }
        try checkpoint(token)
        let from=run.start.title,to=run.target.title
        let line=say(step.result == "more" ? "Looking further for a chain from \(from) to \(to)…" : "Looking for the shortest chain of links from \(from) to \(to)…")
        if local {amend(line,trail:"understood instantly")}
        setConnection(line,ConnectionLine(chain:run.chain ?? [run.start,run.target],found:run.chain != nil,proven:run.proven,read:run.read,canContinue:false))
        let began=Date()
        run=try await ConnectionEngine.advance(run,source:source) {@MainActor [weak self] progress in
            guard let self,token == self.generation else {return}
            self.status=progress.checkingMentions ? "Checking articles that mention \(to)…" : "Read \(Self.format(progress.read)) articles, \(progress.level) link\(progress.level == 1 ? "" : "s") out"
            self.updateConnection(line) {$0.read=progress.read}
        }
        try checkpoint(token)
        connectionRun=run
        amend(line,text:run.answer,trail:String(format:"%.1f s",Date().timeIntervalSince(began)))
        setConnection(line,ConnectionLine(chain:run.chain ?? [run.start,run.target],found:run.chain != nil,proven:run.proven,read:run.read,canContinue:!run.isComplete))
        if let chain=run.chain,chain.count>1 {try await walkRoute(chain,line:line,token:token)}
    }

    private func setConnection(_ line:UUID,_ value:ConnectionLine) {
        if let index=lines.firstIndex(where:{$0.id == line}) {lines[index].connection=value}
    }
    private func updateConnection(_ line:UUID,_ change:(inout ConnectionLine)->Void) {
        guard let index=lines.firstIndex(where:{$0.id == line}),var value=lines[index].connection else {return}
        change(&value);lines[index].connection=value
    }

    /// Walks a chain from its first article: in each one the spider goes to the link that leads on,
    /// lights it in orange and follows it.
    private func walkRoute(_ chain:[ConnectionStop],line:UUID,token:UUID) async throws {
        guard let crawler,let browser=crawler.intelligence.browser,chain.count>1 else {return}
        guard rules.allowLinks else {say("You asked me to stay in this article, so I won't walk the route. Say “allow links”, then press Walk it.");return}
        updateConnection(line) {$0.walking=true;$0.reached=0}
        defer {updateConnection(line) {$0.walking=false}}
        var page:CrawlerPageMap?
        if crawler.ready,browser.currentArticleID?.path == chain[0].path {page=try await readPage()}
        else {page=try await navigate(path:chain[0].path,token:token)}
        guard page != nil else {return}
        for index in 0..<(chain.count-1) {
            try checkpoint(token)
            let here=chain[index],next=chain[index+1]
            updateConnection(line) {$0.reached=index}
            status="\(here.title) → \(next.title)"
            if let current=page,let link=routeLink(to:next,on:current) {
                let match=PageMatch(range:nil,elementID:link.id,text:link.text,rect:link.rect,order:0)
                if let box=try await rects([match],page:current).first ?? nil {
                    try await walk(to:box.center,token:token,refresh:{[weak self] in await self?.freshCenter(match,page:current)})
                    layerSerial += 1
                    let style=HighlightStyle.parse("orange") ?? HighlightStyle(colors:["#ff9629"],label:"orange")
                    let layer=HighlightLayer(id:"l\(layerSerial)",label:"the way to \(next.title)",style:style,count:1,document:current.document)
                    layers.append(layer)
                    try await send(style.paints(for:[match]),layer:layer,page:current)
                    // A moment to see the lit link before the next article opens.
                    try await Task.sleep(for:.milliseconds(800))
                }
            }
            try checkpoint(token)
            page=try await navigate(path:next.path,token:token)
            guard page != nil else {say("I couldn't open “\(next.title)”, so the walk stopped there.");return}
        }
        updateConnection(line) {$0.reached=chain.count-1}
        status="Arrived at \(chain[chain.count-1].title)"
        amend(line,trail:"walked")
    }

    /// The link on the page that leads to the next stop: the very link the chain was found through,
    /// else any link to that article.
    private func routeLink(to next:ConnectionStop,on page:CrawlerPageMap)->CrawlerPageItem? {
        func path(_ href:String?)->String? {
            guard let href,let base=crawler?.intelligence.browser?.webView?.url,let url=URL(string:href,relativeTo:base)?.absoluteURL else {return nil}
            if url.scheme == "atlas",url.host == base.host {return String(url.path.dropFirst())}
            return OfflineURL.localWikipediaPath(url)
        }
        if let via=next.via,let link=page.links.first(where:{path($0.href) == via}) {return link}
        let names=[next.title]+(next.via.map {[ArticleLinks.destinationTitle($0)]} ?? [])
        return page.links.first {link in names.contains {ArticleLinks.points(link.href,to:$0)}}
    }

    /// Walks a found chain again from its start.
    func walkConnection(_ lineID:UUID) {
        guard let chain=lines.first(where:{$0.id == lineID})?.connection?.chain,chain.count>1 else {return}
        interrupt()
        busy=true;status="Walking the route…"
        let token=generation
        task=Task {[weak self] in
            guard let self else {return}
            defer {if token == self.generation {self.endRequest()}}
            do {try await self.walkRoute(chain,line:lineID,token:token)}
            catch is CancellationError {}
            catch {if token == self.generation {self.say(error.localizedDescription,isError:true)}}
        }
    }
    /// Continues the last connection search.
    func continueConnection() {
        var step=CompanionStep(action:"connect");step.result="more"
        if let index=lines.lastIndex(where:{$0.connection?.canContinue == true}) {lines[index].connection?.canContinue=false}
        run(CompanionPlan(steps:[step],local:true),saying:"Keep looking")
    }

    // MARK: Crawler modes

    private func hunt(_ phrase:String) {
        guard let crawler,crawler.ready else {say("Open an article first, then I'll hunt for it.");return}
        guard !phrase.isEmpty else {say("Which exact phrase should I hunt for?");return}
        crawler.target=phrase
        announcedHunt=nil
        crawler.start(hunt:true,preservingConversation:true)
        say("Hunting for “\(phrase)” on foot. I only see what's near me, so this can take a while. Say “stop” anytime.")
    }

    private func explore(_ topic:String) {
        guard let crawler,crawler.ready else {say("Open an article first; I'll start exploring from it.");return}
        guard !crawler.intelligence.model.isEmpty else {say("Exploring by meaning needs a chat model. Choose one in Ask.");return}
        guard !topic.isEmpty else {say("What should I look for?");return}
        crawler.target=topic
        crawler.start(hunt:false,semantic:true,preservingConversation:true)
        say("Exploring for “\(topic)”. I'll read as I walk, follow promising links and tell you what I find."+(rules.allowLinks ? "" : " You asked me to stay in this article, so I won't leave it."))
    }

    private func resume() {
        guard let crawler,crawler.active else {say("I'm not doing anything right now. Ask me to wander, hunt for a phrase or explore a topic.");return}
        if crawler.status == .found {crawler.findNext();announcedHunt=nil;say("Looking for the next one.");return}
        crawler.resume()
        say("Continuing.")
    }

    private func applyRule(_ step:CompanionStep,page:CrawlerPageMap?) {
        switch step.rule {
        case "stay":
            rules.allowLinks=false;crawler?.interruptAdvice();crawler?.restartAdvice()
            say("I'll stay in this article and won't follow links.")
        case "allowLinks":
            rules.allowLinks=true;crawler?.restartAdvice()
            say("I may follow links again.")
        case "clearRules":
            rules=CrawlerTravelRules();excludedSections=[];crawler?.restartAdvice()
            say("All travel rules cleared.")
        default:
            guard let place=step.place?.trimmingCharacters(in:.whitespacesAndNewlines),!place.isEmpty else {return}
            let name=PageQuery.normalizeSectionName(place)
            if let page,PageQueryEngine.sectionNames(page).contains(where:{$0.range(of:name,options:[.caseInsensitive,.diacriticInsensitive]) != nil}) {
                if !excludedSections.contains(where:{$0.caseInsensitiveCompare(name) == .orderedSame}) {excludedSections.append(name)}
                say("I'll skip the “\(name)” section from now on.")
            } else {
                rules.avoid(place);crawler?.interruptAdvice();crawler?.restartAdvice()
                say("I won't go to anything matching “\(place)”.")
            }
        }
    }

    // MARK: Clearing

    private func clear(_ target:String?) async {
        let wanted=(target ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let everything=wanted.isEmpty || ["all","everything","highlights","all highlights","the highlights","them","it"].contains(wanted)
        var removed:[HighlightLayer]
        if everything {
            removed=layers
        } else if ["last","latest","previous","last one","the last one","newest"].contains(wanted),let last=layers.last {
            removed=[last]
        } else {
            let colors=Set(HighlightStyle.parse(wanted)?.colors ?? [])
            removed=layers.filter {layer in
                layer.label.lowercased().contains(wanted) || layer.style.label.lowercased().contains(wanted) || !colors.isDisjoint(with:Set(layer.style.colors))
            }
        }
        guard !removed.isEmpty || everything else {
            say("I don't see highlights matching “\(target ?? "")”."+(layers.isEmpty ? " There are none right now." : " Current ones: "+layers.map {"\($0.style.label) \($0.label)"}.joined(separator:"; ")+"."))
            return
        }
        if everything {
            _ = try? await call("window.atlasTerrain?.clearLayers()")
            layers=[]
            say("Cleared all highlights.")
            return
        }
        for layer in removed {_ = try? await call("window.atlasTerrain?.removeLayer(id)",["id":layer.id])}
        let ids=Set(removed.map(\.id))
        layers.removeAll {ids.contains($0.id)}
        say(removed.count == 1 ? "Removed the \(removed[0].style.label) highlights (\(removed[0].label))." : "Removed \(removed.count) highlight layers.")
    }

    /// Clears one layer from the legend.
    func removeLayer(_ id:String) {
        Task {
            _ = try? await call("window.atlasTerrain?.removeLayer(id)",["id":id])
            layers.removeAll {$0.id == id}
        }
    }
    func clearAllLayers() {
        Task {
            _ = try? await call("window.atlasTerrain?.clearLayers()")
            layers=[]
        }
    }

    // MARK: Reading the whole article

    private func read(question:String,page:CrawlerPageMap?,token:UUID) async throws {
        guard let page=try await currentPage(page),let crawler else {return}
        let model=crawler.intelligence.model
        guard !model.isEmpty else {say("Reading the whole article needs a chat model. Choose one in Ask.");return}
        let key=model+":"+page.fingerprint
        let notes:String
        if let cached=articleNotes[key] {notes=cached}
        else {
            status="Reading the article…"
            notes=try await CompanionReader.notes(page:page,question:question,provider:crawler.intelligence.provider,model:model) {[weak self] done,total in
                Task {@MainActor in self?.status="Reading part \(min(done+1,total)) of \(total)…"}
            }
            try checkpoint(token)
            articleNotes[key]=notes
        }
        status="Thinking it over…"
        let answer=try await CompanionReader.answer(question:question,title:companionTitle,notes:notes,history:history(),provider:crawler.intelligence.provider,model:model)
        try checkpoint(token)
        let line=say(answer.text)
        amend(line,trail:"read all \(page.blocks.count) blocks")
        saveSources(answer.sources,page:page,reply:answer.text)
    }

    private func saveSources(_ ids:[String],page:CrawlerPageMap,reply:String) {
        let wanted=Set(ids)
        let blocks=page.blocks.filter {wanted.contains($0.id) && !$0.text.isEmpty}
        guard !blocks.isEmpty else {return}
        let matches=blocks.enumerated().map {index,block in
            PageMatch(range:.init(id:block.id,start:0,end:block.text.utf16.count,text:block.text),elementID:nil,text:block.text,rect:block.rect,order:index)
        }
        resultSerial += 1
        results.append(.init(id:"r\(resultSerial)",label:"passages behind my answer",query:nil,footing:nil,matches:matches,count:matches.count,
                             complete:true,frequencies:[],document:page.document,fingerprint:page.fingerprint))
        if results.count>12 {results.removeFirst(results.count-12)}
        focusResult="r\(resultSerial)"
    }

    /// The focus chip under the conversation: show the latest result again.
    func demonstrateFocused() {
        guard let focused else {return}
        var step=CompanionStep(action:"show");step.result=focused.id
        run(CompanionPlan(steps:[step],local:true),saying:"Show the \(focused.label) again")
    }

    // MARK: Page bridge

    private func call(_ script:String,_ arguments:[String:Any]=[:]) async throws -> Any? {
        guard let web=crawler?.webView else {throw AtlasError.articleUnavailable}
        return try await web.callAsyncJavaScript(script,arguments:arguments,in:nil,contentWorld:.defaultClient)
    }
    private func readPage() async throws -> CrawlerPageMap {
        let value=try await call("return window.atlasTerrain.pageMap()")
        return try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:value as Any))
    }
    private func jsonObject<T:Encodable>(_ value:T) throws -> Any {try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))}

    /// Current geometry for matches, in order. Nil entries are no longer on the page.
    private func rects(_ matches:[PageMatch],page:CrawlerPageMap) async throws -> [TerrainRect?] {
        var result:[TerrainRect?]=[]
        for start in stride(from:0,to:matches.count,by:3000) {
            let slice=matches[start..<min(matches.count,start+3000)]
            let values:[[String:Any]]=slice.map {match in
                if let range=match.range {return ["id":range.id,"start":range.start,"end":range.end]}
                return ["id":match.elementID ?? ""]
            }
            let raw=try await call("return window.atlasTerrain.pageResolve(values,revision)",["values":values,"revision":page.textRevision.map {$0 as Any} ?? NSNull()])
            guard let boxes=raw as? [Any] else {throw AIError.message("The article text changed. Ask me again and I'll map it fresh.")}
            for box in boxes {
                if let box=box as? [String:Any],let data=try? JSONSerialization.data(withJSONObject:box),let rect=try? JSONDecoder().decode(TerrainRect.self,from:data) {result.append(rect)}
                else {result.append(nil)}
            }
        }
        return result
    }
    private func freshRect(_ match:PageMatch,page:CrawlerPageMap) async -> TerrainRect? {
        (try? await rects([match],page:page))?.first ?? nil
    }
    private func freshCenter(_ match:PageMatch,page:CrawlerPageMap) async -> DocumentPosition? {
        await freshRect(match,page:page)?.center
    }

    // MARK: Observation hooks used by the crawler

    func inspect(_ observation:CrawlerObservation) async {}
    func permitsSection(_ item:CrawlerTerrain)->Bool {
        !excludedSections.contains {blocked in (item.section ?? "").range(of:blocked,options:[.caseInsensitive,.diacriticInsensitive]) != nil}
    }
    func allowedObservation(_ observation:CrawlerObservation)->CrawlerObservation {
        let terrain=observation.terrain.filter {permitsSection($0)}
        return .init(document:observation.document,revision:observation.revision,center:observation.center,radius:observation.radius,viewport:observation.viewport,
                     documentWidth:observation.documentWidth,documentHeight:observation.documentHeight,terrain:terrain,truncated:observation.truncated)
    }

    // MARK: Formatting

    static func format(_ value:Int)->String {
        let formatter=NumberFormatter();formatter.numberStyle = .decimal
        return formatter.string(from:NSNumber(value:value)) ?? String(value)
    }
    static func clip(_ text:String,_ limit:Int)->String {
        let clean=text.replacingOccurrences(of:"\n",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        return clean.count<=limit ? clean : String(clean.prefix(limit))+"…"
    }
    static func capitalized(_ text:String)->String {text.prefix(1).uppercased()+text.dropFirst()}
    /// "42 adjectives", but "the 3 longest words" stays as it is.
    static func counted(_ n:Int,_ label:String)->String {label.hasPrefix("the ") ? label : "\(format(n)) \(label)"}
}
