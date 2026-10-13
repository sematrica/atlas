import AppKit
import WebKit
import AtlasCore

// Compiled against the actual application BrowserModel and OfflineWebView sources.
@main
@MainActor
struct BrowserSmoke {
    // Keep synthetic AppKit windows alive until the smoke process exits. Closing
    // one while WebKit and the crawler display link are finishing a transaction
    // can crash AppKit's window transform animation in a headless run.
    private static var retainedWindows:[NSWindow]=[]
    static func main() {
        let application=NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task {
            do { try await run(); print("WEBKIT OFFLINE SMOKE PASSED"); exit(0) }
            catch { fputs("WEBKIT SMOKE FAILED: \(error)\n",stderr); exit(1) }
        }
        application.run()
    }
    enum Failure: Error { case check(String) }
    static func require(_ value: Bool,_ message:String) throws { if !value { throw Failure.check(message) } }
    static func waitUntil(attempts:Int=200,_ check: @escaping @MainActor () async throws -> Bool) async throws {
        for _ in 0..<attempts {
            if try await check() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        throw Failure.check("Timed out waiting for WebKit")
    }
    static func js(_ web:WKWebView,_ script:String) async throws -> Any? {
        try await web.evaluateJavaScript(script,in:nil,contentWorld:.defaultClient)
    }
    static func run() async throws {
        let emptyBrowser=BrowserModel()
        let emptyChat=emptyBrowser.crawler.conversation
        emptyBrowser.crawler.intelligence.provider=NoArticleChatProvider()
        emptyBrowser.crawler.intelligence.model="test"
        for greeting in ["hello","hi","Can we talk about music?"] {
            emptyChat.talk(greeting)
            try await waitUntil {!emptyChat.companionBusy}
            try require(emptyChat.lines.last?.text == "Hello! We can talk without an article open.","Empty-page chat incorrectly required a tool decision")
            try require(!emptyBrowser.crawler.active,"Ordinary chat started the crawler")
        }
        try require(emptyChat.companionTitle == "No article open","Empty-page header claims an article is open")
        print("NO-ARTICLE APP CHAT PASSED: hello, hi, follow-up, no tool planner or crawler spawn")
        try await exerciseStandaloneCompanion()
        try await exerciseEmbodiedSelection()
        try await exerciseStatisticsTool()
        if ProcessInfo.processInfo.environment["ATLAS_COMPANION_ONLY"] == "1" {return}
        let root=URL(fileURLWithPath:"/tmp/AtlasStage2LiveLibrary")
        let metadata=try LibraryLayout().establish(at:root)
        let access=try LibraryAccess(root:root,libraryID:metadata.id)
        let record=try PackageManifest(access:access).load().first {$0.state == .installed && $0.package.format == .zim}.unwrap()
        let model=BrowserModel()
        try await model.open(record:record,access:access)
        let web=try model.webView.unwrap()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:760),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        let surface=CrawlerSurface(webView:web,crawler:model.crawler)
        window.contentView=surface;window.orderFront(nil)
        try await waitUntil { web.url != nil && !web.isLoading }
        let results=try await model.provider!.search("Ray Charles",limit:10)
        let match=try results.first {$0.title == "Ray Charles"}.unwrap()
        model.select(match)
        try await waitUntil {
            guard !web.isLoading else { return false }
            return (try? await js(web,"document.body.innerText.includes('Ray Charles')") as? Bool) == true
        }
        try await waitUntil { (try? await js(web,"[...document.images].some(i=>i.complete && i.naturalWidth>0)") as? Bool) == true }
        let styles=try await js(web,"document.styleSheets.length") as? Int ?? 0
        try require(styles > 0,"Local stylesheets did not load")
        try await waitUntil { !model.headings.isEmpty }
        let firstURL=web.url
        let href=try await js(web,"[...document.querySelectorAll('a[href]')].map(a=>a.href).find(h=>h.startsWith('atlas:') && !h.includes('#') && h!==location.href && !h.includes('/-/') && !h.includes('/I/'))") as? String
        let target=try href.flatMap(URL.init(string:)).unwrap()
        _ = try await js(web,"[...document.querySelectorAll('a[href]')].find(a=>a.href===\(quoted(target.absoluteString)))?.click()")
        try await waitUntil { !web.isLoading && web.url != firstURL }
        try require(model.canGoBack,"Back history missing")
        model.back(); try await waitUntil { !web.isLoading && web.url == firstURL }
        try require(model.canGoForward,"Forward history missing")
        model.forward(); try await waitUntil { !web.isLoading && web.url != firstURL }
        // An explicit external navigation must be blocked before it reaches the network.
        let current=web.url
        web.load(URLRequest(url:URL(string:"https://example.com/atlas-offline-canary")!))
        try await waitUntil { model.message?.contains("External link blocked") == true }
        try require(web.url == current,"External navigation escaped the offline policy")
        print("WebKit: article, loaded image, \(styles) stylesheets, TOC, clicked link, Back, Forward, external block verified")
        if ProcessInfo.processInfo.environment["ATLAS_COMMAND_ONLY"] != "1" {try await exerciseCrawler(model:model,web:web,surface:surface,window:window,results:results)}
        try await exerciseCommands(model:model,web:web)
        model.close(); window.close()
    }
    static func exerciseStandaloneCompanion() async throws {
        let browser=BrowserModel()
        browser.title="Fixture article"
        let web=WKWebView(frame:NSRect(x:0,y:0,width:960,height:700))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        retainedWindows.append(window)
        window.contentView=web;window.orderFront(nil)
        browser.webView=web;browser.crawler.attach(web)
        web.loadHTMLString("<html><body><article><p>The beautiful red bird sings sweet songs.</p><h2>History</h2><p>A tall green tree grows beside the extraordinary forest.</p></article></body></html>",baseURL:nil)
        try await waitUntil {(try? await js(web,"document.body?.innerText.includes('beautiful')") as? Bool) == true}
        print("STANDALONE ARTICLE LOADED")
        await browser.crawler.prepare()
        try require(browser.crawler.ready,"Standalone article geometry was unavailable")
        print("STANDALONE GEOMETRY READY")
        let crawler=browser.crawler,chat=crawler.conversation
        crawler.autoFollow=false
        crawler.intelligence.provider=CompanionFixtureProvider();crawler.intelligence.model="test-companion"
        chat.talk("How many adjectives are in this article?")
        try await waitUntil {!chat.companionBusy}
        print("STANDALONE COUNT: ",chat.lines.last?.text ?? "none")
        let adjectives=try chat.companionResults.last.unwrap()
        try require(adjectives.count>0 && adjectives.title == "adjectives","Standalone adjective count failed: \(chat.lines.last?.text ?? "")")
        chat.talk("Create a sentence using all these adjectives.")
        try await waitUntil {!chat.companionBusy}
        print("STANDALONE COMPOSITION: ",chat.lines.last?.text ?? "none")
        let sentence=chat.lines.last?.text.lowercased() ?? ""
        try require(Set(adjectives.ranges.map {$0.text.lowercased()}).allSatisfy {sentence.contains($0)},"Creative reply did not receive focused adjective words")
        try require(chat.companionFocus == adjectives.id,"Creative reply replaced the adjective finding")
        chat.talk("What's the second longest word here?")
        try await waitUntil {!chat.companionBusy}
        print("STANDALONE RANK: ",chat.lines.last?.text ?? "none")
        let ranked=try chat.companionResults.last.unwrap()
        try require(ranked.title == "Word ranked 2 by length" && ranked.count == 1 && ranked.id != adjectives.id,"Fresh word ranking reused the adjective result: \(chat.lines.last?.text ?? "")")
        chat.talk("What do you think of this article?")
        try await waitUntil {!chat.companionBusy}
        print("STANDALONE OPINION: ",chat.lines.last?.text ?? "none")
        let evidence=try chat.companionResults.last.unwrap()
        try require(evidence.title == "Supporting passages" && evidence.id != ranked.id,"Natural article reply did not save supporting passages")
        chat.talk("Prove it.")
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.companionBusy && !chat.companionTouring}
        print("STANDALONE PROOF: ",chat.lines.last?.text ?? "none")
        let shown=try await js(web,"[...(CSS.highlights.get('atlas-page')||[])].map(r=>r.toString()).join('')") as? String ?? ""
        try require(shown.contains("bird sings"),"Proof did not show the current article evidence")
        if ProcessInfo.processInfo.environment["ATLAS_COMPANION_LIVE"] == "1" {
            chat.lines=[];chat.companionResults=[adjectives];chat.companionFocus=adjectives.id
            crawler.debug=true
            crawler.intelligence.provider=OllamaProvider();crawler.intelligence.model="llama3.1:latest"
            chat.talk("Create a sentence using all these adjectives.")
            try await waitUntil(attempts:1800) {!chat.companionBusy}
            let liveSentence=chat.lines.last?.text.lowercased() ?? ""
            print("LIVE COMPOSITION:",liveSentence)
            try require(Set(adjectives.ranges.map {$0.text.lowercased()}).allSatisfy {liveSentence.contains($0)},"Local model omitted saved adjective words in creative reply")
            try require(chat.companionFocus == adjectives.id,"Local router did not preserve the finding used for creative writing")
            chat.talk("What's the second longest word here?")
            try await waitUntil(attempts:1800) {!chat.companionBusy}
            print("LIVE RANK:",chat.lines.last?.text ?? "none")
            try require(chat.companionResults.last?.title == "Word ranked 2 by length" && chat.companionResults.last?.ranges.first?.text == "beautiful","Live router or planner returned the wrong whole-page word rank")
            print("LIVE COMPANION PASSED: natural composition and fresh ordinal ranking with llama3.1")
        }
        crawler.stop();browser.close();window.orderOut(nil)
        print("STANDALONE COMPANION PASSED: exact rank after adjectives, natural composition, grounded opinion, requested proof")
    }
    /// Exercises the actual WebKit text map, model decision, restricted feet,
    /// movement, and CSS highlight without requiring an installed ZIM fixture.
    static func exerciseEmbodiedSelection() async throws {
        let browser=BrowserModel()
        browser.title="Embodied fixture"
        let web=WKWebView(frame:NSRect(x:0,y:0,width:960,height:700))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        retainedWindows.append(window)
        let crawler=browser.crawler,chat=crawler.conversation
        window.contentView=CrawlerSurface(webView:web,crawler:crawler);window.orderFront(nil)
        browser.webView=web;crawler.attach(web);crawler.autoFollow=false
        crawler.intelligence.provider=EmbodiedFixtureProvider();crawler.intelligence.model="test-embodied"
        let linkedWords=Array(repeating:"Cats chase mice. Dogs chase birds. Ants carry crumbs. Bees visit flowers. Crows gather twigs. Bears catch fish.",count:5).joined(separator:" ")
        web.loadHTMLString("<html><body><article style='margin:24px;width:820px;font:18px/28px Helvetica'><p>\(linkedWords) Hippopotamuses gather.</p></article></body></html>",baseURL:nil)
        try await waitUntil {(try? await js(web,"document.body?.innerText.includes('Hippopotamuses')") as? Bool) == true}
        await crawler.prepare();try require(crawler.ready,"Embodied fixture has no document geometry")
        let page=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:try await js(web,"window.atlasTerrain.pageMap()") as Any))
        let longest=try CrawlerPageAnalysis.select(page,unit:"word",order:"longest").unwrap()
        let first=try CrawlerPageAnalysis.select(page,unit:"word",order:"first").unwrap()
        try require(longest.text.lowercased() == "hippopotamuses" && first.text == "Cats","Synthetic page word order is not stable")

        // Put the body on a real permitted foothold, then ask for the far target.
        let allowed=CrawlerPageAnalysis.ranges(page,unit:.word,footholds:["noun","verb"])
        let allowedJSON=String(data:try JSONEncoder().encode(allowed),encoding:.utf8)!
        let targets=try JSONDecoder().decode([CrawlerPageTarget].self,from:JSONSerialization.data(withJSONObject:try await js(web,"window.atlasTerrain.pageResolve(JSON.parse(\(quoted(allowedJSON))),\(page.revision))") as Any))
        let start=try targets.first.unwrap().rect.center
        crawler.start(hunt:false);crawler.guide(to:start)
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return crawler.agent.state.position.distance(to:start)<11}
        let before=crawler.agent.state.position
        chat.talk("Go to the longest word in this article but do so only stepping on nouns or verbs")
        var sawRestrictedFeet=false
        try await waitUntil(attempts:1600) {
            if let permitted=crawler.pageFootholds {
                sawRestrictedFeet=true
                try require(crawler.legs.legs.allSatisfy {leg in permitted.contains {$0.position == leg.to}},"Restricted movement planted a foot away from noun/verb source text")
            }
            for _ in 0..<6 {crawler.tick(dt:0.03)}
            return !chat.companionBusy && !chat.companionTouring
        }
        let longestMark=try await js(web,"[...(CSS.highlights.get('atlas-page')||[])].map(r=>r.toString()).join('')") as? String ?? ""
        try require(sawRestrictedFeet,"The companion ignored the noun/verb-only foothold constraint")
        try require(longestMark.lowercased() == longest.text.lowercased(),"The restricted tour failed to highlight its measured destination: \(chat.lines.last?.text ?? "")")
        try require(crawler.agent.state.position.distance(to:before)>40,"The crawler highlighted a distant word without moving to it")
        let longestCenter=try await resolvedCenter(longest,page:page,web:web)
        try require(crawler.agent.state.position.distance(to:longestCenter)<15,"The crawler did not reach the longest word")
        try require(crawler.pageFootholds == nil,"The completed tour left its noun/verb-only foot rule active")

        let afterLongest=crawler.agent.state.position
        chat.talk("Go to the first word of this article?")
        try await waitUntil(attempts:1600) {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.companionBusy && !chat.companionTouring}
        let firstMark=try await js(web,"[...(CSS.highlights.get('atlas-page')||[])].map(r=>r.toString()).join('')") as? String ?? ""
        try require(firstMark == first.text,"A request for the first word reused the old longest-word finding: \(chat.lines.last?.text ?? "")")
        try require(crawler.agent.state.position.distance(to:afterLongest)>40,"The crawler did not return to the first word")
        try require(crawler.pageFootholds == nil,"A fresh unrestricted request inherited the old foothold rule")
        print("EMBODIED SELECTION PASSED: restricted longest-word journey, exact highlight, fresh first-word journey")

        if ProcessInfo.processInfo.environment["ATLAS_EMBODIED_LIVE"] == "1" {
            chat.lines=[];chat.companionResults=[];chat.companionFocus=nil
            crawler.intelligence.provider=OllamaProvider();crawler.intelligence.model="llama3.1:latest"
            chat.talk("Go to the longest word in this article but do so only stepping on nouns or verbs")
            try await waitUntil(attempts:1800) {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.companionBusy && !chat.companionTouring}
            let liveLongest=try await js(web,"[...(CSS.highlights.get('atlas-page')||[])].map(r=>r.toString()).join('')") as? String ?? ""
            try require(liveLongest.lowercased() == longest.text.lowercased(),"llama3.1 failed to plan or execute the constrained destination: \(chat.lines.last?.text ?? "")")
            chat.talk("Go to the first word of this article?")
            try await waitUntil(attempts:1800) {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.companionBusy && !chat.companionTouring}
            let liveFirst=try await js(web,"[...(CSS.highlights.get('atlas-page')||[])].map(r=>r.toString()).join('')") as? String ?? ""
            try require(liveFirst == first.text,"llama3.1 treated the first-word request as the previous longest-word request: \(chat.lines.last?.text ?? "")")
            print("LIVE EMBODIED COMPANION PASSED: llama3.1 planned both commands through the real page tools")
            crawler.intelligence.provider=EmbodiedFixtureProvider();crawler.intelligence.model="test-embodied"
        }

        // The same request must fail honestly when eligible words are separated by
        // a gap wider than the crawler's connected foothold reach.
        crawler.stop()
        web.loadHTMLString("<html><body data-fixture='sparse'><article style='margin:24px;font:18px/28px Helvetica'><p>Cats chase mice.</p><p style='margin-top:550px'>Hippopotamuses gather.</p></article></body></html>",baseURL:nil)
        try await waitUntil {
            if web.isLoading {return false}
            return (try? await js(web,"document.body?.dataset.fixture === 'sparse'") as? Bool) == true
        }
        await crawler.prepare();try require(crawler.ready,"Sparse fixture has no document geometry")
        let sparse=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:try await js(web,"window.atlasTerrain.pageMap()") as Any))
        let sparseWords=CrawlerPageAnalysis.ranges(sparse,unit:.word,footholds:["noun","verb"])
        let sparseJSON=String(data:try JSONEncoder().encode(sparseWords),encoding:.utf8)!
        let sparseTargets=try JSONDecoder().decode([CrawlerPageTarget].self,from:JSONSerialization.data(withJSONObject:try await js(web,"window.atlasTerrain.pageResolve(JSON.parse(\(quoted(sparseJSON))),\(sparse.revision))") as Any))
        let sparseStart=try sparseTargets.first.unwrap().rect.center
        crawler.start(hunt:false);crawler.guide(to:sparseStart)
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return crawler.agent.state.position.distance(to:sparseStart)<11}
        chat.talk("Go to the longest word in this article but do so only stepping on nouns or verbs")
        try await waitUntil(attempts:500) {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.companionBusy && !chat.companionTouring}
        let failure=chat.lines.last?.text.lowercased() ?? ""
        let sparseMark=try await js(web,"CSS.highlights.get('atlas-page')?.size || 0") as? Int ?? 0
        try require(failure.contains("no connected route") && failure.contains("haven't relaxed"),"Disconnected noun/verb footholds did not produce an honest route failure: \(failure)")
        try require(sparseMark == 0,"The crawler highlighted an unreachable word")
        print("EMBODIED ROUTE FAILURE PASSED: no silent constraint relaxation or unreachable highlight")
        crawler.stop();browser.close();window.orderOut(nil)
    }
    /// Checks exact article statistics through the real rendered-page bridge.
    /// The fixture classifier intentionally says CHAT: an exact count must still
    /// reach the measurement tool, and the reply must disclose that choice.
    static func exerciseStatisticsTool() async throws {
        let browser=BrowserModel()
        browser.title="Letter-count fixture"
        let web=WKWebView(frame:NSRect(x:0,y:0,width:900,height:650))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        retainedWindows.append(window)
        let crawler=browser.crawler,chat=crawler.conversation
        window.contentView=CrawlerSurface(webView:web,crawler:crawler);window.orderFront(nil)
        browser.webView=web;crawler.attach(web);crawler.autoFollow=false
        crawler.intelligence.provider=StatisticsFixtureProvider();crawler.intelligence.model="test-statistics"
        web.loadHTMLString("<html><body><article><p>Abé Ω字 123!? &amp; X-ray.</p><p><em>façade</em> — ٤٢, NASA. Cafe\u{301}.</p><span style='display:none'>Hiddenletters</span></article></body></html>",baseURL:nil)
        try await waitUntil {(try? await js(web,"document.querySelector('article')?.innerText.includes('NASA')") as? Bool) == true}
        await crawler.prepare();try require(crawler.ready,"Statistics fixture has no document geometry")
        let page=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:try await js(web,"window.atlasTerrain.pageMap()") as Any))
        try require(!page.truncated && page.blocks.map(\.text).joined().contains("Cafe\u{301}"),"Statistics fixture text is incomplete or normalized unexpectedly")
        let before=crawler.agent.state.position
        chat.talk("how many letters in this article (exluding numbers and non-letter characters")
        try await waitUntil {!chat.companionBusy}
        let answer=chat.lines.last?.text.lowercased() ?? ""
        try require(answer.contains("23") && answer.contains("letter"),"Exact letter-count request did not use the page measurement: \(answer)")
        try require(!crawler.active && crawler.agent.state.position == before,"A count request moved the crawler")
        try require((try await js(web,"CSS.highlights.get('atlas-page')?.size || 0") as? Int ?? 0) == 0,"A count request highlighted article text")
        let activities=try chat.lines.last.unwrap().toolActivity
        try require(Set(activities.map(\.id)) == ["model","page","measure","words","links","crawler"],"Reply omitted a tool from the visible catalog")
        for id in ["model","page","measure"] {
            guard let item=activities.first(where:{$0.id == id}) else {throw Failure.check("Missing tool activity: \(id)")}
            if case .used=item.state {} else {throw Failure.check("Expected \(id) to be marked used")}
        }
        for id in ["words","links","crawler"] {
            guard let item=activities.first(where:{$0.id == id}) else {throw Failure.check("Missing tool activity: \(id)")}
            if case .idle=item.state {} else {throw Failure.check("Expected \(id) to be marked not used")}
        }

        chat.talk("How many digits are in this article?")
        try await waitUntil {!chat.companionBusy}
        let digitAnswer=chat.lines.last?.text.lowercased() ?? ""
        try require(digitAnswer.contains("5") && digitAnswer.contains("digit"),"A new count reused the prior letters result: \(digitAnswer)")
        try require(!crawler.active,"Switching measurement units moved the crawler")

        // A partial text map must not produce an apparently exact answer.
        _ = try await js(web,"window.__atlasOriginalPageMap=window.atlasTerrain.pageMap;window.atlasTerrain.pageMap=()=>({...window.__atlasOriginalPageMap(),textTruncated:true,truncated:true})")
        chat.talk("how many letters in this article (exluding numbers and non-letter characters")
        try await waitUntil {!chat.companionBusy}
        let incomplete=chat.lines.last?.text.lowercased() ?? ""
        try require(incomplete.contains("partial") || incomplete.contains("complete-map") || incomplete.contains("incomplete"),"Partial page text was reported as an exact count: \(incomplete)")
        guard let failedMeasure=chat.lines.last?.toolActivity.first(where:{$0.id == "measure"}) else {throw Failure.check("Partial-map reply omitted text statistics activity")}
        if case .failed=failedMeasure.state {} else {throw Failure.check("A partial article count did not mark text statistics as failed")}
        try require(!crawler.active,"A failed exact count moved the crawler")
        print("ARTICLE STATISTICS PASSED: Unicode letters only, explicit tool-use trace, no movement, incomplete-map refusal")
        crawler.stop();browser.close();window.orderOut(nil)
    }
    static func resolvedCenter(_ range:CrawlerPageRange,page:CrawlerPageMap,web:WKWebView) async throws -> DocumentPosition {
        let encoded=String(data:try JSONEncoder().encode([range]),encoding:.utf8)!
        let result=try JSONDecoder().decode([CrawlerPageTarget].self,from:JSONSerialization.data(withJSONObject:try await js(web,"window.atlasTerrain.pageResolve(JSON.parse(\(quoted(encoded))),\(page.revision))") as Any))
        return try result.first.unwrap().rect.center
    }
    static func exerciseCrawler(model:BrowserModel,web:WKWebView,surface:CrawlerSurface,window:NSWindow,results:[SearchResult]) async throws {
        for article in results.prefix(3) {
            model.select(article)
            try await waitUntil {model.crawler.ready && !web.isLoading}
            let crawler=model.crawler;crawler.autoFollow=false;crawler.start(hunt:false)
            try await Task.sleep(for:.seconds(1))
            let before=crawler.agent.state.position
            try await Task.sleep(for:.seconds(1))
            try require(crawler.agent.state.position.distance(to:before)>1,"Creature did not move on display link")
            try require(surface.overlay.renderedFrames>10,"Native overlay did not render")
            try require(crawler.legs.legs.count == 8,"Missing articulated legs")
            // Initial whitespace is valid terrain. Continue bounded sensing until the route reaches text.
            for _ in 0..<160 where !crawler.legs.legs.contains(where: {$0.anchorID != nil}) {
                try await crawler.refreshPerception()
                for _ in 0..<12 {crawler.tick(dt:0.05)}
            }
            try require(crawler.legs.legs.contains {$0.anchorID != nil},"Legs did not select real terrain anchors")
            try require(!(crawler.agent.observation?.terrain.isEmpty ?? true),"No real article terrain")
            crawler.pause();let paused=crawler.agent.state.position
            _ = try await js(web,"scrollBy(0,200)")
            try await Task.sleep(for:.milliseconds(300))
            try require(crawler.agent.state.position == paused,"Scrolling moved document coordinates")
            try require(crawler.viewport.y>0,"Scroll transform did not update")
            window.setContentSize(NSSize(width:950,height:700))
            try await Task.sleep(for:.milliseconds(300))
            try await crawler.refreshPerception()
            crawler.resume();crawler.autoFollow=true
            try await Task.sleep(for:.milliseconds(300))
            try require(crawler.status != .paused,"Resume failed")
            print("CRAWLER REAL ARTICLE: \(article.title), frames=\(surface.overlay.renderedFrames), fragments=\(crawler.agent.observation?.terrain.count ?? 0)")
            crawler.stop();try require(!crawler.active,"Stop must be immediate")
        }
        let main=try results.first {$0.title == "Ray Charles"}.unwrap();model.select(main)
        try await waitUntil {model.crawler.ready && !web.isLoading}
        _ = try await js(web,"scrollTo(0,0)")
        try await Task.sleep(for:.milliseconds(200))
        // Fixture selection may inspect the article. Production perception never receives these coordinates.
        let target=try await js(web,"""
          [...document.querySelectorAll('p')].filter(p=>p.getBoundingClientRect().top+scrollY>900 && p.getBoundingClientRect().top+scrollY<2000)
          .flatMap(p=>{const w=document.createTreeWalker(p,NodeFilter.SHOW_TEXT);let n,out=[];while(n=w.nextNode()){const m=n.data.match(/[A-Za-z][A-Za-z ,'-]{12,22}/);if(m)out.push(m[0].trim());}return out;})[0]
        """) as? String
        let crawler=model.crawler;crawler.target=try target.unwrap();crawler.autoFollow=false;crawler.start(hunt:true)
        try require(crawler.agent.state.match == nil,"Target position revealed at start")
        var sawSuspected=false
        // Accelerate only the simulation clock; every decision still requires actual bounded WebKit perception.
        for _ in 0..<1000 {
            try await crawler.refreshPerception()
            if crawler.status == .targetSuspected {sawSuspected=true}
            for _ in 0..<24 {crawler.tick(dt:0.05)}
            if crawler.status == .found {break}
        }
        try require(crawler.status == .found,"Coverage hunt did not reach farther article phrase: \(crawler.target)")
        try require(sawSuspected,"Hunt skipped local suspicion state")
        try await Task.sleep(for:.milliseconds(200))
        let highlighted=try await js(web,"[...(CSS.highlights.get('atlas-found')||[])].map(r=>r.toString()).join('')") as? String
        try require(highlighted == crawler.target,"Highlight is not the exact perceived string")
        let huntObservations=crawler.agent.memory.observationCount
        try require(huntObservations>10,"Hunt did not explore before finding farther target")
        let found=crawler.agent.state.match!.key
        crawler.findNext();try require(crawler.agent.memory.discoveries.contains(found),"Find Next forgot previous discovery")
        crawler.autoFollow=true
        try await waitUntil {crawler.viewport.y>200}
        try require(crawler.agent.state.position.y>700,"Hunt did not leave the initial viewport")
        crawler.stop()
        _ = try await js(web,"scrollTo(0,0)");try await Task.sleep(for:.milliseconds(200))
        crawler.target="Charles";crawler.autoFollow=false;crawler.start(hunt:true)
        for _ in 0..<500 {
            try await crawler.refreshPerception();for _ in 0..<24 {crawler.tick(dt:0.05)}
            if crawler.status == .found {break}
        }
        try require(crawler.status == .found,"First repeated-string occurrence not found")
        let firstKey=crawler.agent.state.match!.key;crawler.findNext()
        for _ in 0..<500 {
            try await crawler.refreshPerception();for _ in 0..<24 {crawler.tick(dt:0.05)}
            if crawler.status == .found {break}
        }
        try require(crawler.status == .found && crawler.agent.state.match?.key != firstKey,"Find Next did not find a distinct occurrence")
        crawler.stop()
        // Capture the actual native renderer layered over WebKit for visual inspection.
        _ = try await js(web,"scrollTo(0,0)");try await Task.sleep(for:.milliseconds(200))
        crawler.start(hunt:false);try await Task.sleep(for:.seconds(2))
        // Capture the full long-legged silhouette after it has left the document edge.
        for _ in 0..<220 {
            let point=crawler.agent.state.position
            if point.x>100 && point.x<800 && point.y>100 && point.y<550 {break}
            try await crawler.refreshPerception();for _ in 0..<12 {crawler.tick(dt:0.05)}
        }
        crawler.pause();try await Task.sleep(for:.milliseconds(100))
        let page=try await web.takeSnapshot(configuration:nil)
        guard let overlay=surface.overlay.bitmapImageRepForCachingDisplay(in:surface.overlay.bounds) else {throw Failure.check("No overlay bitmap")}
        surface.overlay.cacheDisplay(in:surface.overlay.bounds,to:overlay)
        let composite=NSImage(size:web.bounds.size)
        composite.lockFocus();page.draw(in:NSRect(origin:.zero,size:composite.size));NSImage(cgImage:overlay.cgImage!,size:composite.size).draw(in:NSRect(origin:.zero,size:composite.size));composite.unlockFocus()
        let bitmap=NSBitmapImageRep(data:composite.tiffRepresentation!)!
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/atlas-phase3-crawler.png"))
        crawler.stop()
        print("CRAWLER HUNT PASSED: \(crawler.target), observations=\(huntObservations); screenshot /tmp/atlas-phase3-crawler.png")
    }
    static func exerciseCommands(model:BrowserModel,web:WKWebView) async throws {
        let crawler=model.crawler,chat=crawler.conversation
        crawler.autoFollow=false;crawler.start(hunt:false)
        try await Task.sleep(for:.milliseconds(800))
        chat.send("move slowly");try require(chat.speed == 135,"Slow command failed")
        chat.send("move faster");try require(chat.speed == 202.5,"Fast command failed")
        chat.send("normal speed")
        chat.send("pause");let position=crawler.agent.state.position
        for _ in 0..<20 {crawler.tick(dt:0.05)}
        try require(crawler.agent.state.position == position && crawler.status == .paused,"Pause command did not hold")
        chat.send("go right")
        for _ in 0..<100 {
            try await crawler.refreshPerception();for _ in 0..<6 {crawler.tick(dt:0.05)}
            if crawler.status == .paused {break}
        }
        try require(crawler.status == .paused && crawler.agent.state.position.x>position.x+40,"Direction command failed to arrive and wait")
        chat.send("stay in this article");try require(!chat.rules.allowLinks,"Stay rule failed")
        chat.send("avoid United States");try require(!chat.rules.permits("United_States"),"Avoid rule failed")
        chat.send("resume")
        chat.send("highlight adjectives")
        for _ in 0..<100 {
            try await crawler.refreshPerception();for _ in 0..<12 {crawler.tick(dt:0.05)}
            if chat.highlightedWords>0 {break}
            try await Task.sleep(for:.milliseconds(80))
        }
        let marked=try await js(web,"[...(CSS.highlights.get('atlas-words')||[])].map(r=>r.toString()).join(', ')") as? String ?? ""
        try require(chat.highlightedWords>0 && !marked.isEmpty,"No locally classified words were highlighted")
        chat.send("clear highlights");try await Task.sleep(for:.milliseconds(100))
        let count=try await js(web,"CSS.highlights.get('atlas-words')?.size || 0") as? Int ?? 0
        try require(count == 0 && chat.wordKind == nil,"Clear highlights failed")
        let originalProvider=crawler.intelligence.provider,originalModel=crawler.intelligence.model
        crawler.intelligence.provider=DelayedCommandProvider();crawler.intelligence.model="test"
        chat.send("Could you gently shift eastwards?")
        try require(chat.interpreting,"Natural-language interpretation did not start")
        chat.send("stop");try require(!crawler.active,"Stop command was not immediate")
        try await Task.sleep(for:.milliseconds(600))
        try require(chat.proposed == nil && !crawler.active,"A stale model response revived the crawler")
        crawler.intelligence.provider=WordSelectionProvider();crawler.intelligence.model="word-test"
        crawler.start(hunt:false);crawler.autoFollow=false
        chat.send("highlight words starting with A")
        try require(chat.wordKind?.lowercased() == "prefix:a","Prefix rule did not activate")
        chat.send("highlight words of French origin")
        try require(chat.wordKind == "AI suggestions: words of French origin","AI criterion did not activate")
        for _ in 0..<100 {
            try await crawler.refreshPerception()
            for _ in 0..<10 {crawler.tick(dt:0.05)}
            if chat.evaluatingWords {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        try require(chat.evaluatingWords,"AI word evaluation did not start")
        try await waitUntil {!chat.evaluatingWords}
        try require(chat.highlightedWords>0,"AI selection did not highlight an observed range")
        chat.send("clear highlights")
        chat.send("highlight words of French origin")
        try await crawler.refreshPerception()
        try require(chat.evaluatingWords,"Second AI batch did not start")
        chat.send("stop")
        try await Task.sleep(for:.milliseconds(700))
        let lateMarks=try await js(web,"CSS.highlights.get('atlas-words')?.size || 0") as? Int ?? 0
        try require(!crawler.active && !chat.evaluatingWords && lateMarks == 0,"Stopped AI batch applied stale highlights")
        print("AI WORD RULES PASSED: prefix mode, bounded model selection, delayed-result cancellation")
        crawler.intelligence.provider=PlanReplyProvider(reply:#"{"actions":[{"action":"stay"},{"action":"slower"}],"words":{"partOfSpeech":"verbs","prefix":"s"},"avoidSections":["References"],"explore":false}"#)
        crawler.intelligence.model="planner-test"
        chat.send("Please find action words beginning with S, skip references, and remain here")
        try await waitUntil {!chat.interpreting}
        try require(chat.wordRule == CrawlerWordRule(partOfSpeech:"verbs",prefix:"s") && !chat.rules.allowLinks && chat.excludedSections == ["References"],"Structured planner lost a constraint")
        try require(crawler.active,"A word plan did not start the crawler")
        let excluded=CrawlerTerrain(id:"excluded",group:"refs",order:0,kind:.link,rect:.init(x:0,y:0,width:50,height:20),text:"Ray Charles",href:"A/Ray_Charles",section:"Article › References")
        try require(!chat.permitsSection(excluded),"Excluded section allowed a remembered link")
        let forbidden=try await crawler.intelligence.followPlanLink(excluded,excluding:[],expectedGeneration:chat.executionID)
        try require(!forbidden,"Excluded section link was followed")

        let beforeStay=web.url
        await chat.exploreNext()
        try require(web.url == beforeStay,"Stay restriction allowed exploration")
        let previousRule=chat.wordRule
        chat.send("find semantic hunt")
        try require(chat.wordRule == previousRule && chat.lines.last?.text.contains("What should I look for") == true,"Ambiguous semantic request did not clarify while retaining the rule")
        chat.execute(.init(actions:[.init("allowLinks")],words:.init(prefix:"zzzz"),avoidSections:["References"],searchQuery:"Ray Charles",explore:true))
        try await waitUntil(attempts:700) {crawler.ready && !web.isLoading && web.url != beforeStay}
        try require(chat.wordRule?.prefix == "zzzz" && chat.excludedSections == ["References"],"Word plan was lost across an autonomous article transition")
        try await crawler.refreshPerception()
        try require(crawler.agent.observation?.terrain.allSatisfy {$0.text.isEmpty || $0.section != nil} == true,"Section metadata missing from text terrain")
        let stale=chat.executionID,stoppedURL=web.url
        chat.send("stop")
        let rejected=try await crawler.intelligence.followPlanArticle("A/Ray_Charles",expectedGeneration:stale)
        try require(!rejected && web.url == stoppedURL,"Stale plan could navigate after Stop")
        print("INTENT LOOP PASSED: compound plan, auto-start, clarification, travel restriction, automatic offline search after stalled progress, preserved rule, stale navigation rejection")
        crawler.intelligence.provider=originalProvider;crawler.intelligence.model=originalModel
        if ProcessInfo.processInfo.environment["ATLAS_RUN_COMMAND_AI"] == "1" {
            crawler.intelligence.provider=RecordingWordProvider(base:originalProvider)
            crawler.intelligence.model="llama3.1:latest"
            let initialSpeed=chat.speed
            chat.send("Please crawl at a much gentler pace.")
            try await waitUntil(attempts:1200) {!chat.interpreting}
            try require(chat.speed<initialSpeed,"Local model did not execute the slower instruction")
            chat.send("Please highlight every word beginning with the letter A")
            try await waitUntil(attempts:1200) {!chat.interpreting}
            try require(chat.wordRule?.prefix?.lowercased() == "a","Local model did not execute a word-prefix plan")
            crawler.start(hunt:false)
            chat.send("highlight words of French origin")
            for _ in 0..<100 {
                try await crawler.refreshPerception()
                for _ in 0..<10 {crawler.tick(dt:0.05)}
                if chat.evaluatingWords {break}
                try await Task.sleep(for:.milliseconds(50))
            }
            try require(chat.evaluatingWords,"Real model word evaluation did not start")
            try await waitUntil(attempts:1200) {!chat.evaluatingWords}
            try require(chat.wordEvaluationNote.hasPrefix("AI suggestions · llama3.1:latest"),"Real model failed word-selection JSON: \(chat.wordEvaluationNote)")
            chat.send("stop")
            crawler.intelligence.model=originalModel
            print("REAL LOCAL COMMAND INTERPRETER AND WORD SELECTION PASSED")
        }

        crawler.stop()
        _ = try await js(web,"document.body.innerHTML = '<main style=\"padding:40px;width:700px\"><p>A small cat runs. The extraordinary creature walks confidently beside <b>pneumonoultramicroscopicsilicovolcanoconiosis</b> in this deliberately longer sentence.</p><p><a href=\"One\">First</a> <a href=\"Two\">Second</a> <a href=\"One\">Repeated</a></p><img alt=\"Test diagram\" width=\"80\" height=\"60\"></main>'; window.scrollTo(0,0)")
        try await Task.sleep(for:.milliseconds(600))
        let pageValue=try await js(web,"window.atlasTerrain.pageMap()")
        let page=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:pageValue as Any))
        try require(page.links.count == 3,"Whole-page link count must count repeated destinations")
        try require(page.images.count == 1,"Whole-page map lost the image")
        let longest=try CrawlerPageAnalysis.longest(page,sentence:false).unwrap()
        try require(longest.text == "pneumonoultramicroscopicsilicovolcanoconiosis","Wrong longest word")
        chat.send("find the longest sentence in this page")
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.pageTaskActive}
        try require(chat.pageTaskStatus == "Complete","Sentence action failed: \(chat.lines.last?.text ?? "")")
        let sentenceMark=try await js(web,"[...CSS.highlights.get('atlas-page')].map(r=>r.toString()).join('')") as? String ?? ""
        try require(sentenceMark.contains(longest.text) && sentenceMark.contains("creature"),"Sentence highlight lost inline text")
        chat.send("count the hyperlinks")
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.pageTaskActive}
        let linkMarks=try await js(web,"CSS.highlights.get('atlas-page').size") as? Int
        try require(linkMarks == 3,"Link tour did not highlight all links: \(chat.lines.last?.text ?? "")")
        crawler.intelligence.provider=PlanReplyProvider(reply:"My interpretation: the article is descriptive, but this excerpt gives little evidence for its claims.")
        crawler.intelligence.model="test-reader"
        chat.send("what do you think of this article?")
        try await waitUntil {!chat.pageTaskActive}
        try require(chat.lines.last?.text.contains("Opinion · test-reader") == true,"Opinion did not use selected model")
        chat.send("find the longest word")
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.pageTaskActive}
        let wordMark=try await js(web,"[...CSS.highlights.get('atlas-page')].map(r=>r.toString()).join('')") as? String
        try require(wordMark == longest.text,"Word highlight is not the exact source range")
        _ = try await js(web,"document.querySelector('p').append(' Changed.')")
        try await Task.sleep(for:.milliseconds(100))
        let stalePageMark=try await js(web,"window.atlasTerrain.pageMark({id:\(quoted(longest.id)),start:\(longest.start),end:\(longest.end)},\(page.revision),false)") as? Bool
        try require(stalePageMark == false,"Stale article map was accepted")

        _ = try await js(web,"document.body.innerHTML='<p style=\"margin:40px;font-size:12px;line-height:18px;width:650px\">Cats chase mice and dogs chase hippopotamuses while birds chase insects.</p>';window.scrollTo(0,0)")
        try await Task.sleep(for:.milliseconds(300))
        let footMap=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:try await js(web,"window.atlasTerrain.pageMap()") as Any))
        let allowedFootWords=CrawlerPageAnalysis.ranges(footMap,unit:.word,footholds:["noun","verb"])
        print("FOOT WORDS",allowedFootWords.map(\.text))
        let firstFoot=try allowedFootWords.first.unwrap()
        let footJSON=String(data:try JSONEncoder().encode([firstFoot]),encoding:.utf8)!
        let footTargets=try JSONDecoder().decode([CrawlerPageTarget].self,from:JSONSerialization.data(withJSONObject:try await js(web,"window.atlasTerrain.pageResolve(JSON.parse(\(quoted(footJSON))),\(footMap.revision))") as Any))
        let footStart=try footTargets.first.unwrap().rect.center
        crawler.guide(to:footStart)
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return crawler.agent.state.position.distance(to:footStart)<11}
        chat.send("go to the longest word in this article but do so only stepping on nouns or verbs")
        var observedStrictFeet=false
        try await waitUntil {
            if let permitted=crawler.pageFootholds {
                observedStrictFeet=true
                try require(crawler.legs.legs.allSatisfy {leg in permitted.contains {$0.position == leg.to}},"A restricted foot targeted blank space")
            }
            for _ in 0..<6 {crawler.tick(dt:0.03)}
            return !chat.pageTaskActive
        }
        try require(observedStrictFeet && chat.pageTaskStatus == "Complete","Restricted gait did not execute: \(chat.lines.last?.text ?? "")")
        print("RESTRICTED WEBKIT GAIT PASSED: noun/verb footholds, actual leg targets, arrival")
        crawler.stop();crawler.intelligence.provider=originalProvider;crawler.intelligence.model=originalModel

        _ = try await js(web,"document.body.innerHTML='<p>The beautiful red bird sings sweet songs.</p><h2>History</h2><p>A tall green tree grows.</p>';window.scrollTo(0,0)")
        try await Task.sleep(for:.milliseconds(300))
        crawler.intelligence.provider=CompanionFixtureProvider();crawler.intelligence.model="test-companion"
        chat.talk("How many adjectives are in this article?")
        try await waitUntil {!chat.companionBusy}
        let counted=try chat.companionResults.last.unwrap()
        try require(counted.count>0 && counted.title == "adjectives","Companion didn't save the exact word result")
        try require(!crawler.active,"A count spawned the spider without a demonstration request")
        chat.talk("Create a sentence using all these adjectives.")
        try await waitUntil {!chat.companionBusy}
        let composition=chat.lines.last?.text ?? ""
        try require(Set(counted.ranges.map {$0.text.lowercased()}).allSatisfy {composition.lowercased().contains($0)},"Plain chat did not receive the saved adjective words")
        try require(chat.companionFocus == counted.id,"Creative chat replaced the saved adjective finding")
        _ = try await js(web,"window.dispatchEvent(new Event('resize'))")
        try await Task.sleep(for:.milliseconds(100))
        chat.talk("I bet you can't point at them.")
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.companionBusy && !chat.companionTouring}
        let proofCount=try await js(web,"CSS.highlights.get('atlas-page')?.size || 0") as? Int
        try require(proofCount == counted.count,"Companion demonstration lost the saved adjective references: \(chat.lines.last?.text ?? "")")
        chat.talk("What's the second longest word here?")
        try await waitUntil {!chat.companionBusy}
        let ranked=try chat.companionResults.last.unwrap()
        try require(ranked.title == "Word ranked 2 by length" && ranked.count == 1 && ranked.id != counted.id,"Fresh ranking reused the old adjective finding")
        chat.talk("What do you think of this article?")
        try await waitUntil {!chat.companionBusy}
        let evidence=try chat.companionResults.last.unwrap()
        try require(evidence.title == "Supporting passages" && evidence.id != counted.id,"Discussion failed to replace the focused referent")
        chat.talk("Prove it.")
        try await waitUntil {for _ in 0..<6 {crawler.tick(dt:0.03)};return !chat.companionBusy && !chat.companionTouring}
        let evidenceProof=try await js(web,"[...(CSS.highlights.get('atlas-page')||[])].map(r=>r.toString()).join('')") as? String ?? ""
        try require(evidenceProof.contains("bird sings"),"Proof incorrectly referred back to individual adjectives")
        _ = try await js(web,"document.querySelector('p').append(' New evidence changes the source.')")
        try await Task.sleep(for:.milliseconds(100))
        chat.talk("Prove it.")
        try await waitUntil {!chat.companionBusy && !chat.companionTouring}
        try require(chat.lines.last?.text.contains("page changed") == true,"Changed source content reused stale evidence")
        crawler.stop();crawler.intelligence.provider=originalProvider;crawler.intelligence.model=originalModel
        print("COMPANION PASSED: count without movement, saved targets, conversational challenge, discussion evidence, referent replacement")
        print("EMBODIED PAGE TOOLS PASSED: whole-page map, inline sentence/word ranges, repeated-link tour, model opinion, stale-map rejection")
        print("CRAWLER COMMANDS PASSED: speed, pause, directional approach, travel rules, local adjective highlights (\(marked.prefix(100))), clear, stop")
    }
    static func quoted(_ value:String)->String { String(data:try! JSONEncoder().encode(value),encoding:.utf8)! }
}
private extension Optional {
    func unwrap() throws -> Wrapped { guard let value=self else { throw BrowserSmoke.Failure.check("Missing expected value") }; return value }
}

