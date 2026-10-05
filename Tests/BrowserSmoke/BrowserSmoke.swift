import AppKit
import WebKit
import AtlasCore

// Compiled against the actual application BrowserModel and OfflineWebView sources.
@main
@MainActor
struct BrowserSmoke {
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
    static func waitUntil(_ check: @escaping @MainActor () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await check() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        throw Failure.check("Timed out waiting for WebKit")
    }
    static func js(_ web:WKWebView,_ script:String) async throws -> Any? {
        try await web.evaluateJavaScript(script,in:nil,contentWorld:.defaultClient)
    }
    static func run() async throws {
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
        try await exerciseCrawler(model:model,web:web,surface:surface,window:window,results:results)
        model.close(); window.close()
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
