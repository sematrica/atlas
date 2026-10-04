import SwiftUI
import AtlasCore

struct BrowserView: View {
    @Bindable var library: PackageLibraryModel
    @Bindable var browser: BrowserModel
    var emphasizeSearch=false
    var emphasizeCrawl=false
    @State private var showCrawler=false
    @State private var showSearch=true
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Button(action:browser.back) { Image(systemName:"chevron.left") }.disabled(!browser.canGoBack).help("Back")
                Button(action:browser.forward) { Image(systemName:"chevron.right") }.disabled(!browser.canGoForward).help("Forward")
                Menu {
                    ForEach(library.installed.filter {$0.package.format == .zim && $0.state == .installed}) { record in
                        Button("\(record.package.language) · \(record.package.name) · \(record.package.version)") { Task { await library.open(record) } }
                    }
                } label: { Label(browser.record?.package.name ?? "Open Wikipedia",systemImage:"book") }
                Button("Crawl") {showCrawler.toggle()}
                Spacer()
                if browser.loading { ProgressView().controlSize(.small) }
                Menu {
                    ForEach(browser.headings) { heading in Button(heading.title) { browser.scroll(to:heading) } }
                } label: { Label("Contents",systemImage:"list.bullet") }.disabled(browser.headings.isEmpty)
                Toggle(isOn:$showSearch) { Image(systemName:"magnifyingglass") }.toggleStyle(.button).help("Show title search")
            }.padding(12)
            if let message=browser.message { Text(message).font(.callout).foregroundStyle(.orange).padding(10) }
            if showCrawler || emphasizeCrawl { CrawlerControls(crawler:browser.crawler) }
            Divider()
            if let web=browser.webView {
                HSplitView {
                    if showSearch || emphasizeSearch {
                        VStack(alignment:.leading,spacing:12) {
                            Text("Search this Wikipedia").font(.headline)
                            TextField("Article title",text:$browser.query).textFieldStyle(.roundedBorder)
                                .onChange(of:browser.query) { browser.search() }
                            if browser.searching { ProgressView().controlSize(.small) }
                            if let message=browser.searchMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                            List(Array(browser.results.enumerated()),id:\.offset) { _,result in
                                Button { browser.select(result) } label: {
                                    Text(result.title).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,4)
                                }.buttonStyle(.plain)
                            }.listStyle(.plain)
                            Text("Local title index · No Internet required").font(.caption2).foregroundStyle(.secondary)
                        }.padding(14).frame(minWidth:200,idealWidth:250,maxWidth:320)
                    }
                    OfflineWebView(webView:web,crawler:browser.crawler).id(browser.sessionID).frame(minWidth:350,maxWidth:.infinity,maxHeight:.infinity)
                }
            } else {
                ContentUnavailableView("Open your offline Wikipedia",systemImage:"book.closed",
                                       description:Text(library.storageAvailable ? "Download a browsable package in Library, then choose Open. Installed packages also appear in the menu above." : "Choose or reconnect your library storage to browse offline articles."))
            }
        }
    }
}
