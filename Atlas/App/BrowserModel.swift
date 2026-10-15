import SwiftUI
import WebKit
import AtlasCore

struct ArticleHeading: Identifiable { let id: String; let title: String; let level: Int }
/// The open article in another language's Wikipedia, and the installed package of that language, if any.
struct ArticleLanguage: Identifiable { let link: LanguageLink; let record: PackageRecord?; var id: String { link.id } }
@MainActor @Observable
final class BrowserModel {
    let crawler=CrawlerController()
    var pendingCitation:RetrievedPassage?
    var currentArticleID:ArticleID? {
        guard let record,let url=webView?.url else {return nil}
        return ArticleID(packageID:record.id,path:String(url.path.dropFirst()))
    }
    init() {crawler.intelligence.browser=self}
    func openCitation(_ passage:RetrievedPassage) {
        guard record?.id == passage.article.packageID else {message="Open the source package first.";return}
        pendingCitation=passage;navigate(passage.article.path)
    }
    func identifyCitation() {
        guard let passage=pendingCitation,passage.article == currentArticleID else {return}
        pendingCitation=nil
        webView?.callAsyncJavaScript("""
        const normalize=t=>t.replace(/\\s+/g,' ').trim();
        const match=[...document.querySelectorAll('p,li,td,dd,figcaption')].find(e=>normalize(e.textContent||'').includes(normalize(needle)));
        const element=match || document.getElementById(anchor);
        if(element){element.scrollIntoView({block:'center'});element.style.outline='2px solid #bd9d39';element.style.outlineOffset='4px';}
        """,arguments:["needle":String(passage.text.prefix(160)),"anchor":passage.anchor ?? ""],in:nil,in:.defaultClient){_ in}
    }
    var record: PackageRecord?
    var provider: (any ArticleProvider)?
    /// Wikipedia's link map for the open package's wiki, once one is built under Packages.
    var linkMap: LinkMap?
    /// The open package's Wikimedia project ("enwiki"); nil when it isn't a Wikipedia.
    var linkMapProject: String?
    /// The library's readable packages, and a way to open an article in one (both set by the library),
    /// so an article can be read in another language's Wikipedia.
    @ObservationIgnored var installedPackages: @MainActor () -> [PackageRecord] = { [] }
    @ObservationIgnored var openArticle: @MainActor (PackageRecord, String) -> Void = { _, _ in }
    /// The open article in other languages, from the link map, with the installed package for each language.
    func articleLanguages() -> [ArticleLanguage] {
        guard let map=linkMap, map.hasLanguages, let id=currentArticleID, let node=map.node(id.path) ?? map.node(title) else { return [] }
        var packages: [String:PackageRecord] = [:]
        for record in installedPackages() where record.id != self.record?.id {
            if let project=LinkMapLibrary.project(for:record.package), packages[project] == nil { packages[project]=record }
        }
        // Naming and sorting a few hundred languages takes a few milliseconds: keep them for the open article.
        let links: [LanguageLink]
        if let cached=languageCache, cached.node == node, cached.map === map { links=cached.links }
        else { links=map.languageLinks(of:node); languageCache=(node,map,links) }
        return links.map { ArticleLanguage(link:$0, record:packages[$0.project]) }
    }
    @ObservationIgnored private var languageCache: (node: Int32, map: LinkMap, links: [LanguageLink])?
    /// Kept so library questions can open the Research text index for this package.
    @ObservationIgnored private var access: LibraryAccess?
    @ObservationIgnored private var textIndex: ResearchStore?
    var webView: WKWebView?
    var title="Offline library"
    var query=""
    var results: [SearchResult] = []
    var searchMessage: String?
    var message: String?
    var headings: [ArticleHeading] = []
    var canGoBack=false
    var canGoForward=false
    var searching=false
    var loading=false
    var sessionID=UUID()
    private var searchTask: Task<Void,Never>?
    func open(record: PackageRecord,access: LibraryAccess) async throws {
        close()
        let session=sessionID
        let provider=try await Task.detached { try ZIMArticleProvider(access:access,record:record) }.value
        let main=try await provider.info()
        guard session == sessionID else { return }
        self.provider=provider; self.record=record; self.access=access
        linkMapProject=LinkMapLibrary.project(for:record.package)
        await loadLinkMap()
        let web=try await OfflineWebFactory.make(provider:provider,host:record.package.storageKey,model:self)
        guard session == sessionID else { return }
        webView=web; title=main.title
        if let url=OfflineURL.make(host:record.package.storageKey,path:main.path) { web.load(URLRequest(url:url)) }
    }
    func close() {
        crawler.stop();crawler.ready=false;pendingCitation=nil
        searchTask?.cancel(); webView?.navigationDelegate=nil; webView?.stopLoading(); webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView=nil; provider=nil; record=nil; access=nil; textIndex=nil; linkMap=nil; linkMapProject=nil; results=[]; headings=[]; message=nil; query=""; title="Offline library"
        canGoBack=false; canGoForward=false; loading=false; searching=false; sessionID=UUID()
    }
    /// Opens the newest link map built for the open package's wiki (again after a build or delete).
    func loadLinkMap() async {
        guard let access,let project=linkMapProject else { linkMap=nil; return }
        let session=sessionID
        let map=await Task.detached { () -> LinkMap? in
            guard let indexes=try? access.file("indexes") else { return nil }
            return LinkMapLibrary.open(project:project,in:indexes)
        }.value
        guard session == sessionID else { return }
        linkMap=map
    }
    /// The Research text index for the open package (opened on first use), or nil.
    func libraryTextIndex() async -> ResearchStore? {
        if let textIndex {return textIndex}
        guard let access,let record else {return nil}
        let session=sessionID
        let store=try? await Task.detached {try ResearchStore(access:access,record:record)}.value
        guard session == sessionID else {return nil}
        textIndex=store
        return store
    }
    func search() {
        searchTask?.cancel(); results=[]; searchMessage=nil
        let text=query, session=sessionID
        guard let provider,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { searching=false; return }
        searching=true
        searchTask=Task {
            do {
                try await Task.sleep(for:.milliseconds(180))
                let results=try await provider.search(text,limit:40)
                guard !Task.isCancelled,session == sessionID else { return }
                self.results=results; searching=false
                if results.isEmpty { searchMessage="No matching titles in this package. Try a shorter title or its original capitalization." }
            } catch {
                guard !Task.isCancelled,session == sessionID else { return }
                searchMessage=AtlasLog.message(error); searching=false
            }
        }
    }
    func navigate(_ path: String) {
        guard let record,let url=OfflineURL.make(host:record.package.storageKey,path:path) else { return }
        message=nil; webView?.load(URLRequest(url:url))
    }
    func select(_ result: SearchResult) { navigate(result.articleID.path) }
    func back() { message=nil; webView?.goBack() }
    func forward() { message=nil; webView?.goForward() }
    func scroll(to heading: ArticleHeading) {
        let json=(try? JSONSerialization.data(withJSONObject:[heading.id])).flatMap {String(data:$0,encoding:.utf8)} ?? "[]"
        webView?.evaluateJavaScript("document.getElementById(\(json)[0])?.scrollIntoView()",in:nil,in:.defaultClient) { _ in }
    }
}
