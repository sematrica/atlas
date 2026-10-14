import SwiftUI
import AppKit
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
                Toggle("Touch glow",isOn:$crawler.touchGlow).toggleStyle(.checkbox).help("Words under the spider's feet glow in boxes")
                Picker("Look",selection:$crawler.look) {
                    ForEach(CreatureLook.allCases) {Text($0.title).tag($0)}
                }.pickerStyle(.menu).fixedSize().help("How the creature is drawn")
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
    @State private var expandedLibrary:Set<UUID>=[]
    private let suggestions=["Highlight the adjectives in green","How many links are on this page?","Take me to the longest word","What is this article about?","How many articles mention jazz?"]
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                ConstellationEmblem(busy:conversation.busy).frame(width:42,height:42)
                VStack(alignment:.leading,spacing:3) {
                    Text("SEMATRICA").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(4.5).foregroundStyle(Constellation.starlight)
                        .shadow(color:.white.opacity(0.45),radius:4)
                    Text("Your reading companion").font(.system(size:12)).foregroundStyle(Constellation.dim)
                }
                Spacer()
                Button {manual.toggle()} label: {Image(systemName:"slider.horizontal.3").foregroundStyle(Constellation.dim)}.buttonStyle(.plain).help("Manual crawler tools")
                    .popover(isPresented:$manual) {ScrollView {CrawlerControls(crawler:crawler)}.frame(width:620,height:300)}
            }.padding(.horizontal,20).padding(.top,18).padding(.bottom,14)
            HStack(alignment:.top,spacing:10) {
                ThreadNode(kind:crawler.ready ? .core : .ring,size:8).padding(.top,4)
                VStack(alignment:.leading,spacing:4) {
                    Text(conversation.companionTitle).font(.system(size:12,weight:.medium)).foregroundStyle(.white.opacity(0.88)).lineLimit(2)
                    HStack(spacing:6) {
                        Text(crawler.intelligence.model.isEmpty ? "No chat model · choose one in Ask" : crawler.intelligence.model)
                            .font(.system(size:10,design:.monospaced)).foregroundStyle(Constellation.faint).lineLimit(1)
                        if let fit=crawler.intelligence.fit,!crawler.intelligence.model.isEmpty {FitBadge(fit:fit)}
                    }
                }
                Spacer(minLength:0)
            }.padding(12).constellationCard(radius:10).padding(.horizontal,16)
            ScrollViewReader {proxy in
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        if conversation.lines.isEmpty {
                            VStack(alignment:.leading,spacing:14) {
                                Text("A mind beside\nyour page.").font(.system(size:29,weight:.regular,design:.serif)).foregroundStyle(.white.opacity(0.94))
                                    .shadow(color:.white.opacity(0.18),radius:8)
                                Text("Ask me anything about the article, or give me a task.\nThe spider is my pair of hands.").font(.system(size:13)).foregroundStyle(Constellation.dim).lineSpacing(4)
                                VStack(alignment:.leading,spacing:9) {
                                    ForEach(suggestions,id:\.self) {suggestion in
                                        Button {conversation.send(suggestion)} label: {
                                            HStack(spacing:9) {
                                                ThreadNode(kind:.ring,size:7)
                                                Text(suggestion).foregroundStyle(.white.opacity(0.82))
                                                Image(systemName:"arrow.up.right").font(.system(size:9,weight:.semibold)).foregroundStyle(Constellation.core)
                                            }.font(.system(size:12)).contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }.padding(.vertical,16)
                        }
                        ForEach(conversation.lines) {line in
                            let isLast=line.id == conversation.lines.last?.id
                            VStack(alignment:.leading,spacing:6) {
                                Text(line.user ? "YOU" : "SEMATRICA").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(2)
                                    .foregroundStyle(line.user ? Constellation.faint : line.isError ? Constellation.warning : Constellation.core)
                                Text(line.text).font(.system(size:14)).lineSpacing(5).foregroundStyle(.white.opacity(line.user ? 0.72 : 0.92)).textSelection(.enabled)
                                if !line.trail.isEmpty {
                                    Text(line.trail.joined(separator:"  ·  ")).font(.system(size:9,design:.monospaced)).foregroundStyle(Constellation.faint)
                                }
                                if let library=line.library {
                                    if !library.hits.isEmpty {
                                        LibraryHitList(library:library,conversation:conversation,expanded:expandedLibrary.contains(line.id)) {
                                            if expandedLibrary.contains(line.id) {expandedLibrary.remove(line.id)} else {expandedLibrary.insert(line.id)}
                                        }
                                    }
                                    if library.canContinue,!conversation.busy {
                                        Button {conversation.continueLibrary()} label: {
                                            HStack(spacing:6) {Text("Check more articles");Image(systemName:"arrow.up.right").font(.system(size:9,weight:.semibold))}
                                        }.font(.system(size:12)).foregroundStyle(Constellation.core).buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .padding(line.user ? 12 : 0)
                            .background {if line.user {RoundedRectangle(cornerRadius:11).fill(.white.opacity(0.035))}}
                            .overlay {if line.user {RoundedRectangle(cornerRadius:11).stroke(Constellation.hairline)}}
                            .padding(.leading,22)
                            // Each message is a node on one thread of light, like the creature's spine.
                            .background(alignment:.topLeading) {
                                ZStack(alignment:.top) {
                                    if !isLast {Rectangle().fill(Constellation.thread).frame(width:1).frame(maxHeight:.infinity).padding(.top,12).padding(.bottom,-20)}
                                    ThreadNode(kind:line.user ? .ring : line.isError ? .warning : conversation.busy && isLast ? .core : .star,size:line.user ? 8 : 7,pulsing:conversation.busy && isLast && !line.user)
                                        .padding(.top,line.user ? 14 : 3)
                                }.frame(width:12)
                            }
                            .id(line.id)
                        }
                        Color.clear.frame(height:1).id("companion-bottom")
                    }.padding(20)
                }
                .onChange(of:conversation.lines.last?.id) {withAnimation(.easeOut(duration:0.2)) {proxy.scrollTo("companion-bottom",anchor:.bottom)}}
            }
            if !conversation.layers.isEmpty {HighlightLegend(conversation:conversation).padding(.horizontal,16).padding(.bottom,8)}
            if let result=conversation.focused,result.canDemonstrate,!conversation.busy {
                Button {conversation.demonstrateFocused()} label: {
                    HStack {Image(systemName:"scope").foregroundStyle(Constellation.core);Text("\(result.id) · \(result.count) \(result.label)").lineLimit(1).foregroundStyle(.white.opacity(0.85));Spacer();Image(systemName:"arrow.up.right").foregroundStyle(Constellation.core)}
                        .font(.system(size:11,weight:.medium)).padding(11).constellationCard(radius:9,glow:true)
                }.buttonStyle(.plain).padding(.horizontal,16).padding(.bottom,10).help("Show this result again")
            }
            HStack(spacing:7) {
                if conversation.busy {ThreadNode(kind:.core,size:7,pulsing:true)}
                Text(conversation.status).font(.system(size:10)).foregroundStyle(Constellation.faint).lineLimit(1)
                Spacer(minLength:0)
                if conversation.canFinish {Button("Finish now",action:conversation.finishTour).font(.system(size:10)).buttonStyle(.plain).foregroundStyle(Constellation.core).help("Highlight the rest at once")}
                if conversation.busy || conversation.touring || crawler.active {Button("Stop",action:conversation.stopAll).font(.system(size:10)).buttonStyle(.plain).foregroundStyle(Constellation.core)}
            }.padding(.horizontal,19).padding(.bottom,8)
            HStack(alignment:.bottom,spacing:8) {
                TextField("A question, a task, a challenge…",text:$conversation.input,axis:.vertical).lineLimit(1...4)
                    .textFieldStyle(.plain).font(.system(size:13)).foregroundStyle(.white).onSubmit {conversation.send()}
                let empty=conversation.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                Button {conversation.send()} label: {
                    Image(systemName:"arrow.up").font(.system(size:12,weight:.bold)).foregroundStyle(empty ? Constellation.faint : Constellation.night)
                        .frame(width:28,height:28)
                        .background {
                            if empty {Circle().stroke(Constellation.hairline)}
                            else {Circle().fill(RadialGradient(colors:[Constellation.coreHot,Constellation.core,Constellation.coreDeep],center:.center,startRadius:0,endRadius:15))
                                    .shadow(color:Constellation.core.opacity(0.8),radius:8)}
                        }
                }.buttonStyle(.plain).disabled(empty).accessibilityLabel("Send message")
            }.padding(12).constellationCard(radius:14).padding(.horizontal,16).padding(.bottom,16)
        }
        .background(ConstellationBackdrop())
        .colorScheme(.dark)
    }
}

// MARK: - Constellation theme

/// The look of the constellation creature, shared by the companion: a night sky,
/// threads and nodes of white light, and one orange core.
enum Constellation {
    static let night=Color(red:0.016,green:0.020,blue:0.031)
    static let dusk=Color(red:0.043,green:0.051,blue:0.071)
    static let starlight=Color.white
    static let dim=Color.white.opacity(0.55)
    static let faint=Color.white.opacity(0.38)
    static let hairline=Color.white.opacity(0.13)
    static let thread=Color.white.opacity(0.16)
    static let core=Color(red:1,green:0.59,blue:0.16)
    static let coreHot=Color(red:1,green:0.95,blue:0.84)
    static let coreDeep=Color(red:0.94,green:0.43,blue:0)
    static let warning=Color(red:1,green:0.42,blue:0.30)
}

extension View {
    /// A pane of dark glass with a hairline edge of light.
    func constellationCard(radius:CGFloat,glow:Bool=false)->some View {
        background(RoundedRectangle(cornerRadius:radius).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius:radius).stroke(glow ? Constellation.core.opacity(0.35) : Constellation.hairline))
            .shadow(color:glow ? Constellation.core.opacity(0.18) : .clear,radius:10)
    }
}

