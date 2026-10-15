import SwiftUI
import AtlasCore

struct BrowserView: View {
    @Bindable var library: PackageLibraryModel
    @Bindable var browser: BrowserModel
    var emphasizeSearch=false
    var emphasizeCrawl=false
    /// Shows Library (Packages), where downloads, archives and link maps live.
    var showLibrary: () -> Void = {}
    @State private var showCrawler=true
    @State private var showSearch=false

    var body: some View {
        // Size the reader from its window, not the combined ideal sizes of
        // AppKit's split view and the expanding conversation/debug content.
        GeometryReader { container in
            VStack(spacing:0) {
                HStack {
                    Button(action:browser.back) { Image(systemName:"chevron.left") }.disabled(!browser.canGoBack).help("Back")
                    Button(action:browser.forward) { Image(systemName:"chevron.right") }.disabled(!browser.canGoForward).help("Forward")
                    Menu {
                        ForEach(library.readable) { record in
                            Button("\(record.package.language) · \(record.package.name) · \(record.package.version)") { Task { await library.open(record) } }
                        }
                        if library.readable.isEmpty { Text("No readable packages yet") }
                        if !library.archives.isEmpty {
                            Divider()
                            // Wikimedia archives are data tables: they can't be opened, so say what they're for.
                            Section("\(library.archives.count) Wikimedia archive\(library.archives.count == 1 ? "" : "s") (.gz): data, not articles") {
                                if !library.dumpSets.isEmpty { Button("Build a Link Map from Them…") { library.packagesSection="Installed"; showLibrary() } }
                                Button("Show Them in Packages") { library.packagesSection="Installed"; showLibrary() }
                            }
                        }
                        if library.readable.isEmpty {
                            Divider()
                            Button("Get a Wikipedia Package…") { library.showReadablePackages(); showLibrary() }
                        }
                    } label: { Label(browser.record?.package.name ?? "Open a package",systemImage:"book") }
                    Button {showCrawler.toggle()} label: {CompanionToolbarLabel(active:showCrawler || emphasizeCrawl,busy:browser.crawler.conversation.busy)}
                        .buttonStyle(.plain).help(showCrawler ? "Hide the companion" : "Show the companion")
                    Spacer()
                    if browser.loading { ProgressView().controlSize(.small) }
                    languagesMenu
                    Menu {
                        ForEach(browser.headings) { heading in Button(heading.title) { browser.scroll(to:heading) } }
                    } label: { Label("Contents",systemImage:"list.bullet") }.disabled(browser.headings.isEmpty)
                    Toggle(isOn:$showSearch) { Image(systemName:"magnifyingglass") }.toggleStyle(.button).help("Show title search")
                }.padding(12)
                if let message=browser.message { Text(message).font(.callout).foregroundStyle(.orange).padding(10) }
                Divider()
                if container.size.width >= 800 {
                    HStack(spacing:0) {
                        reader
                        if showCrawler || emphasizeCrawl {
                            Divider()
                            CompanionPanel(conversation:browser.crawler.conversation,crawler:browser.crawler)
                                .frame(width:350)
                        }
                    }
                } else {
                    VStack(spacing:0) {
                        if showCrawler || emphasizeCrawl {
                            CompanionPanel(conversation:browser.crawler.conversation,crawler:browser.crawler)
                                .frame(height: min(330,container.size.height * 0.48))
                            Divider()
                        }
                        reader
                    }
                }
            }
            .frame(width:container.size.width,height:container.size.height,alignment:.top)
        }
    }
    /// The open article in other languages' Wikipedias (from the link map). Languages with an installed
    /// package open it there; the rest are listed so you know what exists.
    @ViewBuilder private var languagesMenu: some View {
        let languages=browser.articleLanguages()
        if !languages.isEmpty {
            let readable=languages.filter { $0.record != nil }
            Menu {
                if readable.isEmpty { Text("No package in these languages yet") }
                ForEach(readable) { item in
                    Button("\(item.link.name) · \(item.link.title)") { if let record=item.record { browser.openArticle(record,item.link.title) } }
                }
                Divider()
                Menu("All \(languages.count) Languages") {
                    ForEach(languages) { item in
                        if let record=item.record { Button("\(item.link.name) · \(item.link.title)") { browser.openArticle(record,item.link.title) } }
                        else { Text("\(item.link.name) · \(item.link.title)") }
                    }
                }
                Button("Get Wikipedia in Another Language…") { library.showReadablePackages(); showLibrary() }
            } label: { Label(readable.isEmpty ? "Languages" : "Languages (\(readable.count))",systemImage:"globe") }
                .help("This article in other languages, from the link map")
        }
    }

    @ViewBuilder private var reader:some View {
        if let web=browser.webView {
                    // NSSplitView retains its previous fitting height. Contain it in
                    // the available reader area so revealing controls cannot grow
                    // the window (and push the toolbar above the screen).
                    GeometryReader { area in
                    HSplitView {
                        if showSearch || emphasizeSearch {
                            VStack(alignment:.leading,spacing:12) {
                                Text("Search this package").font(.headline)
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
                    .frame(width:area.size.width,height:area.size.height)
                    }
                } else if library.storageAvailable && library.readable.isEmpty && !library.archives.isEmpty {
                    // Only Wikimedia archives are installed: explain why there's nothing to open.
                    ContentUnavailableView {
                        Label("Nothing to read yet",systemImage:"book.closed")
                    } description: {
                        Text("The .gz files you downloaded from Wikimedia archives are database tables, not articles, so Browse can't open them. To read, download a ZIM package from the Kiwix library."+(library.dumpSets.isEmpty ? "" : " Your Wikipedia tables can then be built into a link map, which makes Connect the dots, “what links here” and category questions exact and fast in that package."))
                    } actions: {
                        Button("Get a Wikipedia Package") { library.showReadablePackages(); showLibrary() }.buttonStyle(.borderedProminent)
                        if !library.dumpSets.isEmpty { Button("Build the Link Map") { library.packagesSection="Installed"; showLibrary() } }
                    }
                } else {
                    ContentUnavailableView("Open your offline library",systemImage:"book.closed",
                                           description:Text(library.storageAvailable ? "Download a browsable package in Library, then choose Open. Installed packages also appear in the menu above." : "Choose or reconnect your library storage to browse offline articles."))
                }
    }
}
