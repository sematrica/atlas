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

struct CompanionPanel:View {
    @Bindable var conversation:CrawlerConversation
    @Bindable var crawler:CrawlerController
    @State private var manual=false
    private let gold=Color(red:0.85,green:0.73,blue:0.49)
    private let ink=Color(red:0.065,green:0.078,blue:0.083)
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"sparkle").font(.system(size:21,weight:.ultraLight)).foregroundStyle(gold)
                    .frame(width:36,height:36).background(gold.opacity(0.08),in:Circle()).overlay(Circle().stroke(gold.opacity(0.25)))
                VStack(alignment:.leading,spacing:2) {
                    Text("ATLAS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(4).foregroundStyle(gold)
                    Text("Your reading companion").font(.system(size:12)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button {manual.toggle()} label: {Image(systemName:"slider.horizontal.3").foregroundStyle(.white.opacity(0.6))}.buttonStyle(.plain).help("Manual crawler tools")
                    .popover(isPresented:$manual) {ScrollView {CrawlerControls(crawler:crawler)}.frame(width:620,height:300)}
            }.padding(.horizontal,20).padding(.top,18).padding(.bottom,14)
            HStack(alignment:.top,spacing:8) {
                Image(systemName:"book.closed").font(.system(size:12)).foregroundStyle(gold.opacity(0.65))
                VStack(alignment:.leading,spacing:4) {
                    Text(conversation.companionTitle).font(.system(size:12,weight:.medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    Text(crawler.intelligence.model.isEmpty ? "Choose a model in Ask" : crawler.intelligence.model)
                        .font(.system(size:10,design:.monospaced)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
                Spacer(minLength:0)
                Circle().fill(crawler.ready ? gold : .gray).frame(width:5,height:5).padding(.top,4)
            }.padding(12).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10)).padding(.horizontal,16)
            ScrollViewReader {proxy in
                ScrollView {
                    VStack(alignment:.leading,spacing:22) {
                        if conversation.lines.isEmpty {
                            VStack(alignment:.leading,spacing:14) {
                                Text("A mind beside\nyour page.").font(.system(size:29,weight:.regular,design:.serif)).foregroundStyle(.white.opacity(0.93))
                                Text("Discuss a thought. Follow a detail.\nWhen you want to see, I'll point.").font(.system(size:13)).foregroundStyle(.white.opacity(0.5)).lineSpacing(4)
                                Button("What do you make of this article?  ↗") {conversation.talk("What do you make of this article?")}.font(.system(size:12)).foregroundStyle(gold).buttonStyle(.plain)
                            }.padding(.vertical,16)
                        }
                        ForEach(Array(conversation.lines.enumerated()),id:\.element.id) {index,line in
                            VStack(alignment:.leading,spacing:8) {
                                Text(line.user ? "YOU" : "ATLAS").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(2).foregroundStyle(line.user ? .white.opacity(0.4) : gold)
                                Text(line.text).font(.system(size:14)).lineSpacing(5).foregroundStyle(.white.opacity(line.user ? 0.70 : 0.91)).textSelection(.enabled)
                                if !line.user && !line.toolActivity.isEmpty &&
                                    (index+1 == conversation.lines.count || conversation.lines[index+1].user) {
                                    CompanionToolActivityView(items:line.toolActivity)
                                        .padding(.top,4)
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(line.user ? 13 : 0)
                                .background(line.user ? .white.opacity(0.045) : .clear,in:RoundedRectangle(cornerRadius:12)).id(line.id)
                        }
                        Color.clear.frame(height:1).id("companion-bottom")
                    }.padding(20)
                }
                .onChange(of:conversation.lines.last?.id) {withAnimation(.easeOut(duration:0.2)) {proxy.scrollTo("companion-bottom",anchor:.bottom)}}
            }
            if let id=conversation.companionFocus,let result=conversation.companionResults.first(where:{$0.id == id}),result.canDemonstrate {
                Button {conversation.demonstrateFocused()} label: {
                    HStack {Image(systemName:"scope");Text("\(result.count) · \(result.title)").lineLimit(1);Spacer();Image(systemName:"arrow.up.right")}
                        .font(.system(size:11,weight:.medium)).foregroundStyle(gold).padding(11)
                        .background(gold.opacity(0.065),in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(gold.opacity(0.18)))
                }.buttonStyle(.plain).padding(.horizontal,16).padding(.bottom,10).help("Demonstrate this saved finding")
            }
            if (conversation.companionBusy || conversation.pageTaskActive) && !conversation.companionToolActivity.isEmpty {
                CompanionToolActivityView(items:conversation.companionToolActivity,live:true)
                    .padding(.horizontal,16).padding(.bottom,10)
            }
            HStack(spacing:7) {
                if conversation.companionBusy {ProgressView().controlSize(.mini).tint(gold)}
                Text(conversation.companionStatus).font(.system(size:10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer(minLength:0)
                if conversation.companionBusy || conversation.pageTaskActive {Button("Stop",action:conversation.stopCompanion).font(.system(size:10)).buttonStyle(.plain).foregroundStyle(gold)}
            }.padding(.horizontal,19).padding(.bottom,8).help(conversation.companionCoverage)
            if !conversation.companionCoverage.isEmpty {Text(conversation.companionCoverage).font(.system(size:9)).foregroundStyle(.white.opacity(0.3)).lineLimit(1).padding(.horizontal,18).padding(.bottom,7)}
            HStack(alignment:.bottom,spacing:8) {
                TextField("A question, a thought, a challenge…",text:$conversation.input,axis:.vertical).lineLimit(1...4)
                    .textFieldStyle(.plain).font(.system(size:13)).foregroundStyle(.white).onSubmit {conversation.talk()}
                Button {conversation.talk()} label: {
                    Image(systemName:"arrow.up").font(.system(size:12,weight:.semibold)).foregroundStyle(ink).frame(width:28,height:28).background(gold,in:RoundedRectangle(cornerRadius:8))
                }.buttonStyle(.plain).disabled(conversation.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityLabel("Send message")
            }.padding(12).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(.white.opacity(0.12))).padding(.horizontal,16).padding(.bottom,16)
        }
        .background(LinearGradient(colors:[Color(red:0.10,green:0.115,blue:0.12),ink],startPoint:.topLeading,endPoint:.bottomTrailing))
        .colorScheme(.dark)
    }
}

private struct CompanionToolActivityView:View {
    let items:[CompanionToolActivity]
    var live=false
    private let gold=Color(red:0.85,green:0.73,blue:0.49)
    private let columns=[GridItem(.flexible(),spacing:6),GridItem(.flexible(),spacing:6)]

    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(spacing:6) {
                Image(systemName:live ? "circle.dotted.circle" : "square.stack.3d.up")
                    .font(.system(size:10))
                    .foregroundStyle(gold)
                Text(live ? "TOOLS IN USE" : "TOOLS FOR THIS REPLY")
                    .font(.system(size:9,weight:.semibold,design:.monospaced))
                    .tracking(1.3)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength:0)
                Text("\(items.filter {$0.state == .used}.count) used")
                    .font(.system(size:9,design:.monospaced))
                    .foregroundStyle(gold.opacity(0.8))
            }
            LazyVGrid(columns:columns,alignment:.leading,spacing:6) {
                ForEach(items) {item in
                    HStack(spacing:5) {
                        Circle().fill(color(item.state)).frame(width:5,height:5)
                        Text(item.title).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(.white.opacity(item.state == .idle || item.state == .unavailable ? 0.48 : 0.86))
                        Spacer(minLength:1)
                        Text(label(item.state))
                            .foregroundStyle(color(item.state))
                    }
                    .font(.system(size:9,weight:.medium))
                    .padding(.horizontal,7).padding(.vertical,6)
                    .background(.white.opacity(item.state == .used || item.state == .working ? 0.055 : 0.025),in:RoundedRectangle(cornerRadius:6))
                    .overlay(RoundedRectangle(cornerRadius:6).stroke(.white.opacity(item.state == .used || item.state == .working ? 0.10 : 0.045)))
                    .help(item.detail.isEmpty ? "\(item.title): \(label(item.state))" : "\(item.title): \(label(item.state)). \(item.detail)")
                    .accessibilityLabel("\(item.title), \(label(item.state))")
                    .accessibilityHint(Text(item.detail))
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.025),in:RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).stroke(.white.opacity(0.08)))
    }

    private func label(_ state:CompanionToolState)->String {
        switch state {
        case .used:return "Used"
        case .working:return "Working"
        case .failed:return "Failed"
        case .idle:return "Not used"
        case .unavailable:return "Unavailable"
        }
    }

    private func color(_ state:CompanionToolState)->Color {
        switch state {
        case .used:return gold
        case .working:return .cyan
        case .failed:return .orange
        case .idle:return .white.opacity(0.32)
        case .unavailable:return .orange.opacity(0.7)
        }
    }
}