/// A node on a thread of light: a ring (your messages), a star (replies), the orange core
/// (work in progress), or a warning.
struct ThreadNode:View {
    enum Kind {case ring,star,core,warning}
    let kind:Kind
    var size:CGFloat=7
    var pulsing=false
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:!pulsing)) {timeline in
            let phase=pulsing ? 0.5+0.5*sin(timeline.date.timeIntervalSinceReferenceDate*3.2) : 0
            node.shadow(color:glow.opacity(0.55+0.35*phase),radius:3+5*phase)
        }
        .frame(width:size+4,height:size+4)
    }
    @ViewBuilder private var node:some View {
        switch kind {
        case .ring: Circle().stroke(Color.white.opacity(0.6),lineWidth:1).frame(width:size,height:size)
        case .star: Circle().fill(Color.white).frame(width:size*0.75,height:size*0.75)
        case .core: Circle().fill(RadialGradient(colors:[Constellation.coreHot,Constellation.core,Constellation.coreDeep],center:.center,startRadius:0,endRadius:size/2)).frame(width:size,height:size)
        case .warning: Circle().stroke(Constellation.warning,lineWidth:1.2).frame(width:size,height:size)
        }
    }
    private var glow:Color {kind == .core ? Constellation.core : kind == .warning ? Constellation.warning : .white}
}

