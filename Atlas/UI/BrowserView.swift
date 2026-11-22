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
    @State private var showVisitedMap=false

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
                    Button {showVisitedMap=true} label: {
                        Label("Visit board",systemImage:"point.3.connected.trianglepath.dotted")
                    }.help("Map the articles you have visited and the links they share")
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
        .sheet(isPresented:$showVisitedMap) {VisitedMapView(browser:browser)}
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

private enum VisitBoardTheme:String,CaseIterable,Identifiable {
    case evidence,monochrome,grafana,blueprint
    var id:String {rawValue}
    var name:String {
        switch self {
        case .evidence:"Evidence board"
        case .monochrome:"Black & white"
        case .grafana:"Grafana"
        case .blueprint:"Midnight blueprint"
        }
    }
    var heading:String {
        switch self {
        case .evidence:"THE VISIT BOARD"
        case .monochrome:"VISITED ARTICLES"
        case .grafana:"LINK OBSERVATORY"
        case .blueprint:"ARTICLE BLUEPRINT"
        }
    }
    var caption:String {
        switch self {
        case .evidence:"Every article you opened. Every thread it shares."
        case .monochrome:"A clear map of your reading history."
        case .grafana:"Local article traffic and shared destinations."
        case .blueprint:"A schematic of the paths you have traced."
        }
    }
    var detailHeading:String {
        switch self {
        case .evidence:"CASE FILE"
        case .monochrome:"ARTICLE"
        case .grafana:"NODE DETAILS"
        case .blueprint:"FIELD RECORD"
        }
    }
    var palette:VisitBoardPalette {
        switch self {
        case .evidence:
            .init(background:Color(red:0.085,green:0.075,blue:0.073),header:Color(red:0.13,green:0.105,blue:0.09),
                  boardTop:Color(red:0.22,green:0.18,blue:0.14),boardBottom:Color(red:0.11,green:0.105,blue:0.11),
                  primary:Color(red:0.88,green:0.82,blue:0.66),muted:Color(red:0.70,green:0.65,blue:0.56),
                  direct:Color(red:0.95,green:0.42,blue:0.27),shared:Color(red:0.96,green:0.68,blue:0.43),
                  card:Color(red:0.88,green:0.82,blue:0.66),cardText:Color(red:0.19,green:0.15,blue:0.13),
                  cardMeta:Color(red:0.42,green:0.37,blue:0.32),panel:Color(red:0.12,green:0.10,blue:0.095),
                  edge:Color(red:0.30,green:0.24,blue:0.20))
        case .monochrome:
            .init(background:.white,header:.white,boardTop:Color(white:0.98),boardBottom:.white,
                  primary:.black,muted:Color(white:0.38),direct:.black,shared:Color(white:0.55),
                  card:.white,cardText:.black,cardMeta:Color(white:0.42),panel:.white,edge:Color(white:0.74))
        case .grafana:
            .init(background:Color(red:0.065,green:0.075,blue:0.10),header:Color(red:0.11,green:0.12,blue:0.15),
                  boardTop:Color(red:0.09,green:0.105,blue:0.13),boardBottom:Color(red:0.055,green:0.07,blue:0.09),
                  primary:Color(red:0.92,green:0.94,blue:0.96),muted:Color(red:0.57,green:0.64,blue:0.71),
                  direct:Color(red:1.0,green:0.59,blue:0.18),shared:Color(red:0.36,green:0.80,blue:0.88),
                  card:Color(red:0.13,green:0.15,blue:0.19),cardText:.white,
                  cardMeta:Color(red:0.57,green:0.67,blue:0.74),panel:Color(red:0.11,green:0.13,blue:0.17),
                  edge:Color(red:0.25,green:0.29,blue:0.34))
        case .blueprint:
            .init(background:Color(red:0.025,green:0.065,blue:0.12),header:Color(red:0.035,green:0.095,blue:0.16),
                  boardTop:Color(red:0.035,green:0.11,blue:0.20),boardBottom:Color(red:0.02,green:0.07,blue:0.14),
                  primary:Color(red:0.78,green:0.94,blue:0.98),muted:Color(red:0.43,green:0.69,blue:0.78),
                  direct:Color(red:0.30,green:0.83,blue:0.95),shared:Color(red:1.0,green:0.78,blue:0.39),
                  card:Color(red:0.04,green:0.15,blue:0.24),cardText:Color(red:0.86,green:0.97,blue:1.0),
                  cardMeta:Color(red:0.48,green:0.78,blue:0.86),panel:Color(red:0.035,green:0.12,blue:0.21),
                  edge:Color(red:0.21,green:0.50,blue:0.62))
        }
    }
}

