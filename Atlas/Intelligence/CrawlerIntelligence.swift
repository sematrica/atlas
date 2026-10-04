import Foundation
import Observation
import AtlasCore

@MainActor @Observable
final class CrawlerIntelligence {
    @ObservationIgnored weak var crawler:CrawlerController?
    @ObservationIgnored weak var browser:BrowserModel?
    @ObservationIgnored var provider:any LLMProvider=OllamaProvider()
    var model=""
    var mission=""
    var path:[CrawlerJourneyEntry]=[]
    var decision=""
    var prompt=""
    var latency=0.0
    var confidence=0.0
    var evaluations=0
    var sections:Set<String>=[]
    var discovery:CrawlerDiscovery?
    var failed=false
    var transitioning=false
    var note=""
    @ObservationIgnored var persist:((CrawlerDiscovery) async -> Void)?
    @ObservationIgnored private var task:Task<Void,Never>?
    @ObservationIgnored private var token=UUID()
    @ObservationIgnored private var pendingLink:CrawlerTerrain?
    @ObservationIgnored private var links:Set<String>=[]
    @ObservationIgnored private var backstack:[ArticleID]=[]
    @ObservationIgnored private var started=Date()
    init(crawler:CrawlerController) {self.crawler=crawler}
    func cancel() {token=UUID();task?.cancel();task=nil;pendingLink=nil;transitioning=false}
    func begin(reset:Bool) {
        cancel()
        guard let crawler else {return}
        if reset {mission=crawler.target;path=[];links=[];backstack=[];sections=[];evaluations=0;discovery=nil;failed=false;note="";started=Date()}
        if let article=browser?.currentArticleID {path.append(.init(article:article,title:browser?.title ?? "Wikipedia"))}
        let current=token
        task=Task { [weak self] in
            guard let self else {return}
            while !Task.isCancelled && current == self.token {
                do {
                    try await Task.sleep(for:.seconds(4))
                    guard let crawler=self.crawler,crawler.active else {return}
                    if [.paused,.found,.spawning].contains(crawler.status) {continue}
                    if self.failed {continue}
                    if self.evaluations>=60 || self.path.count>=20 || Date().timeIntervalSince(self.started)>1200 {
                        self.fail();continue
                    }
                    guard let observation=crawler.agent.observation,!observation.terrain.isEmpty else {continue}
                    for heading in observation.terrain where heading.kind == .heading {self.sections.insert(observation.document+heading.group)}
                    if let link=self.pendingLink {
                        if crawler.agent.state.position.distance(to:link.rect.center)<18 {
                            self.pendingLink=nil;crawler.inspectFor(0.4)
                            try await Task.sleep(for:.milliseconds(400));try Task.checkCancellation()
                            if try await self.follow(link) {return}
                        } else {crawler.steer(to:link.rect.center)}
                        continue
                    }
                    self.prompt=CrawlerReasoning.prompt(mission:self.mission,title:self.browser?.title ?? "Wikipedia",observation:observation,path:self.path)
                    // A deliberate inspection keeps evidence in view while reasoning; rendering never waits on HTTP.
                    crawler.inspectFor(120)
                    let began=Date()
                    let raw=try await self.provider.generate(model:self.model,prompt:self.prompt,json:true)
                    try Task.checkCancellation();guard current == self.token else {return}
                    self.latency=Date().timeIntervalSince(began);self.evaluations += 1
                    guard let latest=crawler.agent.observation else {continue}
                    let action=try CrawlerReasoning.parse(raw,observation:observation)
                    guard action.validate(in:latest),latest.revision == observation.revision,latest.document == observation.document else {crawler.inspectFor(0);continue}
                    self.decision=raw;self.confidence=action.confidence ?? 0
                    if action.action == "reportFound",let quote=action.quote {
                        let secondPrompt=CrawlerReasoning.prompt(mission:self.mission,title:self.browser?.title ?? "Wikipedia",observation:latest,path:self.path,confirmation:quote)
                        self.prompt=secondPrompt
                        let second=try await self.provider.generate(model:self.model,prompt:secondPrompt,json:true)
                        try Task.checkCancellation();guard current == self.token,let currentObservation=crawler.agent.observation else {return}
                        let confirmation=try CrawlerReasoning.parse(second,observation:currentObservation)
                        guard confirmation.action == "reportFound",confirmation.quote == quote,crawler.confirmDiscovery(quote) else {crawler.inspectFor(0);continue}
                        if let article=self.browser?.currentArticleID {
                            let result=CrawlerDiscovery(article:article,title:self.browser?.title ?? "Wikipedia",section:latest.terrain.filter {$0.kind == .heading}.map(\.text).joined(),quote:quote,reason:String((confirmation.reason ?? action.reason ?? "Locally observed supporting evidence").prefix(1000)),path:self.path)
                            self.discovery=result
                            if let persist=self.persist {await persist(result)}
                        }
                    } else {
                        crawler.inspectFor(0)
                        switch action.action {
                        case "followLink":
                            if let item=latest.terrain.first(where:{$0.id == action.elementID}),let href=item.href,!self.links.contains(latest.document+href) {self.pendingLink=item;crawler.steer(to:item.rect.center)}
                        case "approach":if let item=latest.terrain.first(where:{$0.id == action.elementID}) {crawler.steer(to:item.rect.center)}
                        case "inspect","markInteresting":crawler.inspectFor(2)
                        case "turnAround":
                            if let point=crawler.agent.memory.recentPositions.dropLast().last {crawler.steer(to:point)}
                        case "backtrack":if try await self.backtrack() {return}
                        default:break
                        }
                    }
                    self.note=""
                } catch {
                    if Task.isCancelled || current != self.token {return}
                    self.crawler?.inspectFor(0);self.note="Local reasoning unavailable or action rejected: \(error.localizedDescription). Procedural exploration continues."
                    self.evaluations += 1
                }
            }
        }
    }
    private func follow(_ link:CrawlerTerrain) async throws -> Bool {
        guard let browser,let base=browser.webView?.url,let href=link.href,
              let url=URL(string:href,relativeTo:base)?.absoluteURL,let provider=browser.provider else {return false}
        let path:String
        if url.scheme == "atlas",url.host == base.host {path=String(url.path.dropFirst())}
        else if let local=OfflineURL.localWikipediaPath(url) {path=local}
        else {note="External link ignored.";return false}
        let info=try await provider.info(path:path)
        guard info.mimeType.contains("html"),info.path != browser.currentArticleID?.path,
              self.path.filter({$0.article.path == info.path}).count<2 else {note="Already explored this route.";links.insert(base.absoluteString+href);return false}
        if let current=browser.currentArticleID {backstack.append(current)}
        links.insert(base.absoluteString+href);transitioning=true;browser.navigate(info.path);return true
    }
    func didMove() {
        guard let link=pendingLink,let crawler,crawler.agent.state.position.distance(to:link.rect.center)<18 else {return}
        crawler.inspectFor(5)
    }
    private func backtrack() async throws -> Bool {
        guard let article=backstack.popLast(),let browser else {return false}
        transitioning=true;browser.navigate(article.path);return true
    }
    func arrived() {
        guard transitioning,let crawler else {return}
        transitioning=false;crawler.target=mission;crawler.start(hunt:false,semantic:true,preserveExpedition:true)
    }
    func navigationFailed() {cancel();note="The local destination could not be opened. Choose another article and restart the mission."}
    private func fail() {failed=true;note="No sufficiently strong evidence was discovered. Continue exploring or choose a different starting article.";crawler?.pause()}
    func continueExploring() {failed=false;evaluations=0;started=Date();crawler?.resume()}
}