/// The constellation creature in miniature, upright as in the app icon: a haloed head,
/// a spine of glass spheres around an orange core, a lattice, legs ending in ringed feet,
/// and a slanting beam. The core breathes while the companion is working.
struct ConstellationEmblem:View {
    var busy=false
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:!busy)) {timeline in
            let pulse=busy ? 0.5+0.5*sin(timeline.date.timeIntervalSinceReferenceDate*3.2) : 0
            Canvas {context,size in Self.draw(&context,size:size,pulse:pulse)}
        }
        .accessibilityHidden(true)
    }

    static func draw(_ context:inout GraphicsContext,size:CGSize,pulse:Double) {
        let s=min(size.width,size.height),ox=(size.width-s)/2,oy=(size.height-s)/2
        let simple=s<28
        func p(_ x:Double,_ y:Double)->CGPoint {CGPoint(x:ox+x/100*s,y:oy+y/100*s)}
        func r(_ value:Double)->CGFloat {value/100*s}
        func circle(_ x:Double,_ y:Double,_ radius:Double)->Path {
            Path(ellipseIn:CGRect(x:p(x,y).x-r(radius),y:p(x,y).y-r(radius),width:r(radius)*2,height:r(radius)*2))
        }
        // Drawn into whichever context is passed, so the glowing layer below gets its shadow.
        func line(_ g:GraphicsContext,_ points:[(Double,Double)],opacity:Double=0.85,width:Double=0.9) {
            var path=Path();path.move(to:p(points[0].0,points[0].1))
            for point in points.dropFirst() {path.addLine(to:p(point.0,point.1))}
            g.stroke(path,with:.color(.white.opacity(opacity)),lineWidth:max(0.5,r(width)))
        }
        func dot(_ g:GraphicsContext,_ x:Double,_ y:Double,_ radius:Double,opacity:Double=1) {
            g.fill(circle(x,y,radius),with:.color(.white.opacity(opacity)))
        }
        func ring(_ g:GraphicsContext,_ x:Double,_ y:Double,_ radius:Double,opacity:Double=0.7) {
            g.stroke(circle(x,y,radius),with:.color(.white.opacity(opacity)),lineWidth:max(0.5,r(0.8)))
        }
        // The beam, under everything.
        context.drawLayer {layer in
            layer.addFilter(.shadow(color:Constellation.core.opacity(0.9),radius:r(2.5)))
            var beam=Path();beam.move(to:p(54,56));beam.addLine(to:p(80,97))
            layer.stroke(beam,with:.linearGradient(Gradient(colors:[.white.opacity(0.95),Constellation.coreHot.opacity(0.8),.clear]),startPoint:p(54,56),endPoint:p(80,97)),lineWidth:max(0.6,r(1.3)))
        }
        context.drawLayer {layer in
            layer.addFilter(.shadow(color:.white.opacity(0.7),radius:r(1.6)))
            // Legs: three a side, from the body out to ringed feet.
            let legs:[[(Double,Double)]]=[[(44,30),(36,22),(13,22)],[(43,44),(33,40),(13,40)],[(44,58),(34,64),(13,64)]]
            for leg in legs {
                line(layer,leg,opacity:0.8)
                line(layer,leg.map {(100-$0.0,$0.1)},opacity:0.8)
                if !simple {dot(layer,leg[1].0,leg[1].1,1.2);dot(layer,100-leg[1].0,leg[1].1,1.2)}
            }
            // The lattice around the spine.
            let left:[(Double,Double)]=[(50,16),(43,30),(42,44),(43,58),(46,72),(50,78)]
            line(layer,left,opacity:0.75);line(layer,left.map {(100-$0.0,$0.1)},opacity:0.75)
            if !simple {
                line(layer,[(43,30),(50,44),(57,30)],opacity:0.45,width:0.6)
                line(layer,[(42,44),(58,44)],opacity:0.35,width:0.6)
                line(layer,[(43,58),(50,44),(57,58)],opacity:0.4,width:0.6)
            }
            line(layer,[(50,8),(50,92)],opacity:0.6,width:0.7)
            // Joints, the head and its halo, and the tail's fading dots.
            for point in left.dropFirst().dropLast() {dot(layer,point.0,point.1,simple ? 1.6 : 1.3);dot(layer,100-point.0,point.1,simple ? 1.6 : 1.3)}
            ring(layer,50,10,simple ? 6.5 : 5.5);dot(layer,50,10,simple ? 2.6 : 2.2)
            dot(layer,50,84,1.4);dot(layer,50,89,1.1);dot(layer,50,93,0.7)
            for foot in legs.map({$0[2]}) {
                dot(layer,foot.0,foot.1,simple ? 2 : 1.6);dot(layer,100-foot.0,foot.1,simple ? 2 : 1.6)
                if !simple {ring(layer,foot.0,foot.1,3.4,opacity:0.55);ring(layer,100-foot.0,foot.1,3.4,opacity:0.55)}
            }
        }
        // Glass spheres along the spine.
        for (y,radius) in simple ? [(36.0,4.0)] : [(30.0,4.2),(46.0,4.0),(76.0,3.8)] {
            context.fill(circle(50,y,radius),with:.radialGradient(Gradient(colors:[.white.opacity(0.85),.white.opacity(0.3),.white.opacity(0.08)]),center:p(50,y),startRadius:0,endRadius:r(radius)))
            context.stroke(circle(50,y,radius),with:.color(.white.opacity(0.6)),lineWidth:max(0.4,r(0.5)))
        }
        // The orange core, breathing while busy.
        context.drawLayer {layer in
            let radius=simple ? 7.0 : 6.2
            layer.addFilter(.shadow(color:Constellation.core.opacity(0.95),radius:r(4+5*pulse)))
            layer.fill(circle(50,61,radius),with:.radialGradient(Gradient(colors:[Constellation.coreHot,Constellation.core,Constellation.coreDeep]),center:p(50,61),startRadius:0,endRadius:r(radius)))
        }
        if !simple {
            var sparkle=Path();let c=p(50,61)
            sparkle.move(to:CGPoint(x:c.x-r(3.2),y:c.y));sparkle.addLine(to:CGPoint(x:c.x+r(3.2),y:c.y))
            sparkle.move(to:CGPoint(x:c.x,y:c.y-r(3.2)));sparkle.addLine(to:CGPoint(x:c.x,y:c.y+r(3.2)))
            context.stroke(sparkle,with:.color(.white.opacity(0.9)),lineWidth:max(0.4,r(0.5)))
        }
    }
}

