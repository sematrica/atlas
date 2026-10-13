import SwiftUI

private enum Destination: String, CaseIterable, Identifiable {
    case library = "Library", browse = "Browse", search = "Search", ask = "Ask", crawl = "Crawl", research = "Research"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .library: "externaldrive"
        case .browse: "book"
        case .search: "magnifyingglass"
        case .ask: "text.bubble"
        case .research: "text.book.closed"
        case .crawl: "point.3.connected.trianglepath.dotted"
        }
    }
    var subtitle: String {
        switch self {
        case .library: "Offline Wikipedia library"
        case .browse: "An encyclopedia, entirely yours."
        case .search: "A direct route to what you need."
        case .ask: "Answers grounded in your library."
        case .research: "Research your offline library."
        case .crawl: "Let curiosity find a path."
        }
    }
    var detail: String {
        switch self {
        case .library: ""
        case .browse: "Read local Wikipedia articles, follow their links, and pick up where you left off."
        case .search: "Find titles and passages with fast, conventional full-text search. No language model required."
        case .ask: "Explore questions with a local model and citations that lead back to your offline articles."
        case .research: "Autonomous reading, evidence, and cited reports."
        case .crawl: "A procedural creature will explore article terrain and follow links through your library, one discovery at a time."
        }
    }
}

struct ContentView: View {
    @Bindable var library: LibraryViewModel
    @State private var destination: Destination? = .library

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $destination) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
                    .padding(.vertical, 5)
            }
            .navigationTitle("Sematrica")
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ATLAS").font(.caption.weight(.semibold)).tracking(3)
                    Text("wikipedia").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } detail: {
            let current = destination ?? .library
            Group {
                if current == .library {
                    LibraryView(model: library)
                } else if current == .browse || current == .search || current == .crawl {
                    BrowserView(library: library.packages, browser: library.packages.browser, emphasizeSearch: current == .search, emphasizeCrawl: current == .crawl)
                } else if current == .research {
                    ResearchView(research:library.packages.research,ai:library.packages.intelligence,browser:library.packages.browser,openSource:{passage in library.packages.browser.openCitation(passage);destination = .browse})
                } else if current == .ask {
                    IntelligenceView(ai:library.packages.intelligence,browser:library.packages.browser,
                        openSource:{passage in library.packages.browser.openCitation(passage);destination = .browse},
                        explore:{mission in
                            let crawler=library.packages.browser.crawler
                            crawler.target=mission
                            crawler.intelligence.model=library.packages.intelligence.chatModel
                            destination = .crawl
                            crawler.start(hunt:false,semantic:true)
                        })
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: current.symbol)
                            .font(.system(size: 40, weight: .light)).foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(current.subtitle).font(.system(size: 29, weight: .medium, design: .serif))
                        Text(current.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        Text("Planned for a future stage")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(current.rawValue)
        }
        .onChange(of: library.packages.browser.record?.id) { _, id in
            if id != nil { destination = .browse }
        }
        .tint(Color(red: 0.18, green: 0.48, blue: 0.43))
        .alert("Storage couldn’t be configured", isPresented: Binding(
            get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
    }
}
