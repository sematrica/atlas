import SwiftUI
import WebKit
import AtlasCore

@MainActor
final class OfflineSchemeHandler: NSObject, WKURLSchemeHandler {
    let provider: any ArticleProvider
    let host: String
    private var tasks: [ObjectIdentifier:Task<Void,Never>] = [:]
    init(provider: any ArticleProvider,host:String) { self.provider=provider; self.host=host }
    func webView(_ webView: WKWebView,start urlSchemeTask: any WKURLSchemeTask) {
        let key=ObjectIdentifier(urlSchemeTask)
        tasks[key]=Task { [weak self] in
            guard let self else { return }
            defer { tasks[key]=nil }
            guard let url=urlSchemeTask.request.url,url.scheme == "atlas",url.host == host else {
                urlSchemeTask.didFailWithError(AtlasError.articleUnavailable); return
            }
            do {
                let path=String(url.path.dropFirst())
                let info=try await provider.info(path:path)
                guard tasks[key] != nil,!Task.isCancelled else { return }
                let isHTML=info.mimeType.contains("html")
                if isHTML {
                    guard info.byteCount <= 32*1024*1024 else { throw AtlasError.articleUnavailable }
                    var data=Data(); var offset: UInt64=0
                    while offset < info.byteCount {
                        let chunk=try await provider.read(path:info.path,offset:offset)
                        guard !chunk.isEmpty else { throw AtlasError.articleUnavailable }
                        data.append(chunk); offset += UInt64(chunk.count)
                        try Task.checkCancellation()
                    }
                    let protected=Data(OfflineURL.protectHTML(String(decoding:data,as:UTF8.self)).utf8)
                    guard tasks[key] != nil,!Task.isCancelled else { return }
                    urlSchemeTask.didReceive(URLResponse(url:url,mimeType:"text/html",expectedContentLength:protected.count,textEncodingName:"utf-8"))
                    urlSchemeTask.didReceive(protected)
                } else {
                    urlSchemeTask.didReceive(URLResponse(url:url,mimeType:info.mimeType,expectedContentLength:Int(clamping:info.byteCount),textEncodingName:nil))
                    var offset: UInt64=0
                    while offset < info.byteCount {
                        let chunk=try await provider.read(path:info.path,offset:offset)
                        guard tasks[key] != nil,!Task.isCancelled else { return }
                        guard !chunk.isEmpty else { throw AtlasError.articleUnavailable }
                        urlSchemeTask.didReceive(chunk); offset += UInt64(chunk.count)
                    }
                }
                guard tasks[key] != nil,!Task.isCancelled else { return }
                urlSchemeTask.didFinish()
            } catch {
                guard tasks[key] != nil,!Task.isCancelled else { return }
                // A local error document keeps the failure in Back/Forward history.
                if urlSchemeTask.request.mainDocumentURL == url || urlSchemeTask.request.mainDocumentURL == nil {
                    let html=Data(OfflineURL.protectHTML("<html><head><title>Article unavailable</title></head><body><h1>Article unavailable</h1><p>This page isn’t in the installed package, or the library drive is disconnected. Reconnect it or return to the previous article.</p></body></html>").utf8)
                    urlSchemeTask.didReceive(URLResponse(url:url,mimeType:"text/html",expectedContentLength:html.count,textEncodingName:"utf-8"))
                    urlSchemeTask.didReceive(html); urlSchemeTask.didFinish()
                } else { urlSchemeTask.didFailWithError(error) }
            }
        }
    }
    func webView(_ webView: WKWebView,stop urlSchemeTask: any WKURLSchemeTask) {
        let key=ObjectIdentifier(urlSchemeTask); tasks.removeValue(forKey:key)?.cancel()
    }
}