/// The companion's night sky: a dark ground with a faint lattice of light behind the header
/// and the trace of a beam, like the creature carries.
struct ConstellationBackdrop:View {
    var body:some View {
        Canvas {context,size in
            context.fill(Path(CGRect(origin:.zero,size:size)),with:.linearGradient(Gradient(colors:[Constellation.dusk,Constellation.night]),startPoint:.zero,endPoint:CGPoint(x:size.width*0.4,y:size.height)))
            // A warm glow behind the emblem.
            let glow=CGPoint(x:41,y:39)
            context.fill(Path(ellipseIn:CGRect(x:glow.x-90,y:glow.y-90,width:180,height:180)),with:.radialGradient(Gradient(colors:[Constellation.core.opacity(0.10),.clear]),center:glow,startRadius:0,endRadius:90))
            // A faint lattice across the top.
            let nodes:[CGPoint]=[CGPoint(x:size.width*0.52,y:22),CGPoint(x:size.width*0.70,y:12),CGPoint(x:size.width*0.86,y:38),CGPoint(x:size.width*0.66,y:62),CGPoint(x:size.width*0.94,y:84),CGPoint(x:size.width*0.78,y:104)]
            var lattice=Path()
            for (a,b) in [(0,1),(1,2),(1,3),(2,3),(2,4),(3,5),(4,5)] {lattice.move(to:nodes[a]);lattice.addLine(to:nodes[b])}
            context.stroke(lattice,with:.color(.white.opacity(0.06)),lineWidth:0.7)
            for node in nodes {context.fill(Path(ellipseIn:CGRect(x:node.x-1.4,y:node.y-1.4,width:2.8,height:2.8)),with:.color(.white.opacity(0.16)))}
            // The trace of the beam, across the far corner.
            var beam=Path();beam.move(to:CGPoint(x:size.width*0.62,y:0));beam.addLine(to:CGPoint(x:size.width*1.05,y:size.height*0.32))
            context.stroke(beam,with:.linearGradient(Gradient(colors:[.clear,Constellation.coreHot.opacity(0.07),.clear]),startPoint:CGPoint(x:size.width*0.62,y:0),endPoint:CGPoint(x:size.width*1.05,y:size.height*0.32)),lineWidth:1)
        }
        .ignoresSafeArea()
    }
}

