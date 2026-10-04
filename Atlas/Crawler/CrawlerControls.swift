import SwiftUI
import AtlasCore

struct CrawlerControls:View {
    @Bindable var crawler:CrawlerController
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Image(systemName:"point.3.connected.trianglepath.dotted").accessibilityHidden(true)
                TextField("Find an exact phrase…",text:$crawler.target).textFieldStyle(.roundedBorder)
                    .onSubmit {crawler.start(hunt:true)}
                Button("Hunt") {crawler.start(hunt:true)}.disabled(!crawler.ready || crawler.target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Button("Semantic Hunt") {crawler.start(hunt:false,semantic:true)}.disabled(!crawler.ready || crawler.target.isEmpty || crawler.intelligence.model.isEmpty)
                Button("Free Crawl") {crawler.start(hunt:false)}.disabled(!crawler.ready)
                if crawler.active {
                    if crawler.status == .paused {Button("Resume",action:crawler.resume)}else{Button("Pause",action:crawler.pause)}
                    Button("Stop",action:crawler.stop).keyboardShortcut(.escape,modifiers:[])
                }
            }
            HStack {
                Text(crawler.status == .found ? "FOUND" : crawler.status.rawValue.capitalized).font(.caption.weight(.semibold)).foregroundStyle(crawler.status == .found ? .green : .secondary)
                if crawler.status == .found {
                    Button("Find Next",action:crawler.findNext)
                    Button("Resume Crawl",action:crawler.freeAfterFound)
                }
                Spacer()
                Toggle("Auto Follow",isOn:$crawler.autoFollow).toggleStyle(.checkbox)
                Toggle("Debug",isOn:$crawler.debug).toggleStyle(.checkbox)
            }.font(.caption)
            if let error=crawler.error {Text(error).font(.caption).foregroundStyle(.orange)}
            if !crawler.intelligence.path.isEmpty {
                Text(crawler.intelligence.path.map(\.title).joined(separator:" → ")).font(.caption).lineLimit(3)
                if let found=crawler.intelligence.discovery,crawler.status == .found {
                    Text("Why I stopped here: " + found.reason).font(.callout)
                    Text(found.quote).font(.caption).textSelection(.enabled)
                }
                if !crawler.intelligence.note.isEmpty {Text(crawler.intelligence.note).font(.caption).foregroundStyle(.orange)}
                if crawler.intelligence.failed {Button("Continue Exploring",action:crawler.intelligence.continueExploring)}
            }
            if crawler.debug {
                HStack {
                    Text("Perception radius")
                    Slider(value:$crawler.radius,in:80...220,step:10).frame(width:170)
                    Text("\(Int(crawler.radius)) pt").monospacedDigit()
                }.font(.caption)
                ScrollView {Text(crawler.inspector + "\nArticles: \(crawler.intelligence.path.count) · Sections: \(crawler.intelligence.sections.count) · Evaluations: \(crawler.intelligence.evaluations)\nDecision latency: \(crawler.intelligence.latency)s · Relevance: \(crawler.intelligence.confidence)\nLast decision: \(crawler.intelligence.decision)\nExact model input:\n\(crawler.intelligence.prompt)").font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(height:125)
            }
        }.padding(12).background(.bar)
    }
}