@MainActor
final class OfflineBrowserDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var model: BrowserModel?
    let host: String
    init(model:BrowserModel,host:String) { self.model=model; self.host=host }
    func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping @MainActor (WKNavigationActionPolicy)->Void) {
        guard let url=action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "atlas",url.host == host {
            if action.targetFrame == nil { decisionHandler(.cancel); webView.load(URLRequest(url:url)); return }
            // Resolve archive redirects before loading, keeping relative resources anchored at the canonical article.
            if action.targetFrame?.isMainFrame == true,let provider=model?.provider {
                Task {
                    if let info=try? await provider.info(path:String(url.path.dropFirst())),info.path != String(url.path.dropFirst()),
                       let canonical=OfflineURL.make(host:host,path:info.path),var parts=URLComponents(url:canonical,resolvingAgainstBaseURL:false) {
                        parts.fragment=url.fragment
                        decisionHandler(.cancel)
                        if let resolved=parts.url { webView.load(URLRequest(url:resolved)) }
                    } else { decisionHandler(.allow) }
                }
            } else { decisionHandler(.allow) }
            return
        }
        decisionHandler(.cancel)
        if let path=OfflineURL.localWikipediaPath(url) { model?.navigate(path) }
        else { model?.message="External link blocked. Reading in Atlas stays offline." }
    }
    func webView(_ webView: WKWebView,didStartProvisionalNavigation navigation: WKNavigation!) {
        model?.crawler.navigationStarted()
        model?.loading=true; model?.headings=[]
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) {
        Task { [weak model] in await model?.crawler.prepare();model?.identifyCitation() }
        model?.loading=false; model?.title=webView.title ?? "Wikipedia"
        model?.canGoBack=webView.canGoBack; model?.canGoForward=webView.canGoForward
        // The isolated client world is the future geometry bridge. Archive scripts are disabled.
        webView.evaluateJavaScript("""
        (() => {
          const headings = [...document.querySelectorAll('h1,h2,h3,h4')].slice(0,300).map((h,i) => {
            if(!h.id) h.id='atlas-heading-'+i;
            return {id:h.id,title:(h.textContent||'').trim(),level:Number(h.tagName.slice(1))};
          });
          document.querySelectorAll('a[href]').forEach(a => {
            if(/^https?:/i.test(a.href) && !/^https?:\\/\\/([a-z0-9-]+\\.)?wikipedia\\.org\\/wiki\\//i.test(a.href)) {
              a.title='External link — blocked while reading offline'; a.dataset.atlasExternal='true';
            }
          });
          window.webkit.messageHandlers.atlasDocument.postMessage({headings:headings,height:document.documentElement.scrollHeight});
        })()
        """,in:nil,in:.defaultClient) { _ in }
    }
    func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: Error) { failed(error) }
    private func failed(_ error:Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        model?.crawler.intelligence.navigationFailed()
        model?.loading=false; model?.message=AtlasLog.message(error)
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard message.frameInfo.isMainFrame,message.frameInfo.request.url?.host == host,
              let body=message.body as? [String:Any],let headings=body["headings"] as? [[String:Any]] else { return }
        model?.headings=headings.prefix(300).compactMap {
            guard let id=$0["id"] as? String,let title=$0["title"] as? String,let level=$0["level"] as? Int else { return nil }
            return ArticleHeading(id:id,title:title,level:level)
        }
    }
}

@MainActor
enum OfflineWebFactory {
    static func make(provider:any ArticleProvider,host:String,model:BrowserModel) async throws -> WKWebView {
        let config=WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript=false
        config.preferences.javaScriptCanOpenWindowsAutomatically=false
        config.setURLSchemeHandler(OfflineSchemeHandler(provider:provider,host:host),forURLScheme:"atlas")
        let rules="""
        [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]
        """
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"AtlasStrictOffline-v1",encodedContentRuleList:rules) { list,error in
                if let list { continuation.resume(returning:list) } else { continuation.resume(throwing:error ?? AtlasError.articleUnavailable) }
            }
        }
        config.userContentController.add(list)
        let delegate=OfflineBrowserDelegate(model:model,host:host)
        config.userContentController.add(model.crawler,contentWorld:.defaultClient,name:"atlasCrawlerMetrics")
        config.userContentController.add(delegate,contentWorld:.defaultClient,name:"atlasDocument")
        let web=WKWebView(frame:.zero,configuration:config)
        web.navigationDelegate=delegate // UserContentController retains the delegate without retaining the model.
        model.crawler.attach(web)
        web.allowsBackForwardNavigationGestures=true
        return web
    }
}
struct OfflineWebView: NSViewRepresentable {
    let webView: WKWebView
    let crawler:CrawlerController
    func makeNSView(context:Context)->CrawlerSurface { CrawlerSurface(webView:webView,crawler:crawler) }
    func updateNSView(_ nsView:CrawlerSurface,context:Context) {}
}
