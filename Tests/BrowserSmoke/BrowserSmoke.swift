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
        try await exerciseNoArticleChat()
        try await exerciseCompanion()
        if ProcessInfo.processInfo.environment["ATLAS_COMPANION_ONLY"] == "1" {return}
        let root=URL(fileURLWithPath:"/tmp/AtlasStage2LiveLibrary")
        let metadata=try LibraryLayout().establish(at:root)
        let access=try LibraryAccess(root:root,libraryID:metadata.id)
        let record=try PackageManifest(access:access).load().first {$0.state == .installed && $0.package.format == .zim}.unwrap()
        let model=BrowserModel()
        try await model.open(record:record,access:access)
        let web=try model.webView.unwrap()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:760),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        retainedWindows.append(window)
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
        try await exerciseLiveCompanion(model:model,web:web,results:results)
        model.close()
    }

    /// Ordinary chat works with no article open and never starts the spider.
    static func exerciseNoArticleChat() async throws {
        let browser=BrowserModel()
        let chat=browser.crawler.conversation
        browser.crawler.intelligence.provider=ScriptedPlans(["hello":#"{"steps":[],"reply":"Hello! We can talk without an article open."}"#])
        browser.crawler.intelligence.model="test"
        chat.send("hello")
        try await waitUntil {!chat.busy}
        try require(chat.lines.last?.text == "Hello! We can talk without an article open.","No-article chat failed: \(chat.lines.last?.text ?? "")")
        try require(!browser.crawler.active,"Ordinary chat started the crawler")
        try require(chat.companionTitle == "No article open","Empty-page header claims an article is open")
        print("NO-ARTICLE CHAT PASSED")
    }

    static let fixtureHTML="""
    <html><body><article>
    <h1>Fixture</h1>
    <p>A yellow bird sat on a narrow branch near a new house. Anchor after anchor, the bird sang. The extraordinary singer was famous.</p>
    <h2>History</h2>
    <p>A tall green tree grows beside the forest. Another tiny insect watches. <a href="#x">A link</a> and <a href="#y">another link</a>.</p>
    </article></body></html>
    """

    /// The companion on a fixture page: local requests run without a model,
    /// highlights are exact and survive reflow, the spider walks to targets.
    static func exerciseCompanion() async throws {
        let browser=BrowserModel()
        browser.title="Fixture article"
        let web=WKWebView(frame:NSRect(x:0,y:0,width:960,height:700))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        retainedWindows.append(window)
        let surface=CrawlerSurface(webView:web,crawler:browser.crawler)
        window.contentView=surface;window.orderFront(nil)
        browser.webView=web;browser.crawler.attach(web)
        web.loadHTMLString(fixtureHTML,baseURL:nil)
        try await waitUntil {(try? await js(web,"document.body?.innerText.includes('extraordinary')") as? Bool) == true}
        await browser.crawler.prepare()
        try require(browser.crawler.ready,"Fixture geometry was unavailable")
        let crawler=browser.crawler,chat=crawler.conversation
        crawler.autoFollow=false
        crawler.intelligence.model=""   // Local requests must not need a model.
        func ask(_ text:String) async throws {
            chat.send(text)
            try await waitUntil(attempts:600) {for _ in 0..<4 {crawler.tick(dt:0.03)};return !chat.busy}
        }
        func painted(_ layer:String) async throws -> [String] {
            try await js(web,"[0,1,2,3,4,5,6,7,8,9,10,11].flatMap(i=>[...(CSS.highlights.get('atlas-\(layer)-'+i)||[])].map(r=>r.toString()))") as? [String] ?? []
        }

        try await ask("how many periods are in this article")
        try require(chat.lines.last?.text.hasPrefix("There are 6 periods") == true,"Period count: \(chat.lines.last?.text ?? "")")
        try require(!crawler.active,"Counting moved the spider")

        try await ask("find all adjectives that end with w and highlight them in green")
        let green=try await painted("l1")
        try require(Set(green) == ["yellow","narrow","new"],"Green adjectives: \(green)")
        try require(chat.layers.first?.style.colors == ["#008000"],"Layer color was not green")
        try require(crawler.active,"Highlighting did not use the spider")

        try await ask("find me all the words that start with a and ends with r")
        let words=try await painted("l2")
        try require(words == ["Anchor","after","anchor","Another","another"],"a…r words: \(words)")

        try await ask("highlight the verbs half green half yellow")
        try require(chat.layers.count == 3 && chat.layers.last?.style.mode == .split,"Split layer missing")

        // A reflow must not erase highlights or break the next walk.
        window.setContentSize(NSSize(width:720,height:700))
        try await Task.sleep(for:.milliseconds(400))
        try require(try await painted("l1").count == 3,"Highlights vanished after a reflow")

        try await ask("go to the longest word")
        let rect=try await js(web,"(()=>{const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;while(n=w.nextNode()){const i=n.data.indexOf('extraordinary');if(i>=0){const r=document.createRange();r.setStart(n,i);r.setEnd(n,i+13);const b=r.getBoundingClientRect();return [b.left+scrollX+b.width/2,b.top+scrollY+b.height/2];}}})()") as? [Double] ?? []
        try require(rect.count == 2 && crawler.agent.state.position.distance(to:.init(x:rect[0],y:rect[1]))<20,"Spider did not reach the longest word")

        try await ask("take me to the History section")
        try require(chat.lines.last?.trail.contains("arrived") == true,"Go to section did not arrive")

        try await ask("clear highlights")
        try require(chat.layers.isEmpty,"Clear left layers behind")
        try require(try await painted("l1").isEmpty,"Clear left highlights on the page")

        // The model path: one schema-constrained call, then the same execution.
        crawler.intelligence.provider=ScriptedPlans([
            "paint words about trees in blue":#"{"steps":[{"action":"highlight","query":{"unit":"word","meaning":"related to trees"},"color":"blue"}],"reply":"Blue for trees."}"#,
            "Which words are related to trees?":#"{"matches":[]}"#
        ],judge:["tree","forest","branch"])
        crawler.intelligence.model="fixture"
        try await ask("paint words about trees in blue")
        let trees=try await painted("l5")
        try require(Set(trees) == ["tree","forest","branch"],"Semantic highlight: \(trees)")
        try require(chat.lines.contains {$0.text == "Blue for trees."},"Model reply missing")

        try await ask("stop")
        try require(crawler.status == .idle || crawler.status == .paused,"Stop did not stop the spider")
        print("COMPANION PASSED: local counts and highlights, exact layers, reflow, walking, sections, clear, model plan with semantic judgment")
        crawler.stop();browser.close();window.orderOut(nil)
    }

    /// The companion on the real offline article: sections, links, navigation and hunts.
    static func exerciseLiveCompanion(model:BrowserModel,web:WKWebView,results:[SearchResult]) async throws {
        let crawler=model.crawler,chat=crawler.conversation
        let main=try results.first {$0.title == "Ray Charles"}.unwrap();model.select(main)
        try await waitUntil {crawler.ready && !web.isLoading}
        crawler.autoFollow=true
        crawler.intelligence.model=""
        func ask(_ text:String) async throws {
            chat.send(text)
            try await waitUntil(attempts:900) {for _ in 0..<4 {crawler.tick(dt:0.03)};return !chat.busy}
        }
        try await ask("how many links are on this page")
        try require(chat.lines.last?.text.hasPrefix("There are") == true,"Link count failed: \(chat.lines.last?.text ?? "")")
        try await ask("highlight the nouns in the introduction in light blue")
        try require(chat.layers.count == 1,"Introduction nouns were not highlighted")
        try await ask("go to the bottom")
        try require(crawler.agent.state.position.y>1000,"Spider did not walk to the bottom")
        try await ask("go to the top")
        try require(crawler.agent.state.position.y<400,"Spider did not walk back to the top")
        let before=web.url
        let other=try results.first {$0.title != "Ray Charles"}.unwrap().title
        let request="open the article about \(other)"
        crawler.intelligence.provider=ScriptedPlans([request:#"{"steps":[{"action":"open","title":"\#(other)"}],"reply":"Opening it."}"#])
        crawler.intelligence.model="fixture"
        try await ask(request)
        try require(web.url != before && crawler.ready,"Open article did not navigate")
        try await ask("go back")
        try require(web.url == before,"Back did not return")
        print("LIVE COMPANION PASSED: counts, section highlights, long walks, open, back")
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
    static func quoted(_ value:String)->String { String(data:try! JSONEncoder().encode(value),encoding:.utf8)! }
}
private extension Optional {
    func unwrap() throws -> Wrapped { guard let value=self else { throw BrowserSmoke.Failure.check("Missing expected value") }; return value }
}

/// Answers each request with a scripted plan; semantic-judgment prompts select the listed words.
private struct ScriptedPlans:LLMProvider {
    let plans:[String:String]
    var judge:[String]=[]
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"fixture",capabilities:["completion"])}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        let last=messages.last?.content ?? ""
        var reply=#"{"steps":[],"reply":"I'm not sure."}"#
        if last.hasPrefix("Which of these words match") {
            let lines=last.components(separatedBy:"\n").filter {$0.contains(": ")}
            let picked=lines.compactMap {line -> Int? in
                let parts=line.components(separatedBy:": ")
                guard parts.count == 2,let index=Int(parts[0]),judge.contains(parts[1].lowercased()) else {return nil}
                return index
            }
            reply=#"{"matches":"#+String(describing:picked)+"}"
        } else if let request=last.components(separatedBy:"USER MESSAGE: ").last,let plan=plans[request] {
            reply=plan
        }
        return AsyncThrowingStream {continuation in continuation.yield(reply);continuation.finish()}
    }
}
