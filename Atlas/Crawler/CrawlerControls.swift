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
    private let suggestions=["Highlight the adjectives in green","How many links are on this page?","Take me to the longest word","What is this article about?"]
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
                    HStack(spacing:6) {
                        Text(crawler.intelligence.model.isEmpty ? "No chat model · choose one in Ask" : crawler.intelligence.model)
                            .font(.system(size:10,design:.monospaced)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                        if let fit=crawler.intelligence.fit,!crawler.intelligence.model.isEmpty {FitBadge(fit:fit)}
                    }
                }
                Spacer(minLength:0)
                Circle().fill(crawler.ready ? gold : .gray).frame(width:5,height:5).padding(.top,4)
            }.padding(12).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10)).padding(.horizontal,16)
            ScrollViewReader {proxy in
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        if conversation.lines.isEmpty {
                            VStack(alignment:.leading,spacing:14) {
                                Text("A mind beside\nyour page.").font(.system(size:29,weight:.regular,design:.serif)).foregroundStyle(.white.opacity(0.93))
                                Text("Ask me anything about the article, or give me a task.\nThe spider is my pair of hands.").font(.system(size:13)).foregroundStyle(.white.opacity(0.5)).lineSpacing(4)
                                VStack(alignment:.leading,spacing:8) {
                                    ForEach(suggestions,id:\.self) {suggestion in
                                        Button(suggestion+"  ↗") {conversation.send(suggestion)}.font(.system(size:12)).foregroundStyle(gold).buttonStyle(.plain)
                                    }
                                }
                            }.padding(.vertical,16)
                        }
                        ForEach(conversation.lines) {line in
                            VStack(alignment:.leading,spacing:6) {
                                Text(line.user ? "YOU" : "ATLAS").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(2)
                                    .foregroundStyle(line.user ? .white.opacity(0.4) : line.isError ? .orange : gold)
                                Text(line.text).font(.system(size:14)).lineSpacing(5).foregroundStyle(.white.opacity(line.user ? 0.70 : 0.91)).textSelection(.enabled)
                                if !line.trail.isEmpty {
                                    Text(line.trail.joined(separator:"  ·  ")).font(.system(size:9,design:.monospaced)).foregroundStyle(.white.opacity(0.35))
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(line.user ? 13 : 0)
                                .background(line.user ? .white.opacity(0.045) : .clear,in:RoundedRectangle(cornerRadius:12)).id(line.id)
                        }
                        Color.clear.frame(height:1).id("companion-bottom")
                    }.padding(20)
                }
                .onChange(of:conversation.lines.last?.id) {withAnimation(.easeOut(duration:0.2)) {proxy.scrollTo("companion-bottom",anchor:.bottom)}}
            }
            if !conversation.layers.isEmpty {HighlightLegend(conversation:conversation).padding(.horizontal,16).padding(.bottom,8)}
            if let result=conversation.focused,result.canDemonstrate,!conversation.busy {
                Button {conversation.demonstrateFocused()} label: {
                    HStack {Image(systemName:"scope");Text("\(result.id) · \(result.count) \(result.label)").lineLimit(1);Spacer();Image(systemName:"arrow.up.right")}
                        .font(.system(size:11,weight:.medium)).foregroundStyle(gold).padding(11)
                        .background(gold.opacity(0.065),in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(gold.opacity(0.18)))
                }.buttonStyle(.plain).padding(.horizontal,16).padding(.bottom,10).help("Show this result again")
            }
            HStack(spacing:7) {
                if conversation.busy {ProgressView().controlSize(.mini).tint(gold)}
                Text(conversation.status).font(.system(size:10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer(minLength:0)
                if conversation.canFinish {Button("Finish now",action:conversation.finishTour).font(.system(size:10)).buttonStyle(.plain).foregroundStyle(gold).help("Highlight the rest at once")}
                if conversation.busy || conversation.touring || crawler.active {Button("Stop",action:conversation.stopAll).font(.system(size:10)).buttonStyle(.plain).foregroundStyle(gold)}
            }.padding(.horizontal,19).padding(.bottom,8)
            HStack(alignment:.bottom,spacing:8) {
                TextField("A question, a task, a challenge…",text:$conversation.input,axis:.vertical).lineLimit(1...4)
                    .textFieldStyle(.plain).font(.system(size:13)).foregroundStyle(.white).onSubmit {conversation.send()}
                Button {conversation.send()} label: {
                    Image(systemName:"arrow.up").font(.system(size:12,weight:.semibold)).foregroundStyle(ink).frame(width:28,height:28).background(gold,in:RoundedRectangle(cornerRadius:8))
                }.buttonStyle(.plain).disabled(conversation.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityLabel("Send message")
            }.padding(12).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(.white.opacity(0.12))).padding(.horizontal,16).padding(.bottom,16)
        }
        .background(LinearGradient(colors:[Color(red:0.10,green:0.115,blue:0.12),ink],startPoint:.topLeading,endPoint:.bottomTrailing))
        .colorScheme(.dark)
    }
}

/// The highlight layers on the page, each removable.
private struct HighlightLegend:View {
    @Bindable var conversation:CrawlerConversation
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text("HIGHLIGHTS").font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(1.3).foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button("Clear all",action:conversation.clearAllLayers).font(.system(size:10)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.55))
            }
            ForEach(conversation.layers) {layer in
                HStack(spacing:7) {
                    HStack(spacing:0) {
                        ForEach(Array(layer.style.palette.prefix(6).enumerated()),id:\.offset) {_,hex in Rectangle().fill(Color(hex:hex))}
                    }.frame(width:22,height:10).clipShape(RoundedRectangle(cornerRadius:3))
                    Text("\(layer.label)").font(.system(size:11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Text("\(layer.count)").font(.system(size:10,design:.monospaced)).foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength:0)
                    Button {conversation.removeLayer(layer.id)} label: {Image(systemName:"xmark").font(.system(size:9,weight:.semibold))}
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45)).help("Remove these highlights")
                }
            }
        }.padding(10).background(.white.opacity(0.03),in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(.white.opacity(0.07)))
    }
}

/// Strong / medium / weak fit of the chosen chat model.
struct FitBadge:View {
    let fit:ModelFitBadge
    var body:some View {
        Text(fit.rating.title.replacingOccurrences(of:" fit",with:"")+(fit.measured ? "" : "?"))
            .font(.system(size:9,weight:.semibold)).padding(.horizontal,6).padding(.vertical,2)
            .foregroundStyle(color).background(color.opacity(0.14),in:Capsule())
            .help(fit.summary+(fit.measured ? "" : " (estimate; run the fit test in Ask to measure)"))
    }
    var color:Color {
        switch fit.rating {
        case .strong: .green
        case .medium: .yellow
        case .weak: .orange
        case .unknown: .gray
        }
    }
}

extension Color {
    init(hex:String) {
        let value=Int(hex.dropFirst(),radix:16) ?? 0
        self.init(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255)
    }
}