private struct DelayedCommandProvider:LLMProvider {
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {throw AIError.unavailable}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream {continuation in
            let task=Task {
                try? await Task.sleep(for:.milliseconds(300))
                continuation.yield(#"{"action":"direction","value":"right"}"#)
                continuation.finish()
            }
            continuation.onTermination={_ in task.cancel()}
        }
    }
}

private struct WordSelectionProvider:LLMProvider {
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {throw AIError.unavailable}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream {continuation in
            Task {
                try? await Task.sleep(for:.milliseconds(400))
                continuation.yield(#"{"matches":[0]}"#)
                continuation.finish()
            }
        }
    }
    func embed(model:String,texts:[String]) async throws -> [[Float]] {throw AIError.unavailable}
}

private struct RecordingWordProvider:LLMProvider {
    let base:any LLMProvider
    func models() async throws -> [AIModel] {try await base.models()}
    func validate(model:String) async throws -> AIModel {try await base.validate(model:model)}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream {continuation in
            let task=Task {
                do {
                    var reply=""
                    for try await part in base.chat(model:model,messages:messages,json:json) {reply += part;continuation.yield(part)}
                    print("TEST MODEL REPLY: \(reply.prefix(1000))")
                    continuation.finish()
                } catch {continuation.finish(throwing:error)}
            }
            continuation.onTermination={_ in task.cancel()}
        }
    }
}

