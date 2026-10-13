import AppKit
import SwiftUI
import WebKit
import AtlasCore
@main @MainActor struct LayoutSmoke {
 static func main() {
 let app=NSApplication.shared;app.setActivationPolicy(.accessory)
 Task {do {try await run();exit(0)} catch {print(error);exit(1)}};app.run()
 }
 enum Failure:Error {case failed(String)}
 static func run() async throws {
 let library=LibraryViewModel()
 let root=URL(fileURLWithPath:"/tmp/AtlasStage2LiveLibrary")
 let metadata=try LibraryLayout().establish(at:root)
 let access=try LibraryAccess(root:root,libraryID:metadata.id)
 let record=try PackageManifest(access:access).load().first {$0.state == .installed && $0.package.format == .zim}!
 let browser=library.packages.browser
 try await browser.open(record:record,access:access)
 let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
 let state=LayoutState()
 let host=NSHostingView(rootView:LayoutRoot(library:library,state:state).frame(minWidth:860,minHeight:580))
 host.sizingOptions=[.minSize];window.contentView=host;window.setContentSize(NSSize(width:1100,height:760));window.orderFront(nil)
 try await Task.sleep(for:.seconds(3))
 for size in [NSSize(width:1100,height:760),NSSize(width:860,height:580)] {
     window.setContentSize(size)
     for expanded in [false,true,false,true] {
         state.crawl=expanded
         browser.crawler.debug=expanded
         browser.crawler.conversation.panelOpen=expanded
         if expanded {browser.crawler.conversation.send("status")}
         try await Task.sleep(for:.milliseconds(700))
         let height=host.bounds.height
         guard height<=size.height+60,window.contentMinSize.height<=580 else {throw Failure.failed("Window grew beyond available space: \(height), minimum \(window.contentMinSize)")}
         guard let web=browser.webView else {throw Failure.failed("Missing article")}
         let rect=web.convert(web.bounds,to:host)
         guard rect.minY >= -1,rect.maxY<=height+1,rect.height>150 else {throw Failure.failed("Article outside window: \(rect)")}
         print("LAYOUT",size,"crawler",expanded,"height",height,"article",rect)
     }
 }
 browser.crawler.start(hunt:false)
 try await Task.sleep(for:.seconds(1))
 guard browser.crawler.active,let renderer=browser.crawler.renderer,renderer.renderedFrames>0 else {throw Failure.failed("Crawler did not render in SwiftUI reader")}
 print("LAYOUT SMOKE PASSED: opening, closing, expanded chat/debug, resizing, creature rendering")
 if let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) {host.cacheDisplay(in:host.bounds,to:rep);try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/atlas-layout.png"))}
 window.setContentSize(NSSize(width:1360,height:840))
 browser.crawler.debug=false;browser.crawler.conversation.lines=[]
 try await Task.sleep(for:.milliseconds(800))
 if let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) {host.cacheDisplay(in:host.bounds,to:rep);try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/atlas-companion-wide.png"))}
 let research=library.packages.research
 research.question="Compare the musical influences on Ray Charles and identify disagreements in the sources."
 let researchHost=NSHostingView(rootView:ResearchView(research:research,ai:library.packages.intelligence,browser:browser,openSource:{_ in}).frame(minWidth:660,minHeight:580))
 researchHost.sizingOptions=[.minSize];window.contentView=researchHost
 for size in [NSSize(width:900,height:760),NSSize(width:660,height:580)] {
     window.setContentSize(size)
     try await Task.sleep(for:.milliseconds(800))
     guard researchHost.bounds.height<=size.height+1,researchHost.bounds.width<=size.width+1 else {throw Failure.failed("Research controls grew beyond the window")}
 }
 print("RESEARCH LAYOUT PASSED: scrollable controls at regular and minimum window sizes")
 browser.close()

 }
}

@MainActor @Observable final class LayoutState {var crawl=false}
private struct LayoutRoot:View {
 let library:LibraryViewModel
 @Bindable var state:LayoutState
 var body:some View {
     NavigationSplitView {
         List {Text("Library");Text("Browse");Text("Crawl")}.navigationSplitViewColumnWidth(200)
     } detail: {
         BrowserView(library:library.packages,browser:library.packages.browser,emphasizeCrawl:state.crawl)
     }
 }
}
