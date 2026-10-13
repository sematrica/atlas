import AppKit
import WebKit
import Observation
import AtlasCore

@MainActor @Observable
final class CrawlerController:NSObject,CrawlerPerception,WKScriptMessageHandler {
    @ObservationIgnored lazy var intelligence=CrawlerIntelligence(crawler:self)
    @ObservationIgnored lazy var conversation=CrawlerConversation(crawler:self)
    var target=""
    var autoFollow=true
    var debug=false
    /// Words under the spider's feet get a glowing box, fading after it moves on.
    var touchGlow=true {didSet {if !touchGlow {touchMarks=[:];webView?.evaluateJavaScript("window.atlasTerrain?.clearTouch()",in:nil,in:.defaultClient){_ in};renderer?.needsDisplay=true}}}
    /// How the creature and its touch boxes are drawn; remembered between launches.
    var look=CreatureLook(rawValue:UserDefaults.standard.string(forKey:"atlas.crawler.look") ?? "") ?? .constellation {
        didSet {UserDefaults.standard.set(look.rawValue,forKey:"atlas.crawler.look");renderer?.needsDisplay=true}
    }
    /// Words the feet are touching or touched recently, keyed by word or link.
    @ObservationIgnored private(set) var touchMarks:[String:TouchMark]=[:]
    @ObservationIgnored private var lastTouchScan=0.0
    var radius=140.0
    var ready=false
    var status:CrawlerBehavior = .idle
    var inspector=""
    var error:String?
    @ObservationIgnored private(set) var agent=ProceduralCrawlerAgent()
    @ObservationIgnored private(set) var legs=CrawlerLegController()
    @ObservationIgnored private(set) var anchors:[TerrainAnchor]=[]
    @ObservationIgnored var viewport=TerrainRect(x:0,y:0,width:1,height:1)
    @ObservationIgnored weak var webView:WKWebView?
    @ObservationIgnored weak var renderer:CrawlerRenderer?
    @ObservationIgnored private var senses:Task<Void,Never>?
    @ObservationIgnored private var epoch=UUID()
    @ObservationIgnored private var highlighted:String?
    @ObservationIgnored var reduceMotion=false
    @ObservationIgnored private(set) var perceptionMilliseconds=0.0
    /// Only these points may hold a foot (a noun-only walk, for example).
    @ObservationIgnored var pageFootholds:[TerrainAnchor]?
    /// A temporary pace for companion dashes and sweeps; nil uses the conversation's speed.
    @ObservationIgnored var travelSpeed:Double?
    @ObservationIgnored private var settlingTime=0.0
    var active:Bool {status != .idle}
    func attach(_ web:WKWebView) {webView=web}
    func prepare() async {
        guard let webView else {return};let document=webView.url
        do {
            _ = try await webView.evaluateJavaScript(DocumentGeometryScript.source,in:nil,contentWorld:.defaultClient)
            guard webView.url == document else {return}
            ready=true;error=nil;intelligence.arrived();conversation.pageArrived()
        } catch {self.error="Document terrain is unavailable. Reload this article."}
    }
    func navigationStarted() {
        conversation.pageWillChange()
        stopCreature(preserveExpedition:intelligence.transitioning)
        ready=false
    }
    /// Starts a creature. A plan or a semantic expedition passes `preservingConversation`
    /// so starting the spider does not cancel the request that asked for it.
    func start(hunt:Bool,semantic:Bool=false,preserveExpedition:Bool=false,preservingConversation:Bool=false) {
        guard ready,let webView else {return}
        let text=target
        guard !(hunt || semantic) || !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return}
        if !preservingConversation {conversation.interrupt()}
        stopCreature(preserveExpedition:preserveExpedition);epoch=UUID();let token=epoch
        reduceMotion=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let p=DocumentPosition(x:max(35,viewport.x+min(140,viewport.width*0.2)),y:viewport.y+90)
        agent.start(position:p,mission:semantic ? .semanticHunt(text) : hunt ? .stringHunt(text) : .freeCrawl,seed:UInt64(truncatingIfNeeded:Int(Date().timeIntervalSince1970*1000)))
        legs.reset(at:p);status=agent.state.behavior
        renderer?.startAnimation()
        senses=Task { [weak self,weak webView] in
            while !Task.isCancelled {
                guard let self,let webView,self.epoch == token else {return}
                do {
                    try await self.refreshPerception()
                    guard self.epoch == token,!Task.isCancelled else {return}
                    if self.touchGlow {
                        _ = try? await webView.callAsyncJavaScript("return window.atlasTerrain?.touch(points,tint)",arguments:["points":self.touchPoints(),"tint":self.look.touchTint],in:nil,contentWorld:.defaultClient)
                        if self.status == .paused {self.scanTouches(force:true);self.renderer?.needsDisplay=true}
                    }
                    if self.autoFollow && ![.paused,.found,.idle].contains(self.status) {
                        _ = try await webView.callAsyncJavaScript("window.atlasTerrain?.follow(x,y,smooth)",arguments:["x":self.agent.state.position.x,"y":self.agent.state.position.y,"smooth":!self.reduceMotion],in:nil,contentWorld:.defaultClient)
                    }
                } catch {
                    guard self.epoch == token,!Task.isCancelled else {return}
                    self.agent.pause();self.status = .paused;self.error="Terrain observation stopped. Resume or reload the article."
                }
                let pace=self.travelSpeed ?? self.conversation.speed
                do {try await Task.sleep(for:.milliseconds(Int(max(45,min(125,self.radius*300/max(45,pace))))))}catch{return}
            }
        }
        if semantic {intelligence.begin(reset:!preserveExpedition)}
    }
    /// Planted feet in document coordinates.
    private func touchPoints()->[[String:Any]] {
        let body=agent.state.position
        return legs.legs.indices.filter {!legs.legs[$0].isStepping}.map {
            let foot=legs.drawnFoot($0,body:body)
            return ["x":foot.x,"y":foot.y]
        }
    }
    static let touchFade=1.6
    /// Full strength while touched, then a fade.
    static func touchAlpha(_ age:Double)->Double {age<0.2 ? 1 : max(0,1-(age-0.2)/(touchFade-0.2))}
    var hasFadingTouches:Bool {
        let now=ProcessInfo.processInfo.systemUptime
        return touchMarks.values.contains {now-$0.time>0.2 && now-$0.time<Self.touchFade}
    }
    /// Finds the words (or whole links) under planted feet in the current observation.
    func scanTouches(force:Bool=false) {
        let now=ProcessInfo.processInfo.systemUptime
        guard touchGlow,force || now-lastTouchScan>=0.05 else {return}
        lastTouchScan=now
        touchMarks=touchMarks.filter {now-$0.value.time<Self.touchFade}
        guard let observation=agent.observation else {return}
        let words=observation.terrain.filter {!$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        guard !words.isEmpty else {return}
        let byID=Dictionary(words.map {($0.id,$0)},uniquingKeysWith:{first,_ in first})
        let body=agent.state.position
        for i in legs.legs.indices where !legs.legs[i].isStepping {
            let foot=legs.drawnFoot(i,body:body)
            var hit=legs.legs[i].anchorID.flatMap {byID[String($0.dropLast())]}
            if hit == nil {
                hit=words.first {TerrainRect(x:$0.rect.x-3,y:$0.rect.y-3,width:$0.rect.width+6,height:$0.rect.height+6).contains(foot)}
            }
            guard let item=hit else {continue}
            let (key,rect)=Self.region(of:item,in:words)
            if var mark=touchMarks[key] {mark.time=now;mark.rect=rect;touchMarks[key]=mark;continue}
            touchMarks[key]=TouchMark(rect:rect,style:TouchMark.style(for:key,kind:item.kind),time:now)
        }
    }
    /// A word's box without its trailing space; a link's box spans all its visible words on that line.
    static func region(of item:CrawlerTerrain,in words:[CrawlerTerrain])->(String,TerrainRect) {
        func trimmed(_ word:CrawlerTerrain)->TerrainRect {
            let text=word.text,kept=text.trimmingCharacters(in:.whitespacesAndNewlines).count
            let width=text.isEmpty ? word.rect.width : word.rect.width*Double(kept)/Double(max(1,text.count))
            return .init(x:word.rect.x,y:word.rect.y,width:width,height:word.rect.height)
        }
        guard item.kind == .link,let href=item.href else {return (item.id,trimmed(item))}
        let line=words.filter {$0.group == item.group && $0.href == href && abs($0.rect.y-item.rect.y)<item.rect.height*0.5}
        let boxes=line.map(trimmed)
        let left=boxes.map(\.x).min() ?? item.rect.x,top=boxes.map(\.y).min() ?? item.rect.y
        let right=boxes.map {$0.x+$0.width}.max() ?? item.rect.x+item.rect.width
        let bottom=boxes.map {$0.y+$0.height}.max() ?? item.rect.y+item.rect.height
        return (item.group+"|"+href+"|"+String(Int(item.rect.y)),.init(x:left,y:top,width:right-left,height:bottom-top))
    }
    func inspectFor(_ seconds:Double) {guard active,status != .paused else {return};agent.inspect(for:seconds);status=agent.state.behavior}
    func setGuidanceSuppressed(_ value:Bool) {agent.suppressHunt(value)}
    func guide(to position:DocumentPosition) {agent.guide(to:position);status=agent.state.behavior;renderer?.startAnimation()}
    func endGuidedMovement() {agent.endGuidance();agent.suppressHunt(conversation.isGuiding)}
    /// The companion is about to move the spider: semantic advice pauses and hunts yield.
    func takeControl() {
        intelligence.cancel()
        agent.suppressHunt(true)
        if status == .found {clearHighlight();agent.findNext()}
        renderer?.startAnimation()
    }
    /// The companion is done; the spider rests where it stopped.
    func releaseControl() {
        agent.endGuidance();agent.suppressHunt(false);pageFootholds=nil;travelSpeed=nil
        status=agent.state.behavior
    }
    func interruptAdvice() {
        intelligence.cancel()
        if status == .inspecting {agent.inspect(for:0)}
    }
    func restartAdvice() {
        if case .semanticHunt=agent.state.mission,active,status != .paused,!conversation.isGuiding {intelligence.begin(reset:false,recordArrival:false)}
    }
    func plantPageFeet(_ anchors:[TerrainAnchor]) -> Bool {
        guard legs.plant(body:agent.state.position,anchors:anchors) else {return false}
        pageFootholds=anchors;return true
    }
    func steer(to position:DocumentPosition) {agent.steer(to:position)}
    func confirmDiscovery(_ quote:String)->Bool {agent.confirmDiscovery(quote)}
    func refreshPerception() async throws {
        let token=epoch,began=Date()
        let sample=try await observe(around:agent.state.position,radius:radius)
        guard epoch == token else {return}
        perceptionMilliseconds=Date().timeIntervalSince(began)*1000
        viewport=sample.viewport;agent.perceive(sample);anchors=agent.observation?.anchors ?? [];status=agent.state.behavior;updateInspector()
        scanTouches()
        await conversation.inspect(sample)
    }
    func observe(around position:DocumentPosition,radius:Double) async throws -> CrawlerObservation {
        guard let webView else {throw AtlasError.articleUnavailable}
        let value=try await webView.callAsyncJavaScript("return window.atlasTerrain.observe({x:x,y:y},radius)",arguments:["x":position.x,"y":position.y,"radius":radius],in:nil,contentWorld:.defaultClient)
        let data=try JSONSerialization.data(withJSONObject:value as Any)
        guard data.count<128*1024 else {throw AtlasError.articleUnavailable}
        return try JSONDecoder().decode(CrawlerObservation.self,from:data)
    }
    func tick(dt:Double) {
        guard active else {return}
        if status == .paused {
            // The body is at rest, but feet still in flight finish their step.
            legs.advance(body:agent.state.position,velocity:.zero,anchors:pageFootholds ?? anchors,
                         dt:min(dt,0.05),reduceMotion:reduceMotion,strict:pageFootholds != nil)
            settlingTime += min(dt,0.05)
            scanTouches()
            if settlingTime>0.45 && !legs.legs.contains(where:\.isStepping) && !hasFadingTouches {renderer?.stopAnimation()}
            return
        }
        settlingTime=0
        let pace=travelSpeed ?? conversation.speed
        let before=status
        agent.advance(dt:dt,speed:pageFootholds == nil ? pace : min(90,pace),reduceMotion:reduceMotion)
        intelligence.didMove()
        legs.advance(body:agent.state.position,velocity:agent.state.velocity,anchors:pageFootholds ?? anchors,dt:min(dt,0.05),reduceMotion:reduceMotion,strict:pageFootholds != nil)
        scanTouches()
        if status != agent.state.behavior {status=agent.state.behavior}
        if highlighted != nil,agent.state.match == nil {clearHighlight()}
        if status == .found,let match=agent.state.match,highlighted != match.key {
            highlighted=match.key
            webView?.callAsyncJavaScript("return window.atlasTerrain.highlight(ids,firstOffset,lastOffset)",arguments:["ids":match.terrainIDs,"firstOffset":match.firstOffset,"lastOffset":match.lastOffset],in:nil,in:.defaultClient) { [weak self] result in
                if case .failure = result {self?.error="Found the phrase, but its highlight could not be applied."}
            }
            if before != .found,case .stringHunt=agent.state.mission {conversation.huntFound(match.text)}
        }
    }
    /// User-facing pause (toolbar, Stop button): cancels the companion's request too.
    func pause() {conversation.interrupt();pauseCreature()}
    /// Holds the spider still without touching the conversation.
    func pauseCreature() {intelligence.cancel();agent.pause();status=agent.state.behavior;renderer?.stopAnimation();updateInspector()}
    func resume() {guard active else {return};agent.resume();status=agent.state.behavior;renderer?.startAnimation();error=nil;restartAdvice()}
    func findNext() {clearHighlight();agent.findNext();status=agent.state.behavior;renderer?.startAnimation()}
    func freeAfterFound() {clearHighlight();agent.resumeFreeCrawl();status=agent.state.behavior}
    /// User-facing stop (toolbar, Escape): ends the creature and the companion's request.
    func stop() {conversation.interrupt();stopCreature(preserveExpedition:false)}
    func stopCreature(preserveExpedition:Bool) {
        if !preserveExpedition {intelligence.cancel()}
        epoch=UUID();senses?.cancel();senses=nil;agent.stop();status = .idle;renderer?.stopAnimation();clearHighlight();error=nil
        pageFootholds=nil;travelSpeed=nil;touchMarks=[:]
    }
    private func clearHighlight() {
        highlighted=nil
        webView?.evaluateJavaScript("window.atlasTerrain?.clear()",in:nil,in:.defaultClient){_ in}
    }
    private func updateInspector() {
        let s=agent.state,observed=agent.observation?.terrain.map(\.text).joined() ?? ""
        let mission:String
        switch s.mission {case .stringHunt(let target):mission="String Hunt: \(target)";case .semanticHunt(let target):mission="Semantic Hunt: \(target)";case .freeCrawl:mission="Free Crawl"}
        inspector="State: \(s.behavior.rawValue)\nMission: \(mission)\nPosition: \(Int(s.position.x)), \(Int(s.position.y)) · Radius: \(Int(radius))\nDirection: \(Int(s.velocity.x)), \(Int(s.velocity.y))\nVisited regions: \(agent.memory.visited.count) · Observations: \(agent.memory.observationCount) · Coverage: \(Int(agent.navigator.coverage*100))%\nPerception: \(Int(perceptionMilliseconds)) ms · \(agent.observation?.terrain.count ?? 0) fragments\nTarget coordinates: \(s.match == nil ? "unknown" : "locally observed")\nObserved text:\n\(observed.prefix(2400))"
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard message.frameInfo.isMainFrame,message.frameInfo.request.url?.host == webView?.url?.host,
              let body=message.body as? [String:Any],let raw=body["viewport"],
              let data=try? JSONSerialization.data(withJSONObject:raw),let rect=try? JSONDecoder().decode(TerrainRect.self,from:data) else {return}
        viewport=rect;renderer?.needsDisplay=true
    }
}