private struct VisitBoardPalette {
    let background:Color
    let header:Color
    let boardTop:Color
    let boardBottom:Color
    let primary:Color
    let muted:Color
    let direct:Color
    let shared:Color
    let card:Color
    let cardText:Color
    let cardMeta:Color
    let panel:Color
    let edge:Color
}

/// A tactile board for articles actually opened in the offline reader.
private struct VisitedMapView:View {
    @Bindable var browser:BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var packageFilter="all"
    @State private var selectedID:String?
    @State private var hoveredID:String?
    @State private var search=""
    @State private var showShared=true
    @State private var zoom=0.8
    @State private var settledZoom=0.8
    @State private var pan=CGSize.zero
    @State private var settledPan=CGSize.zero
    @State private var dragged:[String:CGPoint]=[:]
    @AppStorage("VisitBoardTheme") private var themeName=VisitBoardTheme.evidence.rawValue
    private var theme:VisitBoardTheme {VisitBoardTheme(rawValue:themeName) ?? .evidence}
    private var palette:VisitBoardPalette {theme.palette}
    private var paper:Color {palette.primary}
    private var ember:Color {palette.direct}
    private var thread:Color {palette.shared}

    private var articles:[VisitedArticle] {
        browser.visitedGraph.articles.filter {packageFilter == "all" || $0.packageID == packageFilter}
    }
    private var connections:[VisitConnection] {browser.visitedGraph.connections(packageID:packageFilter == "all" ? nil:packageFilter)}
    private var selected:VisitedArticle? {articles.first {$0.id == selectedID}}
    private var packages:[(String,String)] {
        var seen=Set<String>()
        return browser.visitedGraph.articles.compactMap {seen.insert($0.packageID).inserted ? ($0.packageID,$0.packageName):nil}
    }
    var body:some View {
        VStack(spacing:0) {
            header
            GeometryReader {area in
                ZStack(alignment:.topLeading) {
                    boardBackground
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance:2)
                            .onChanged {value in pan=CGSize(width:settledPan.width+value.translation.width,height:settledPan.height+value.translation.height)}
                            .onEnded { _ in settledPan=pan })
                    ForEach(connections) {edge in
                        if let a=articles.first(where:{$0.id == edge.fromID}),
                           let b=articles.first(where:{$0.id == edge.toID}),edge.isDirect || showShared {
                            let emphasized=hoveredID == a.id || hoveredID == b.id || selectedID == a.id || selectedID == b.id
                            connectionPath(from:location(a,in:area.size),to:location(b,in:area.size),
                                           bow:theme == .evidence ? (edge.isDirect ? 18:-18):0)
                                .stroke(edge.isDirect ? ember:thread,style:StrokeStyle(lineWidth:emphasized ? 2.5:(theme == .monochrome ? 1:1.35),lineCap:.round,dash:edge.isDirect ? []:[5,6]))
                                .opacity(emphasized ? 0.95:(theme == .monochrome ? 0.72:0.58)).allowsHitTesting(false)
                        }
                    }
                    ForEach(articles) {article in
                        articleCard(article)
                            .position(location(article,in:area.size))
                            .gesture(DragGesture(minimumDistance:3)
                                .onChanged {value in
                                    dragged[article.id]=CGPoint(x:article.x+value.translation.width/zoom,y:article.y+value.translation.height/zoom)
                                    selectedID=article.id
                                }
                                .onEnded {value in
                                    browser.moveVisit(article.id,to:article.x+value.translation.width/zoom,article.y+value.translation.height/zoom)
                                    dragged[article.id]=nil
                                })
                            .onHover {inside in hoveredID=inside ? article.id:(hoveredID == article.id ? nil:hoveredID)}
                    }
                    if articles.isEmpty {emptyBoard.frame(maxWidth:.infinity,maxHeight:.infinity)}
                    VStack {
                        Spacer()
                        HStack(alignment:.bottom) {
                            legend
                            Spacer()
                            if let selected {inspector(selected)}
                        }.padding(18)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(MagnifyGesture()
                    .onChanged {value in zoom=max(0.28,min(2.2,settledZoom*value.magnification))}
                    .onEnded { _ in settledZoom=zoom })
                .overlay(alignment:.topTrailing) {
                    HStack(spacing:7) {
                        Button {zoom=max(0.28,zoom/1.25);settledZoom=zoom} label:{Image(systemName:"minus.magnifyingglass")}
                        Button {fit(in:area.size)} label:{Image(systemName:"arrow.up.left.and.arrow.down.right")}.help("Fit visited pages")
                        Button {zoom=min(2.2,zoom*1.25);settledZoom=zoom} label:{Image(systemName:"plus.magnifyingglass")}
                    }.buttonStyle(.bordered).padding(18)
                }
            }
        }
        .frame(minWidth:900,minHeight:660)
        .background(palette.background)
        .preferredColorScheme(theme == .monochrome ? .light:.dark)
        .onAppear {if packageFilter == "all",let id=browser.record?.id {packageFilter=id}}
    }
    private var header:some View {
        VStack(spacing:13) {
            HStack(spacing:18) {
                VStack(alignment:.leading,spacing:4) {
                    Text(theme.heading)
                        .font(.system(size:22,weight:.black,design:theme == .evidence ? .serif:.monospaced))
                        .tracking(theme == .evidence ? 3:1.5).foregroundStyle(paper)
                    Text(theme.caption)
                        .font(.caption).foregroundStyle(palette.muted)
                }
                Spacer()
                Text("\(articles.count) FILES  /  \(connections.count) THREADS")
                    .font(.system(size:10,weight:.bold,design:.monospaced)).tracking(2).foregroundStyle(thread)
                Button("Done") {dismiss()}.buttonStyle(.borderedProminent).tint(ember)
            }
            HStack(spacing:14) {
                Picker("Package",selection:$packageFilter) {
                    Text("All packages").tag("all")
                    ForEach(packages,id:\.0) {id,name in Text(name).tag(id)}
                }.frame(width:210)
                TextField("Find a page",text:$search).textFieldStyle(.roundedBorder).frame(width:180)
                Toggle("Shared links",isOn:$showShared).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Picker("Board theme",selection:$themeName) {
                    ForEach(VisitBoardTheme.allCases) {choice in Text(choice.name).tag(choice.rawValue)}
                }.pickerStyle(.menu).frame(width:230)
            }
        }.padding(.horizontal,23).padding(.vertical,16)
            .background(palette.header)
            .overlay(alignment:.bottom) {Rectangle().fill(palette.edge).frame(height:1)}
    }
    private var boardBackground:some View {
        GeometryReader {geometry in
            ZStack {
                LinearGradient(colors:[palette.boardTop,palette.boardBottom],startPoint:.topLeading,endPoint:.bottomTrailing)
                Canvas {context,size in
                    switch theme {
                    case .evidence:
                        for x in stride(from:12.0,through:size.width,by:26) {
                            for y in stride(from:11.0,through:size.height,by:26) {
                                context.fill(Path(ellipseIn:CGRect(x:x,y:y,width:1.1,height:1.1)),with:.color(.white.opacity(0.055)))
                            }
                        }
                    case .monochrome:break
                    case .grafana,.blueprint:
                        let step:CGFloat=theme == .grafana ? 44:28
                        for x in stride(from:CGFloat.zero,through:size.width,by:step) {
                            var line=Path();line.move(to:CGPoint(x:x,y:0));line.addLine(to:CGPoint(x:x,y:size.height))
                            context.stroke(line,with:.color(palette.edge.opacity(theme == .grafana ? 0.22:0.31)),lineWidth:0.65)
                        }
                        for y in stride(from:CGFloat.zero,through:size.height,by:step) {
                            var line=Path();line.move(to:CGPoint(x:0,y:y));line.addLine(to:CGPoint(x:size.width,y:y))
                            context.stroke(line,with:.color(palette.edge.opacity(theme == .grafana ? 0.22:0.31)),lineWidth:0.65)
                        }
                    }
                }
                Rectangle().strokeBorder(palette.edge.opacity(theme == .monochrome ? 0.5:0.35),lineWidth:theme == .evidence ? 7:1).padding(8)
            }.frame(width:geometry.size.width,height:geometry.size.height)
        }.ignoresSafeArea()
    }
    private func location(_ article:VisitedArticle,in size:CGSize)->CGPoint {
        let point=dragged[article.id] ?? CGPoint(x:article.x,y:article.y)
        return CGPoint(x:size.width/2+(point.x-900)*zoom+pan.width,
                       y:size.height/2+(point.y-650)*zoom+pan.height)
    }
    private func connectionPath(from a:CGPoint,to b:CGPoint,bow:CGFloat)->Path {
        var path=Path();path.move(to:a)
        let dx=b.x-a.x,dy=b.y-a.y,length=max(1,hypot(dx,dy))
        path.addQuadCurve(to:b,control:CGPoint(x:(a.x+b.x)/2-dy/length*bow,y:(a.y+b.y)/2+dx/length*bow))
        return path
    }
    private func articleCard(_ article:VisitedArticle)->some View {
        let focused=selectedID == article.id
        let dimmed = !search.isEmpty && article.title.range(of:search,options:[.caseInsensitive,.diacriticInsensitive]) == nil
        return Button {selectedID=article.id} label: {
            VStack(alignment:.leading,spacing:7) {
                HStack {
                    Circle().fill(ember).frame(width:theme == .monochrome ? 7:12,height:theme == .monochrome ? 7:12)
                        .overlay(Circle().stroke(palette.card.opacity(0.75),lineWidth:theme == .evidence ? 1:0))
                        .shadow(color:ember.opacity(theme == .monochrome ? 0:0.65),radius:6)
                    Spacer()
                    Text("#\(article.visitCount)").font(.system(size:9,design:.monospaced)).foregroundStyle(palette.cardMeta)
                }
                Text(article.title).font(.system(size:15,weight:theme == .monochrome ? .medium:.bold,
                                                 design:theme == .evidence ? .serif:theme == .monochrome ? .default:.monospaced))
                    .foregroundStyle(palette.cardText).lineLimit(2)
                Text(article.packageName.uppercased()).font(.system(size:8,weight:.bold,design:.monospaced))
                    .tracking(1).foregroundStyle(palette.cardMeta).lineLimit(1)
            }.padding(12).frame(width:170,height:102)
                .background(palette.card,in:RoundedRectangle(cornerRadius:theme == .grafana ? 7:theme == .monochrome ? 1:3))
                .overlay(RoundedRectangle(cornerRadius:theme == .grafana ? 7:theme == .monochrome ? 1:3)
                    .stroke(focused ? ember:palette.edge,lineWidth:focused ? 2:1))
                .overlay(alignment:.leading) {
                    if theme == .grafana {Rectangle().fill(ember).frame(width:3).padding(.vertical,8)}
                }
                .shadow(color:theme == .monochrome ? .clear:.black.opacity(0.6),radius:focused ? 18:8,x:3,y:5)
                .rotationEffect(.degrees(theme == .evidence ? Double(abs(article.path.hashValue)%7)-3:0))
                .opacity(dimmed ? 0.24:1)
        }.buttonStyle(.plain).help("Select \(article.title) · drag to arrange")
    }
    private var legend:some View {
        VStack(alignment:.leading,spacing:7) {
            Text("THREAD KEY").font(.system(size:10,weight:.bold,design:.monospaced)).tracking(2)
            HStack {Capsule().fill(ember).frame(width:25,height:2);Text("Direct article link")}
            HStack {Capsule().fill(thread).frame(width:25,height:2);Text("Shared destination")}
            Text("Drag cards · drag board · pinch to zoom").foregroundStyle(palette.muted)
        }.font(.caption2).foregroundStyle(paper).padding(12)
            .background(palette.panel.opacity(theme == .monochrome ? 0.96:0.85),in:RoundedRectangle(cornerRadius:theme == .monochrome ? 2:8))
            .overlay(RoundedRectangle(cornerRadius:theme == .monochrome ? 2:8).stroke(palette.edge,lineWidth:1))
    }
    private func inspector(_ article:VisitedArticle)->some View {
        let related=connections.filter {$0.fromID == article.id || $0.toID == article.id}
        return VStack(alignment:.leading,spacing:9) {
            Text(theme.detailHeading).font(.system(size:10,weight:.bold,design:.monospaced)).tracking(2).foregroundStyle(ember)
            Text(article.title).font(.system(size:19,weight:.bold,design:theme == .evidence ? .serif:.monospaced))
                .foregroundStyle(paper).lineLimit(2)
            Text("Visited \(article.visitCount) time\(article.visitCount == 1 ? "" : "s") · \(related.count) connections")
                .font(.caption).foregroundStyle(palette.muted)
            if let strongest=related.sorted(by:{$0.sharedPaths.count>$1.sharedPaths.count}).first {
                let otherID=strongest.fromID == article.id ? strongest.toID:strongest.fromID
                let other=articles.first(where:{$0.id == otherID})?.title ?? "another article"
                Text(strongest.isDirect ? "Linked with \(other)" : "Shares \(strongest.sharedPaths.count) destination\(strongest.sharedPaths.count == 1 ? "" : "s") with \(other)")
                    .font(.caption).foregroundStyle(thread).lineLimit(2)
                if !strongest.sharedPaths.isEmpty {
                    Text("Common trail: "+strongest.sharedPaths.prefix(3).map {
                        String($0.split(separator:"/").last ?? "").replacingOccurrences(of:"_",with:" ")
                    }.joined(separator:", "))
                        .font(.caption2).foregroundStyle(palette.muted).lineLimit(2)
                }
            }
            ForEach(Array(related.prefix(4))) {edge in
                let otherID=edge.fromID == article.id ? edge.toID:edge.fromID
                if let other=articles.first(where:{$0.id == otherID}) {
                    Button {selectedID=other.id} label: {
                        HStack(spacing:7) {
                            Circle().fill(edge.isDirect ? ember:thread).frame(width:6,height:6)
                            Text(other.title).lineLimit(1)
                            Spacer(minLength:0)
                            Image(systemName:"arrow.up.right").font(.caption2)
                        }.font(.caption).foregroundStyle(paper)
                    }.buttonStyle(.plain)
                }
            }
            Button("Open article ↗") {browser.openVisit(article);dismiss()}
                .buttonStyle(.borderedProminent).tint(ember)
        }.padding(16).frame(width:265,alignment:.leading)
            .background(palette.panel.opacity(0.97),in:RoundedRectangle(cornerRadius:theme == .monochrome ? 2:10))
            .overlay(RoundedRectangle(cornerRadius:theme == .monochrome ? 2:10).stroke(palette.edge))
            .shadow(color:theme == .monochrome ? .clear:.black.opacity(0.45),radius:18)
    }
    private var emptyBoard:some View {
        VStack(spacing:12) {
            Image(systemName:"point.3.connected.trianglepath.dotted").font(.system(size:54,weight:.ultraLight)).foregroundStyle(thread)
            Text("The board is waiting for its first clue.")
                .font(.system(size:25,design:theme == .evidence ? .serif:.monospaced)).foregroundStyle(paper)
            Text("Open articles in Browse. Their cards and shared links will appear here, and stay here after relaunch.")
                .font(.callout).foregroundStyle(palette.muted).multilineTextAlignment(.center).frame(maxWidth:430)
        }
    }
    private func fit(in size:CGSize) {
        guard !articles.isEmpty else {return}
        let xs=articles.map(\.x),ys=articles.map(\.y)
        let minX=xs.min() ?? 900,maxX=xs.max() ?? 900,minY=ys.min() ?? 650,maxY=ys.max() ?? 650
        zoom=max(0.28,min(1.25,min((size.width-220)/max(240,maxX-minX),(size.height-210)/max(190,maxY-minY))))
        settledZoom=zoom
        pan=CGSize(width:-(minX+maxX-1800)*zoom/2,height:-(minY+maxY-1300)*zoom/2)
        settledPan=pan
    }
}
