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
    /// Letters under the spider's feet and body glow, and fade after it moves on.
    var touchGlow=true {didSet {if !touchGlow {webView?.evaluateJavaScript("window.atlasTerrain?.clearTouch()",in:nil,in:.defaultClient){_ in}}}}
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
                        _ = try? await webView.callAsyncJavaScript("return window.atlasTerrain?.touch(points)",arguments:["points":self.touchPoints()],in:nil,contentWorld:.defaultClient)
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
    /// Planted feet, plus a few points along the body, in document coordinates.
    private func touchPoints()->[[String:Any]] {
        let body=agent.state.position
        var points:[[String:Any]]=legs.legs.indices.filter {!legs.legs[$0].isStepping}.map {
            let foot=legs.drawnFoot($0,body:body)
            return ["x":foot.x,"y":foot.y]
        }
        let dx=cos(legs.heading)*8,dy=sin(legs.heading)*8
        for step in [-1.0,0,1] {points.append(["x":body.x+dx*step,"y":body.y+dy*step,"body":true])}
        return points
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
            if settlingTime>0.45 && !legs.legs.contains(where:\.isStepping) {renderer?.stopAnimation()}
            return
        }
        settlingTime=0
        let pace=travelSpeed ?? conversation.speed
        let before=status
        agent.advance(dt:dt,speed:pageFootholds == nil ? pace : min(90,pace),reduceMotion:reduceMotion)
        intelligence.didMove()
        legs.advance(body:agent.state.position,velocity:agent.state.velocity,anchors:pageFootholds ?? anchors,dt:min(dt,0.05),reduceMotion:reduceMotion,strict:pageFootholds != nil)
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
        pageFootholds=nil;travelSpeed=nil
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