private struct PlanReplyProvider:LLMProvider {
    let reply:String
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {throw AIError.unavailable}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream {continuation in continuation.yield(reply);continuation.finish()}
    }
}

private struct CompanionFixtureProvider:LLMProvider {
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"test")}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        let input=messages.map(\.content).joined(separator:"\n")
        func match(_ pattern:String)->String {
            let regex=try! NSRegularExpression(pattern:pattern)
            guard let result=regex.firstMatch(in:input,range:NSRange(input.startIndex...,in:input)),let range=Range(result.range(at:1),in:input) else {return "missing"}
            return String(input[range])
        }
        let request=messages.last?.content.components(separatedBy:"LATEST REQUEST:\n").last ?? ""
        let reply:String
        if !json, messages.first?.content.contains("Classify the user's latest request") == true {
            if request.contains("How many") || request.contains("second longest") {reply="TOOL"}
            else if request.contains("point") || request.contains("Prove it") {reply="SHOW"}
            else if request.contains("think") {reply="WHOLE_ARTICLE"}
            else if request.contains("Create a sentence") {reply="SAVED_CHAT"}
            else {reply="CHAT"}
        } else if !json {
            if request.contains("Create a sentence") {
                reply="A vivid scene uses "+match(#"FOCUSED RESULT WORDS \([^\n]+\): ([^\n]+)"#)+"."
            } else if request.contains("think") {
                reply="The descriptive language makes the bird vivid, but the passage is not an evidence-based argument.\nSOURCE_IDS: "+match(#"\[(terrain-[^\]]+)\]"#)
            } else {reply="Hello!"}
        } else {
            let value:[String:Any]
            if request.contains("How many") {value=["operation":"words","kind":"adjectives","demonstrate":false]}
            else if request.contains("second longest") {value=["operation":"rankedWord","rank":2,"distinct":true,"demonstrate":false]}
            else {value=["operation":"show","resultID":match(#"FOCUSED RESULT: ([^\n]+)"#)]}
            reply=String(data:try! JSONSerialization.data(withJSONObject:value),encoding:.utf8)!
        }
        return AsyncThrowingStream {continuation in continuation.yield(reply);continuation.finish()}
    }
}

private struct EmbodiedFixtureProvider:LLMProvider {
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"test")}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        let request=messages.last?.content.components(separatedBy:"LATEST REQUEST:\n").last ?? ""
        let reply:String
        if !json {
            reply=messages.first?.content.contains("Classify the user's latest request") == true ? "TOOL":"I can read the page."
        } else if request.localizedCaseInsensitiveContains("first word") {
            reply=#"{"operation":"select","unit":"word","order":"first","demonstrate":true}"#
        } else {
            reply=#"{"operation":"select","unit":"word","order":"longest","demonstrate":true,"footholds":["noun","verb"]}"#
        }
        return AsyncThrowingStream {continuation in continuation.yield(reply);continuation.finish()}
    }
}

private struct StatisticsFixtureProvider:LLMProvider {
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"test")}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        let reply:String
        if json {
            reply=messages.contains(where:{$0.content.localizedCaseInsensitiveContains("How many digits are in this article")})
                ? #"{"operation":"measure","metric":"digits"}"#
                : #"{"operation":"measure","metric":"letters"}"#
        } else if messages.first?.content.contains("Classify the user's latest request") == true {
            // A weak classifier's CHAT label must not redirect an exact count
            // to unsupported free-form model arithmetic.
            reply="CHAT"
        } else {
            reply="The page has maybe 99 letters."
        }
        return AsyncThrowingStream {continuation in continuation.yield(reply);continuation.finish()}
    }
}

private struct NoArticleChatProvider:LLMProvider {
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"test")}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream {continuation in
            if json {continuation.finish(throwing:AIError.invalidResponse)}
            else {continuation.yield("Hello! We can talk without an article open.");continuation.finish()}
        }
    }
}