/// The toolbar's Companion button: the emblem on a night capsule, its edge lit orange while
/// the panel is open and its core breathing while the companion works.
struct CompanionToolbarLabel:View {
    var active:Bool
    var busy=false
    var body:some View {
        HStack(spacing:6) {
            ConstellationEmblem(busy:busy).frame(width:18,height:18)
            Text("Companion").font(.system(size:12,weight:.medium)).foregroundStyle(active ? Constellation.starlight : Constellation.dim)
        }
        .padding(.leading,5).padding(.trailing,10).padding(.vertical,3)
        .background(Capsule().fill(LinearGradient(colors:[Constellation.dusk,Constellation.night],startPoint:.top,endPoint:.bottom)))
        .overlay(Capsule().stroke(active ? Constellation.core.opacity(0.75) : Constellation.hairline,lineWidth:active ? 1 : 0.8))
        .shadow(color:active ? Constellation.core.opacity(0.35) : .clear,radius:5)
        .contentShape(Capsule())
    }
}

/// The highlight layers on the page, each removable.
private struct HighlightLegend:View {
    @Bindable var conversation:CrawlerConversation
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text("HIGHLIGHTS").font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(1.3).foregroundStyle(Constellation.dim)
                Spacer()
                Button("Clear all",action:conversation.clearAllLayers).font(.system(size:10)).buttonStyle(.plain).foregroundStyle(Constellation.core)
            }
            ForEach(conversation.layers) {layer in
                HStack(spacing:7) {
                    HStack(spacing:0) {
                        ForEach(Array(layer.style.palette.prefix(6).enumerated()),id:\.offset) {_,hex in Rectangle().fill(Color(hex:hex))}
                    }.frame(width:22,height:10).clipShape(RoundedRectangle(cornerRadius:3)).overlay(RoundedRectangle(cornerRadius:3).stroke(Constellation.hairline))
                    Text("\(layer.label)").font(.system(size:11)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                    Text("\(layer.count)").font(.system(size:10,design:.monospaced)).foregroundStyle(Constellation.faint)
                    Spacer(minLength:0)
                    Button {conversation.removeLayer(layer.id)} label: {Image(systemName:"xmark").font(.system(size:9,weight:.semibold))}
                        .buttonStyle(.plain).foregroundStyle(Constellation.faint).help("Remove these highlights")
                }
            }
        }.padding(10).constellationCard(radius:10)
    }
}