/// The creature's drawing style.
enum CreatureLook:String,CaseIterable,Identifiable {
    /// A lattice of light in a dark crystal, with an orange core (the default).
    case constellation
    /// Cyan limbs, pink joints and a boxy body.
    case neon
    /// The original amber mechanical spider.
    case mechanical
    var id:String {rawValue}
    var title:String {
        switch self {
        case .constellation: "Constellation"
        case .neon: "Neon"
        case .mechanical: "Mechanical"
        }
    }
    /// The glow color of touched letters, as "r,g,b" for the page script.
    var touchTint:String {
        switch self {
        case .constellation: "255,150,40"
        case .neon: "64,236,255"
        case .mechanical: "224,186,112"
        }
    }
}

/// A word or link the spider touched, drawn as a glowing box on the overlay.
struct TouchMark {
    enum Style:Int {case cyanOutline,blueOutline,pinkFill,blueFill,cyanFill}
    var rect:TerrainRect
    let style:Style
    var time:Double
    /// Mostly plain outlines, links set apart, and an occasional filled box, stable per word.
    /// Each look maps these to its own colors.
    static func style(for key:String,kind:TerrainKind)->Style {
        let hash=key.unicodeScalars.reduce(UInt32(2166136261)) {($0 ^ $1.value) &* 16777619}
        switch hash%9 {
        case 0: return .pinkFill
        case 1: return .blueFill
        case 2: return .cyanFill
        default: return kind == .link || kind == .citation ? .blueOutline : .cyanOutline
        }
    }
}
