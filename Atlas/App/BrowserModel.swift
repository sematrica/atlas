import SwiftUI
import WebKit
import AtlasCore

struct ArticleHeading: Identifiable { let id: String; let title: String; let level: Int }
@MainActor @Observable
final class BrowserModel {
    let crawler=CrawlerController()
    var record: PackageRecord?
    var provider: (any ArticleProvider)?
    var webView: WKWebView?
    var title="Offline Wikipedia"
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
        self.provider=provider; self.record=record
        let web=try await OfflineWebFactory.make(provider:provider,host:record.package.storageKey,model:self)
        guard session == sessionID else { return }
        webView=web; title=main.title
        if let url=OfflineURL.make(host:record.package.storageKey,path:main.path) { web.load(URLRequest(url:url)) }
    }
    func close() {
        crawler.navigationStarted()
        searchTask?.cancel(); webView?.navigationDelegate=nil; webView?.stopLoading(); webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView=nil; provider=nil; record=nil; results=[]; headings=[]; message=nil; query=""; title="Offline Wikipedia"
        canGoBack=false; canGoForward=false; loading=false; searching=false; sessionID=UUID()
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