/// Strong / medium / weak fit of the chosen chat model: starlight, the orange core, or a warning.
struct FitBadge:View {
    let fit:ModelFitBadge
    var body:some View {
        Text(fit.rating.title.replacingOccurrences(of:" fit",with:"")+(fit.measured ? "" : "?"))
            .font(.system(size:9,weight:.semibold)).padding(.horizontal,6).padding(.vertical,2)
            .foregroundStyle(color).background(color.opacity(0.10),in:Capsule()).overlay(Capsule().stroke(color.opacity(0.45),lineWidth:0.7))
            .shadow(color:color.opacity(0.35),radius:3)
            .help(fit.summary+(fit.measured ? "" : " (estimate; run the fit test in Ask to measure)"))
    }
    var color:Color {
        switch fit.rating {
        case .strong: Constellation.starlight
        case .medium: Constellation.core
        case .weak: Constellation.warning
        case .unknown: Constellation.faint
        }
    }
}

extension Color {
    init(hex:String) {
        let value=Int(hex.dropFirst(),radix:16) ?? 0
        self.init(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255)
    }
}

/// The articles a library question found, most matches first. Each one opens the
/// article and highlights what was counted there.
struct LibraryHitList:View {
    let library:LibraryLine
    let conversation:CrawlerConversation
    let expanded:Bool
    let toggle:()->Void
    var body:some View {
        let shown=expanded ? library.hits : Array(library.hits.prefix(6))
        VStack(alignment:.leading,spacing:4) {
            ForEach(shown) {hit in
                Button {conversation.openLibraryHit(hit,query:library.query)} label: {
                    HStack(spacing:8) {
                        ThreadNode(kind:.star,size:5)
                        Text(hit.title).lineLimit(1)
                        Spacer(minLength:8)
                        Text(hit.count.formatted()).font(.system(size:11,design:.monospaced)).foregroundStyle(Constellation.dim)
                        Image(systemName:"arrow.up.right").font(.system(size:9,weight:.semibold)).foregroundStyle(Constellation.core)
                    }
                    .font(.system(size:12)).foregroundStyle(.white.opacity(0.86))
                    .padding(.vertical,5).padding(.horizontal,9)
                    .constellationCard(radius:7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hit.sample.map {"Open and highlight · “\($0)”"} ?? "Open and highlight the matches")
            }
            HStack(spacing:14) {
                if library.hits.count>6 {Button(expanded ? "Show fewer" : "Show all \(library.hits.count)",action:toggle)}
                if library.matchingArticles>library.hits.count {
                    Text("top \(library.hits.count) of \(library.matchingArticles.formatted())").foregroundStyle(Constellation.faint)
                }
                Button("Copy list") {
                    let text=library.hits.map {"\($0.title)\t\($0.count)"}.joined(separator:"\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text,forType:.string)
                }.help("Copy the titles and counts, one per line")
            }
            .font(.system(size:10)).buttonStyle(.plain).foregroundStyle(Constellation.core)
        }
        .padding(.top,2)
    }
}
