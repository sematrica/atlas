import AppKit
import QuartzCore
import WebKit
import AtlasCore

/// A transparent, non-interactive native overlay. Rendering has no DOM access or navigation decisions.
@MainActor
final class CrawlerRenderer:NSView {
    let crawler:CrawlerController
    private var link:CADisplayLink?
    private var last:CFTimeInterval=0
    private var visualPosition:DocumentPosition?
    private(set) var renderedFrames=0
    override var isFlipped:Bool {true}
    override var isOpaque:Bool {false}
    init(crawler:CrawlerController) {self.crawler=crawler;super.init(frame:.zero);crawler.renderer=self;setAccessibilityElement(false)}
    required init?(coder:NSCoder) {nil}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {stopAnimation()}else if crawler.active {startAnimation()}
    }
    func startAnimation() {
        guard link == nil,window != nil else {return}
        last=0;visualPosition=crawler.agent.state.position
        link=displayLink(target:self,selector:#selector(frameTick(_:)));link?.add(to:.main,forMode:.common)
    }
    func stopAnimation() {link?.invalidate();link=nil;visualPosition=crawler.agent.state.position;needsDisplay=true}
    @objc private func frameTick(_ display:CADisplayLink) {
        // A resumed display link can report a large gap. Advance one bounded frame so the
        // spider does not leap across the article when the window wakes or the Mac stalls.
        let dt=min(0.05,max(1.0/240,last == 0 ? 1.0/60 : display.timestamp-last))
        last=display.timestamp
        crawler.tick(dt:dt)
        updateVisualPosition(dt:dt)
        needsDisplay=true
    }
    private func updateVisualPosition(dt:Double) {
        let target=crawler.agent.state.position
        guard !crawler.reduceMotion,let current=visualPosition,current.distance(to:target)<80 else {
            visualPosition=target;return
        }
        // A short, bounded follow lets the body glide through steering changes while the feet
        // stay planted on their document anchors and the body stays close to its true position.
        let blend=1-exp(-dt/0.05)
        var x=current.x+(target.x-current.x)*blend
        var y=current.y+(target.y-current.y)*blend
        let dx=target.x-x,dy=target.y-y,gap=hypot(dx,dy)
        if gap>10 {x=target.x-dx/gap*10;y=target.y-dy/gap*10}
        visualPosition=DocumentPosition(x:x,y:y)
    }
    /// Knees come from the leg controller's inverse kinematics; a swinging leg lifts its knee.
    private func animatedKnee(_ i:Int,body:DocumentPosition)->DocumentPosition {
        crawler.legs.knee(i,body:body)
    }
    override func draw(_ dirtyRect:NSRect) {
        guard crawler.active,let context=NSGraphicsContext.current?.cgContext else {return}
        renderedFrames += 1
        let viewport=crawler.viewport,sx=bounds.width/max(1,viewport.width),sy=bounds.height/max(1,viewport.height)
        context.saveGState();defer {context.restoreGState()}
        context.scaleBy(x:sx,y:sy);context.translateBy(x:-viewport.x,y:-viewport.y)
        let state=crawler.agent.state,p=visualPosition ?? state.position
        if crawler.debug {
            context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.55).cgColor);context.setLineWidth(0.7)
            context.strokeEllipse(in:CGRect(x:p.x-crawler.radius,y:p.y-crawler.radius,width:crawler.radius*2,height:crawler.radius*2))
            for item in crawler.agent.observation?.terrain ?? [] {
                let r=item.rect;context.stroke(CGRect(x:r.x,y:r.y,width:r.width,height:r.height))
            }
            context.setFillColor(NSColor.systemTeal.withAlphaComponent(0.6).cgColor)
            for anchor in crawler.anchors {context.fillEllipse(in:CGRect(x:anchor.position.x-1.5,y:anchor.position.y-1.5,width:3,height:3))}
            for point in crawler.agent.memory.recentPositions {context.fillEllipse(in:CGRect(x:point.x-2,y:point.y-2,width:4,height:4))}
            context.move(to:CGPoint(x:p.x,y:p.y));context.addLine(to:CGPoint(x:state.desired.x,y:state.desired.y));context.strokePath()
        }
        drawTouches(context)
        switch crawler.look {
        case .sematrica: drawSematricaCreature(context,at:p,state:state)
        case .constellation: drawConstellationCreature(context,at:p,state:state)
        case .neon: drawNeonCreature(context,at:p,state:state)
        case .mechanical: drawAmberCreature(context,at:p,state:state)
        }
    }
    /// The original amber mechanical creature.
    private func drawAmberCreature(_ context:CGContext,at p:DocumentPosition,state:CrawlerState) {
        context.saveGState();defer {context.restoreGState()}
        // A restrained amber aura connects the page hand to its companion panel.
        let glow=NSColor(calibratedRed:0.88,green:0.73,blue:0.44,alpha:1)
        context.saveGState()
        context.setShadow(offset:.zero,blur:14,color:glow.withAlphaComponent(0.28).cgColor)
        context.setFillColor(glow.withAlphaComponent(0.07).cgColor)
        context.fillEllipse(in:CGRect(x:p.x-18,y:p.y-18,width:36,height:36))
        context.restoreGState()
        let spawn=min(1,state.elapsed/0.65)
        context.setAlpha(spawn)
        let color=state.behavior == .found ? NSColor(calibratedRed:0.12,green:0.50,blue:0.38,alpha:1) : NSColor(calibratedRed:0.12,green:0.16,blue:0.18,alpha:1)
        // A pale narrow halo keeps the creature legible over images and dark article regions.
        for halo in [true,false] {
            context.setStrokeColor((halo ? NSColor.white.withAlphaComponent(0.8) : color).cgColor)
            context.setLineWidth(halo ? 3.3 : 1.65);context.setLineCap(.round);context.setLineJoin(.miter)
            for i in crawler.legs.legs.indices {
                let a=crawler.legs.attachment(i,body:p),k=animatedKnee(i,body:p),foot=crawler.legs.drawnFoot(i,body:p)
                context.move(to:CGPoint(x:a.x,y:a.y))
                context.addLine(to:CGPoint(x:p.x+(k.x-p.x)*spawn,y:p.y+(k.y-p.y)*spawn))
                context.addLine(to:CGPoint(x:p.x+(foot.x-p.x)*spawn,y:p.y+(foot.y-p.y)*spawn));context.strokePath()
                if crawler.debug,let _=crawler.legs.legs[i].anchorID {
                    context.setFillColor(NSColor.systemPink.cgColor);context.fillEllipse(in:CGRect(x:foot.x-2,y:foot.y-2,width:4,height:4))
                }
            }
        }
        // Exposed pivot bearings and short actuator rods make each limb read as a mechanism.
        let accent=state.behavior == .found ? NSColor.systemGreen : NSColor(calibratedRed:0.91,green:0.76,blue:0.47,alpha:1)
        for i in crawler.legs.legs.indices {
            let a=crawler.legs.attachment(i,body:p),raw=animatedKnee(i,body:p)
            let k=DocumentPosition(x:p.x+(raw.x-p.x)*spawn,y:p.y+(raw.y-p.y)*spawn)
            context.setStrokeColor(NSColor(calibratedWhite:0.65,alpha:1).cgColor);context.setLineWidth(0.7)
            context.move(to:CGPoint(x:a.x,y:a.y));context.addLine(to:CGPoint(x:a.x+(k.x-a.x)*0.65,y:a.y+(k.y-a.y)*0.65));context.strokePath()
            context.setFillColor(color.cgColor);context.setStrokeColor(NSColor(calibratedWhite:0.85,alpha:1).cgColor)
            context.fillEllipse(in:CGRect(x:k.x-2,y:k.y-2,width:4,height:4))
            context.strokeEllipse(in:CGRect(x:k.x-2,y:k.y-2,width:4,height:4))
            // A lifted foot is drawn slightly smaller, as if farther from the page.
            let foot=crawler.legs.drawnFoot(i,body:p),size=3.2-crawler.legs.legs[i].lift*1.2
            context.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            context.fillEllipse(in:CGRect(x:foot.x-size/2,y:foot.y-size/2,width:size,height:size))
        }
        let stepBalance=crawler.reduceMotion ? 0 : crawler.legs.legs.enumerated().reduce(0.0) { sum,entry in
            sum+entry.element.lift*(entry.offset<4 ? 1 : -1)
        }
        // The chassis rocks toward the planted side and bobs slightly with each step.
        let lifted=crawler.legs.legs.reduce(0.0) {$0+$1.lift}
        let bob=crawler.reduceMotion ? 1.0 : 1+0.025*lifted/4
        context.translateBy(x:p.x,y:p.y);context.rotate(by:crawler.legs.heading+stepBalance*0.02);context.scaleBy(x:bob,y:bob)
        context.setFillColor(color.cgColor);context.setStrokeColor(NSColor(calibratedWhite:0.85,alpha:1).cgColor);context.setLineWidth(0.9)
        context.move(to:CGPoint(x:-12,y:-3));context.addLine(to:CGPoint(x:-7,y:-7))
        context.addLine(to:CGPoint(x:5,y:-6));context.addLine(to:CGPoint(x:11,y:-3))
        context.addLine(to:CGPoint(x:11,y:3));context.addLine(to:CGPoint(x:5,y:6))
        context.addLine(to:CGPoint(x:-7,y:7));context.addLine(to:CGPoint(x:-12,y:3));context.closePath();context.drawPath(using:.fillStroke)
        context.setStrokeColor(accent.withAlphaComponent(0.8).cgColor);context.setLineWidth(0.65)
        context.stroke(CGRect(x:-6,y:-3,width:9,height:6))
        context.setFillColor(accent.withAlphaComponent(crawler.conversation.busy ? 0.85 : 0.35).cgColor)
        context.fillEllipse(in:CGRect(x:-4,y:-2,width:4,height:4))
        context.move(to:CGPoint(x:-10,y:0));context.addLine(to:CGPoint(x:-6,y:0));context.strokePath()
        context.setFillColor(accent.cgColor)
        for y in [-2.5,2.5] {context.fillEllipse(in:CGRect(x:6,y:y-1,width:2.5,height:2))}
    }

    static let neonCyan=NSColor(calibratedRed:0.25,green:0.93,blue:1,alpha:1)
    static let neonBlue=NSColor(calibratedRed:0.40,green:0.50,blue:1,alpha:1)
    static let neonPink=NSColor(calibratedRed:1,green:0.25,blue:0.44,alpha:1)

    static let ink=NSColor(calibratedRed:0.024,green:0.031,blue:0.055,alpha:1)
    static let starlight=NSColor.white
    static let coreOrange=NSColor(calibratedRed:1,green:0.59,blue:0.16,alpha:1)
    static let amber=NSColor(calibratedRed:0.88,green:0.73,blue:0.44,alpha:1)
    static let champagne=NSColor(calibratedRed:1,green:0.94,blue:0.84,alpha:1)
    static let coreHot=NSColor(calibratedRed:1,green:0.96,blue:0.86,alpha:1)
    static let steel=NSColor(calibratedRed:0.45,green:0.55,blue:0.62,alpha:1)

    /// Glowing boxes around the words the feet touch, fading after the foot lifts, in the look's colors.
    private func drawTouches(_ context:CGContext) {
        guard crawler.touchGlow,!crawler.touchMarks.isEmpty else {return}
        let now=ProcessInfo.processInfo.systemUptime
        for mark in crawler.touchMarks.values {
            let alpha=CrawlerController.touchAlpha(now-mark.time)
            guard alpha>0.01 else {continue}
            let (color,fill)=Self.touchColors(mark.style,look:crawler.look)
            let box=CGRect(x:mark.rect.x-3,y:mark.rect.y-1.5,width:mark.rect.width+6,height:mark.rect.height+3)
            // White light needs a dark edge to show on a white page.
            if crawler.look.drawnInLight,mark.style != .pinkFill {
                context.saveGState()
                context.setShadow(offset:.zero,blur:4,color:Self.ink.withAlphaComponent(0.55*alpha).cgColor)
                context.setStrokeColor(Self.ink.withAlphaComponent(0.35*alpha).cgColor);context.setLineWidth(2.2);context.stroke(box)
                context.restoreGState()
            }
            context.saveGState()
            if fill>0 {context.setFillColor(color.withAlphaComponent(fill*alpha).cgColor);context.fill(box)}
            context.setShadow(offset:.zero,blur:(crawler.look.drawnInLight ? 7 : 9)*alpha,color:color.withAlphaComponent(0.85*alpha).cgColor)
            context.setStrokeColor(color.withAlphaComponent(0.95*alpha).cgColor);context.setLineWidth(crawler.look.drawnInLight ? 1.1 : 1.6)
            context.stroke(box)
            context.restoreGState()
        }
    }
    /// The outline color of a touch box and how strongly it is filled (0 for an outline only).
    static func touchColors(_ style:TouchMark.Style,look:CreatureLook)->(NSColor,Double) {
        switch look {
        case .sematrica,.constellation:
            switch style {
            case .cyanOutline: return (starlight,0)
            case .blueOutline: return (starlight,0)
            case .pinkFill: return (coreOrange,0.3)
            case .blueFill,.cyanFill: return (starlight,0.28)
            }
        case .neon:
            switch style {
            case .cyanOutline: return (neonCyan,0)
            case .blueOutline: return (neonBlue,0)
            case .pinkFill: return (neonPink,0.34)
            case .blueFill: return (neonBlue,0.34)
            case .cyanFill: return (neonCyan,0.34)
            }
        case .mechanical:
            switch style {
            case .cyanOutline: return (amber,0)
            case .blueOutline: return (steel,0)
            case .pinkFill,.cyanFill: return (amber,0.3)
            case .blueFill: return (steel,0.3)
            }
        }
    }

    /// A constellation in a dark crystal: a spine of glass spheres with an orange core, a haloed
    /// head and a slanting beam of light, after a sacred-geometry figure; slim, on long legs. The legs leave from the
    /// lattice's side nodes. The crystal carries its own night sky, so the white light shows on white pages.
    private func drawConstellationCreature(_ context:CGContext,at p:DocumentPosition,state:CrawlerState) {
        let spawn=min(1,state.elapsed/0.65)
        let stepBalance=crawler.reduceMotion ? 0 : crawler.legs.legs.enumerated().reduce(0.0) {sum,entry in sum+entry.element.lift*(entry.offset<4 ? 1 : -1)}
        let angle=crawler.legs.heading+stepBalance*0.02,c=cos(angle),s=sin(angle)
        // Body-local coordinates: x points forward, y to the right; the figure is drawn slim and long.
        func at(_ x:Double,_ y:Double)->CGPoint {
            let x=x*1.15
            return CGPoint(x:p.x+c*x-s*y,y:p.y+s*x+c*y)
        }
        func pair(_ x:Double,_ y:Double)->[CGPoint] {[at(x,-y),at(x,y)]}
        let head=at(21.8,0),neck=at(17.4,0),upper=at(9.4,0),hub=at(0,0),lower=at(-7.1,0),core=at(-15.6,0)
        let waist=at(-19.7,0),tail=at(-28.7,0),tailDots=[(at(-37.3,0),1.1),(at(-40.6,0),1.3),(at(-42.5,0),0.6)]
        let shoulders=pair(11.8,5.4),arms=pair(4.05,5.4),wings=pair(-2.1,8.4),hips=pair(-9.5,5.4),flanks=pair(-22.5,5.4)
        let mounts=[shoulders,arms,wings,hips]
        let found=state.behavior == .found
        let ink=Self.ink,light=Self.starlight
        func point(_ d:DocumentPosition)->CGPoint {
            CGPoint(x:p.x+(d.x-p.x)*spawn,y:p.y+(d.y-p.y)*spawn)
        }
        func lines(_ segments:[(CGPoint,CGPoint,Double,Double)],underlay:Bool,glow:Bool=true) {
            context.saveGState();context.setLineCap(.round)
            if underlay {
                context.setShadow(offset:.zero,blur:2.5,color:ink.withAlphaComponent(0.55).cgColor)
                for (a,b,alpha,width) in segments {
                    context.setStrokeColor(ink.withAlphaComponent(0.3*alpha).cgColor);context.setLineWidth(width+1.3)
                    context.move(to:a);context.addLine(to:b);context.strokePath()
                }
            } else {
                if glow {context.setShadow(offset:.zero,blur:3,color:light.withAlphaComponent(0.85).cgColor)}
                for (a,b,alpha,width) in segments {
                    context.setStrokeColor(light.withAlphaComponent(min(1,alpha)).cgColor);context.setLineWidth(width)
                    context.move(to:a);context.addLine(to:b);context.strokePath()
                }
            }
            context.restoreGState()
        }
        func dot(_ q:CGPoint,_ r:Double,alpha:Double=1) {
            context.saveGState()
            context.setShadow(offset:.zero,blur:2.5,color:ink.withAlphaComponent(0.6).cgColor)
            context.setFillColor(ink.withAlphaComponent(0.4).cgColor)
            context.fillEllipse(in:CGRect(x:q.x-r-0.7,y:q.y-r-0.7,width:(r+0.7)*2,height:(r+0.7)*2))
            context.setShadow(offset:.zero,blur:4,color:light.withAlphaComponent(0.95).cgColor)
            context.setFillColor(light.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in:CGRect(x:q.x-r,y:q.y-r,width:r*2,height:r*2))
            context.restoreGState()
        }
        func sparkle(_ q:CGPoint,_ length:Double) {
            context.saveGState()
            context.setShadow(offset:.zero,blur:3,color:light.cgColor)
            context.setStrokeColor(light.withAlphaComponent(0.95).cgColor);context.setLineWidth(0.5)
            context.move(to:CGPoint(x:q.x-length,y:q.y));context.addLine(to:CGPoint(x:q.x+length,y:q.y))
            context.move(to:CGPoint(x:q.x,y:q.y-length));context.addLine(to:CGPoint(x:q.x,y:q.y+length));context.strokePath()
            context.restoreGState()
        }
        func radial(_ q:CGPoint,_ r:Double,_ colors:[NSColor],_ locations:[CGFloat]) {
            guard let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors.map(\.cgColor) as CFArray,locations:locations) else {return}
            context.drawRadialGradient(gradient,startCenter:q,startRadius:0,endCenter:q,endRadius:r,options:[])
        }
        func sphere(_ q:CGPoint,_ r:Double) {
            let disc=CGRect(x:q.x-r,y:q.y-r,width:r*2,height:r*2)
            context.saveGState()
            context.setShadow(offset:.zero,blur:5,color:light.withAlphaComponent(0.7).cgColor)
            context.setFillColor(light.withAlphaComponent(0.28).cgColor);context.fillEllipse(in:disc)
            context.restoreGState()
            radial(q,r,[light.withAlphaComponent(0.6),light.withAlphaComponent(0.16),light.withAlphaComponent(0.02)],[0,0.35,1])
            context.setStrokeColor(light.withAlphaComponent(0.7).cgColor);context.setLineWidth(0.45);context.strokeEllipse(in:disc)
            sparkle(q,r*0.5)
        }
        func polygon(_ points:[CGPoint]) {
            guard let first=points.first else {return}
            context.move(to:first);for q in points.dropFirst() {context.addLine(to:q)};context.closePath()
        }

        context.saveGState();defer {context.restoreGState()}
        context.setAlpha(spawn)
        // 1. Legs, beneath the crystal: from a side node to the knee to the foot.
        var legLines:[(CGPoint,CGPoint,Double,Double)]=[]
        for i in crawler.legs.legs.indices {
            let mount=mounts[i%4][i<4 ? 0 : 1],knee=point(crawler.legs.knee(i,body:p)),foot=point(crawler.legs.drawnFoot(i,body:p))
            legLines.append((mount,knee,0.7,0.62));legLines.append((knee,foot,0.7,0.62))
        }
        lines(legLines,underlay:true);lines(legLines,underlay:false)
        // 2. The crystal: the figure's night sky, with a faint glass rim.
        let hull=[at(29,0),at(13.5,-7.6),at(-2.1,-11.4),at(-24,-7.6),at(-34.5,0),at(-24,7.6),at(-2.1,11.4),at(13.5,7.6)]
        context.saveGState()
        context.setShadow(offset:.zero,blur:8,color:ink.withAlphaComponent(0.55).cgColor)
        context.setFillColor(ink.withAlphaComponent(0.74).cgColor);polygon(hull);context.fillPath()
        context.restoreGState()
        context.setStrokeColor(light.withAlphaComponent(0.22).cgColor);context.setLineWidth(0.5);context.setLineJoin(.round)
        polygon(hull);context.strokePath()
        // 3. Translucent facets, then the lattice.
        var facets:[([CGPoint],Double)]=[([neck,shoulders[0],shoulders[1]],0.07),([shoulders[0],shoulders[1],hub],0.13),([hips[0],hips[1],tail],0.08),([hub,hips[0],hips[1]],0.05)]
        for k in 0..<2 {facets+=[([shoulders[k],arms[k],hub],0.06),([arms[k],wings[k],hub],0.09),([wings[k],hips[k],hub],0.06)]}
        for (points,alpha) in facets {context.setFillColor(light.withAlphaComponent(alpha).cgColor);polygon(points);context.fillPath()}
        var lattice:[(CGPoint,CGPoint,Double,Double)]=[(head,tailDots[2].0,0.72,0.72)]
        for k in 0..<2 {
            lattice+=[(neck,shoulders[k],0.96,0.66),(shoulders[k],arms[k],0.96,0.66),(shoulders[k],hub,0.72,0.6),(arms[k],hub,0.84,0.6),(arms[k],wings[k],0.96,0.66),
                      (wings[k],hub,0.84,0.6),(hub,hips[k],0.6,0.54),(wings[k],hips[k],0.96,0.66),(hips[k],flanks[k],0.96,0.66),(hips[k],core,0.66,0.54),
                      (flanks[k],core,0.6,0.54),(flanks[k],tail,0.9,0.66)]
        }
        lines(lattice,underlay:false)
        // 4. The beam: from the left wing through the tail sphere and on, fading at both ends.
        do {
            let from=wings[0],dx=tail.x-from.x,dy=tail.y-from.y,length=max(0.001,hypot(dx,dy)),ux=dx/length,uy=dy/length
            let start=CGPoint(x:from.x-ux*6.6,y:from.y-uy*6.6),span=length+6.6+50.6
            context.saveGState()
            context.setShadow(offset:.zero,blur:6,color:NSColor(calibratedRed:1,green:0.78,blue:0.55,alpha:1).cgColor)
            context.setLineCap(.butt);context.setLineWidth(1.2)
            let pieces=24
            for n in 0..<pieces {
                let t0=Double(n)/Double(pieces),t1=Double(n+1)/Double(pieces),t=(t0+t1)/2
                let alpha=t<0.12 ? 0.2+0.8*t/0.12 : t<0.55 ? 1 : max(0,1-(t-0.55)/0.45)
                context.setStrokeColor(light.withAlphaComponent(alpha).cgColor)
                context.move(to:CGPoint(x:start.x+ux*span*t0,y:start.y+uy*span*t0))
                context.addLine(to:CGPoint(x:start.x+ux*span*t1,y:start.y+uy*span*t1));context.strokePath()
            }
            context.restoreGState()
        }
        // 5. Nodes, glass spheres, the haloed head and the orange core.
        for k in 0..<2 {for q in [shoulders[k],arms[k],wings[k],hips[k],flanks[k]] {dot(q,1.15)}}
        dot(neck,1.25);dot(hub,1.7);dot(waist,1.1)
        for (q,r) in tailDots {dot(q,r)}
        sphere(upper,3.0);sphere(lower,3.1);sphere(tail,3.2)
        context.saveGState()
        context.setShadow(offset:.zero,blur:3,color:light.withAlphaComponent(0.9).cgColor)
        context.setStrokeColor(light.withAlphaComponent(crawler.conversation.busy ? 1 : 0.8).cgColor);context.setLineWidth(crawler.conversation.busy ? 0.8 : 0.5)
        context.strokeEllipse(in:CGRect(x:head.x-4.6,y:head.y-4.6,width:9.2,height:9.2))
        context.restoreGState()
        dot(head,1.9)
        let glow=found ? NSColor.systemGreen : Self.coreOrange,r=3.9
        context.saveGState()
        context.setShadow(offset:.zero,blur:14,color:glow.withAlphaComponent(0.95).cgColor)
        context.setFillColor(glow.cgColor)
        let disc=CGRect(x:core.x-r,y:core.y-r,width:r*2,height:r*2)
        context.fillEllipse(in:disc);context.fillEllipse(in:disc)
        context.restoreGState()
        radial(core,r,found ? [NSColor(calibratedRed:0.9,green:1,blue:0.9,alpha:1),NSColor.systemGreen,NSColor.systemGreen.withAlphaComponent(0.9)]
                            : [NSColor(calibratedRed:1,green:0.96,blue:0.86,alpha:1),NSColor(calibratedRed:1,green:0.75,blue:0.31,alpha:1),NSColor(calibratedRed:1,green:0.55,blue:0.08,alpha:1),NSColor(calibratedRed:0.94,green:0.43,blue:0,alpha:0.95)],
               found ? [0,0.5,1] : [0,0.3,0.75,1])
        sparkle(core,2.4)
        // 6. Knees and feet; a planted foot wears a faint ring.
        for i in crawler.legs.legs.indices {
            let leg=crawler.legs.legs[i],knee=point(crawler.legs.knee(i,body:p)),foot=point(crawler.legs.drawnFoot(i,body:p))
            dot(knee,0.8,alpha:0.8)
            let planted=leg.lift<0.05
            dot(foot,planted ? 1.3 : 0.9)
            if planted {
                context.saveGState()
                context.setShadow(offset:.zero,blur:2,color:light.withAlphaComponent(0.8).cgColor)
                context.setStrokeColor(light.withAlphaComponent(0.6).cgColor);context.setLineWidth(0.45)
                context.strokeEllipse(in:CGRect(x:foot.x-3.3,y:foot.y-3.3,width:6.6,height:6.6))
                context.restoreGState()
            }
        }
    }

    /// The creature from the app icon: legs of glass tubing on glowing knee joints, ringed feet
    /// standing in pools of warm light, a faceted crystal body with glass spheres and an orange
    /// core, a haloed head with a flare, a beaded tail and a long spike of light. It casts a soft
    /// shadow, so it seems to stand above the page, and the crystal carries its own night sky so
    /// the white light shows on white pages.
    private func drawSematricaCreature(_ context:CGContext,at p:DocumentPosition,state:CrawlerState) {
        let spawn=min(1,state.elapsed/0.65)
        let stepBalance=crawler.reduceMotion ? 0 : crawler.legs.legs.enumerated().reduce(0.0) {sum,entry in sum+entry.element.lift*(entry.offset<4 ? 1 : -1)}
        let angle=crawler.legs.heading+stepBalance*0.02,c=cos(angle),s=sin(angle)
        let busy=crawler.conversation.busy
        let pulse=busy && !crawler.reduceMotion ? 0.5+0.5*sin(ProcessInfo.processInfo.systemUptime*3.2) : 0
        let found=state.behavior == .found
        let ink=Self.ink,light=Self.starlight,glass=Self.champagne
        // Body-local coordinates: x points forward, y to the right.
        func at(_ x:Double,_ y:Double)->CGPoint {CGPoint(x:p.x+c*x-s*y,y:p.y+s*x+c*y)}
        func pair(_ x:Double,_ y:Double)->[CGPoint] {[at(x,-y),at(x,y)]}
        func point(_ d:DocumentPosition)->CGPoint {CGPoint(x:p.x+(d.x-p.x)*spawn,y:p.y+(d.y-p.y)*spawn)}
        func shifted(_ q:CGPoint,_ dx:Double,_ dy:Double)->CGPoint {CGPoint(x:q.x+dx,y:q.y+dy)}
        func polygon(_ points:[CGPoint]) {
            guard let first=points.first else {return}
            context.move(to:first);for q in points.dropFirst() {context.addLine(to:q)};context.closePath()
        }
        func radial(_ q:CGPoint,_ r:Double,_ colors:[NSColor],_ locations:[CGFloat]) {
            guard let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors.map(\.cgColor) as CFArray,locations:locations) else {return}
            context.drawRadialGradient(gradient,startCenter:q,startRadius:0,endCenter:q,endRadius:r,options:[])
        }
        // Shadows are the costly part of drawing, so segments and dots are batched into a few paths.
        func lines(_ segments:[(CGPoint,CGPoint,Double,Double)]) {
            context.saveGState();context.setLineCap(.round)
            context.setShadow(offset:.zero,blur:3,color:light.withAlphaComponent(0.85).cgColor)
            var styles:[(Double,Double)]=[]
            for (_,_,alpha,width) in segments where !styles.contains(where:{$0 == (alpha,width)}) {styles.append((alpha,width))}
            for (alpha,width) in styles {
                for (a,b,_,_) in segments.filter({$0.2 == alpha && $0.3 == width}) {context.move(to:a);context.addLine(to:b)}
                context.setStrokeColor(light.withAlphaComponent(alpha).cgColor);context.setLineWidth(width);context.strokePath()
            }
            context.restoreGState()
        }
        /// Bright points with a dark rim, so they show on white pages as well as dark ones.
        func dots(_ items:[(CGPoint,Double)]) {
            context.saveGState()
            context.setShadow(offset:.zero,blur:2.5,color:ink.withAlphaComponent(0.6).cgColor)
            for (q,r) in items {context.addEllipse(in:CGRect(x:q.x-r-0.7,y:q.y-r-0.7,width:(r+0.7)*2,height:(r+0.7)*2))}
            context.setFillColor(ink.withAlphaComponent(0.4).cgColor);context.fillPath()
            context.setShadow(offset:.zero,blur:4,color:light.withAlphaComponent(0.95).cgColor)
            for (q,r) in items {context.addEllipse(in:CGRect(x:q.x-r,y:q.y-r,width:r*2,height:r*2))}
            context.setFillColor(light.cgColor);context.fillPath()
            context.restoreGState()
        }
        func flare(_ q:CGPoint,_ length:Double,alpha:Double=0.9) {
            context.saveGState()
            context.setShadow(offset:.zero,blur:3,color:light.cgColor)
            context.setStrokeColor(light.withAlphaComponent(alpha).cgColor);context.setLineWidth(0.45);context.setLineCap(.round)
            for (dx,dy,scale) in [(1.0,0.0,1.0),(0.0,1.0,1.0),(0.707,0.707,0.45),(0.707,-0.707,0.45)] {
                context.move(to:CGPoint(x:q.x-dx*length*scale,y:q.y-dy*length*scale));context.addLine(to:CGPoint(x:q.x+dx*length*scale,y:q.y+dy*length*scale))
            }
            context.strokePath()
            context.restoreGState()
        }
        func sphere(_ q:CGPoint,_ r:Double) {
            let disc=CGRect(x:q.x-r,y:q.y-r,width:r*2,height:r*2)
            context.saveGState()
            context.setShadow(offset:.zero,blur:6,color:light.withAlphaComponent(0.75).cgColor)
            context.setFillColor(light.withAlphaComponent(0.26).cgColor);context.fillEllipse(in:disc)
            context.restoreGState()
            context.saveGState()
            context.addEllipse(in:disc);context.clip()
            radial(CGPoint(x:q.x-r*0.25,y:q.y-r*0.25),r,[light.withAlphaComponent(0.75),light.withAlphaComponent(0.22),light.withAlphaComponent(0.04)],[0,0.4,1])
            context.restoreGState()
            context.setStrokeColor(light.withAlphaComponent(0.65).cgColor);context.setLineWidth(0.45);context.strokeEllipse(in:disc)
            flare(q,r*0.55,alpha:0.8)
        }
        /// Leg segments as glass tubing: a faint glassy fill between two bright edges, tapering from wa to wb.
        func tubes(_ segments:[(CGPoint,CGPoint,Double,Double)]) {
            func edges(_ a:CGPoint,_ b:CGPoint,_ wa:Double,_ wb:Double)->[CGPoint] {
                let dx=b.x-a.x,dy=b.y-a.y,length=max(0.001,hypot(dx,dy)),nx = -dy/length,ny=dx/length
                return [CGPoint(x:a.x+nx*wa,y:a.y+ny*wa),CGPoint(x:b.x+nx*wb,y:b.y+ny*wb),CGPoint(x:b.x-nx*wb,y:b.y-ny*wb),CGPoint(x:a.x-nx*wa,y:a.y-ny*wa)]
            }
            for (a,b,wa,wb) in segments {polygon(edges(a,b,wa,wb))}
            context.setFillColor(glass.withAlphaComponent(0.16).cgColor);context.fillPath()
            context.saveGState()
            context.setShadow(offset:.zero,blur:2.5,color:light.withAlphaComponent(0.8).cgColor)
            for (a,b,wa,wb) in segments {
                let q=edges(a,b,wa,wb)
                context.move(to:q[0]);context.addLine(to:q[1]);context.move(to:q[3]);context.addLine(to:q[2])
            }
            context.setStrokeColor(glass.withAlphaComponent(0.85).cgColor);context.setLineWidth(0.42);context.setLineCap(.round);context.strokePath()
            context.restoreGState()
        }

        // The crystal: side nodes in five rows, spheres along the spine, the core low in the body.
        let head=at(30,0),neck=at(24.5,0),tip=at(-27,0)
        let rows=[pair(18,5),pair(9,9),pair(-1,10.5),pair(-11,9),pair(-20,5.5)]
        let upper=at(15,0),hub=at(5,0),middle=at(-2.5,0),core=at(-11,0.8),lower=at(-20.5,0)
        let beads:[(CGPoint,Double)]=[(at(-31.5,0),1.5),(at(-35.5,0),1.7),(at(-39.5,0),1.5),(at(-43,0),1.1),(at(-46,0),0.7)]
        let hull=[at(27,0),at(18,-6.4),at(9,-10.6),at(-1,-12.2),at(-11,-10.6),at(-20,-6.9),at(-29.5,0),at(-20,6.9),at(-11,10.6),at(-1,12.2),at(9,10.6),at(18,6.4)]
        var legs:[(mount:CGPoint,knee:CGPoint,foot:CGPoint,lift:Double,row:Int)]=[]
        for i in crawler.legs.legs.indices {
            legs.append((rows[i%4][i<4 ? 0 : 1],point(crawler.legs.knee(i,body:p)),point(crawler.legs.drawnFoot(i,body:p)),crawler.legs.legs[i].lift,i%4))
        }

        context.saveGState();defer {context.restoreGState()}
        context.setAlpha(spawn)
        // 1. Its shadow on the page, offset away from the light: the knees stand highest.
        context.saveGState()
        context.setShadow(offset:.zero,blur:7,color:ink.withAlphaComponent(0.3).cgColor)
        context.setFillColor(ink.withAlphaComponent(0.1).cgColor);polygon(hull.map {shifted($0,4,6)});context.fillPath()
        context.setShadow(offset:.zero,blur:3,color:ink.withAlphaComponent(0.3).cgColor)
        context.setStrokeColor(ink.withAlphaComponent(0.12).cgColor);context.setLineWidth(1.5);context.setLineCap(.round);context.setLineJoin(.round)
        for leg in legs {
            let raise=1+leg.lift
            context.move(to:shifted(leg.mount,4,6));context.addLine(to:shifted(leg.knee,7*raise,10*raise));context.addLine(to:shifted(leg.foot,3*leg.lift,4*leg.lift))
        }
        context.strokePath()
        context.restoreGState()
        // 2. Pools of warm light under the planted feet.
        for leg in legs where leg.lift<0.6 {
            let strength=1-leg.lift/0.6
            radial(leg.foot,11,[NSColor(calibratedRed:1,green:0.84,blue:0.63,alpha:0.42*strength),Self.coreOrange.withAlphaComponent(0.16*strength),Self.coreOrange.withAlphaComponent(0)],[0,0.45,1])
        }
        // 3. Legs of glass tubing, with a dark edge for white pages and the core's light leaking into the upper legs.
        context.saveGState()
        context.setShadow(offset:.zero,blur:2.5,color:ink.withAlphaComponent(0.55).cgColor)
        context.setStrokeColor(ink.withAlphaComponent(0.26).cgColor);context.setLineWidth(3.6);context.setLineCap(.round);context.setLineJoin(.round)
        for leg in legs {context.move(to:leg.mount);context.addLine(to:leg.knee);context.addLine(to:leg.foot)}
        context.strokePath()
        context.restoreGState()
        tubes(legs.flatMap {[($0.mount,$0.knee,1.25,1.05),($0.knee,$0.foot,1.0,0.4)]})
        for warm in [0.32,0.6] {
            context.saveGState()
            context.setShadow(offset:.zero,blur:5,color:Self.coreOrange.withAlphaComponent(warm).cgColor)
            for leg in legs where (leg.row>=2) == (warm>0.5) {
                context.move(to:leg.mount);context.addLine(to:CGPoint(x:leg.mount.x+(leg.knee.x-leg.mount.x)*0.45,y:leg.mount.y+(leg.knee.y-leg.mount.y)*0.45))
            }
            context.setStrokeColor(Self.coreOrange.withAlphaComponent(warm).cgColor);context.setLineWidth(0.7);context.setLineCap(.round);context.strokePath()
            context.restoreGState()
        }
        // 4. The crystal's night sky with a glass rim, then translucent facets lit from the right.
        context.saveGState()
        context.setShadow(offset:.zero,blur:8,color:ink.withAlphaComponent(0.55).cgColor)
        context.setFillColor(ink.withAlphaComponent(0.72).cgColor);polygon(hull);context.fillPath()
        context.restoreGState()
        context.setStrokeColor(light.withAlphaComponent(0.2).cgColor);context.setLineWidth(0.5);context.setLineJoin(.round)
        polygon(hull);context.strokePath()
        let centers=[upper,hub,middle,core,lower]
        var facets:[([CGPoint],Double)]=[([neck,rows[0][0],rows[0][1]],0.08),([rows[4][0],rows[4][1],tip],0.06)]
        for r in 0..<4 {
            facets.append(([rows[r][0],rows[r+1][0],centers[r]],0.05))
            facets.append(([rows[r][1],rows[r+1][1],centers[r]],0.11))
        }
        for (points,alpha) in facets {context.setFillColor(light.withAlphaComponent(alpha).cgColor);polygon(points);context.fillPath()}
        // 5. The lattice: outline, struts to the spine, the far side's faint cross-bracing, and the spine.
        var lattice:[(CGPoint,CGPoint,Double,Double)]=[(head,neck,0.85,0.6),(neck,upper,0.6,0.5),(upper,hub,0.6,0.5),(hub,middle,0.6,0.5),(middle,core,0.55,0.5),(core,lower,0.55,0.5),(lower,tip,0.6,0.5)]
        for k in 0..<2 {
            lattice.append((neck,rows[0][k],0.95,0.62))
            for r in 0..<4 {lattice.append((rows[r][k],rows[r+1][k],0.95,0.62))}
            lattice.append((rows[4][k],tip,0.9,0.6))
            for r in 0..<4 {lattice.append((rows[r][k],centers[r],0.62,0.5));lattice.append((rows[r+1][k],centers[r],0.62,0.5))}
            lattice.append((rows[4][k],lower,0.62,0.5))
        }
        for r in [1,3] {lattice.append((rows[r][0],rows[r+1][1],0.28,0.4));lattice.append((rows[r][1],rows[r+1][0],0.28,0.4))}
        lines(lattice)
        // 6. The spike: a long blade of light from the core past the beaded tail, fading to a point.
        do {
            let base=at(-12,0),end=at(-80,8),dx=end.x-base.x,dy=end.y-base.y,length=max(0.001,hypot(dx,dy)),nx = -dy/length*1.9,ny=dx/length*1.9
            let blade=[CGPoint(x:base.x+nx,y:base.y+ny),end,CGPoint(x:base.x-nx,y:base.y-ny)]
            context.saveGState()
            context.setShadow(offset:.zero,blur:3,color:ink.withAlphaComponent(0.4).cgColor)
            context.setFillColor(ink.withAlphaComponent(0.18).cgColor);polygon(blade);context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.setShadow(offset:.zero,blur:8,color:Self.coreOrange.withAlphaComponent(0.9).cgColor)
            context.setFillColor(Self.coreOrange.withAlphaComponent(0.5).cgColor);polygon(blade);context.fillPath()
            context.restoreGState()
            context.saveGState()
            polygon(blade);context.clip()
            let colors=[Self.coreHot,Self.coreOrange.withAlphaComponent(0.9),Self.coreOrange.withAlphaComponent(0.4),Self.coreOrange.withAlphaComponent(0)]
            if let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors.map(\.cgColor) as CFArray,locations:[0,0.3,0.7,1]) {
                context.drawLinearGradient(gradient,start:base,end:end,options:[])
            }
            context.restoreGState()
            lines([(base,CGPoint(x:base.x+dx*0.5,y:base.y+dy*0.5),0.85,0.45)])
        }
        // 7. Nodes, beads, glass spheres, the haloed head and the orange core.
        dots(rows.flatMap {$0.map {($0,1.15)}}+[(neck,1.4),(hub,1.8),(tip,1.2)]+beads)
        sphere(upper,3.5);sphere(middle,3.0);sphere(lower,3.4)
        // The head: a dark disc of night sky behind its halo, so the halo shows on white pages.
        context.saveGState()
        context.setShadow(offset:.zero,blur:6,color:ink.withAlphaComponent(0.5).cgColor)
        context.setFillColor(ink.withAlphaComponent(0.62).cgColor);context.fillEllipse(in:CGRect(x:head.x-6.6,y:head.y-6.6,width:13.2,height:13.2))
        context.restoreGState()
        context.saveGState()
        context.setShadow(offset:.zero,blur:4,color:light.withAlphaComponent(0.9).cgColor)
        context.setStrokeColor(light.withAlphaComponent(busy ? 1 : 0.8).cgColor);context.setLineWidth(busy ? 0.8 : 0.6)
        context.strokeEllipse(in:CGRect(x:head.x-5.2,y:head.y-5.2,width:10.4,height:10.4))
        context.restoreGState()
        dots([(head,2.4)]);flare(head,busy ? 8 : 6.5)
        let glow=found ? NSColor.systemGreen : Self.coreOrange,r=5.0
        context.saveGState()
        context.setShadow(offset:.zero,blur:16+8*pulse,color:glow.withAlphaComponent(0.95).cgColor)
        context.setFillColor(glow.cgColor)
        let disc=CGRect(x:core.x-r,y:core.y-r,width:r*2,height:r*2)
        context.fillEllipse(in:disc);context.fillEllipse(in:disc)
        context.restoreGState()
        radial(core,r,found ? [NSColor(calibratedRed:0.9,green:1,blue:0.9,alpha:1),NSColor.systemGreen,NSColor.systemGreen.withAlphaComponent(0.9)]
                            : [Self.coreHot,NSColor(calibratedRed:1,green:0.75,blue:0.31,alpha:1),NSColor(calibratedRed:1,green:0.55,blue:0.08,alpha:1),NSColor(calibratedRed:0.94,green:0.43,blue:0,alpha:0.95)],
               found ? [0,0.5,1] : [0,0.3,0.75,1])
        flare(core,3.6)
        // 8. Knees as glowing glass joints; feet as bright points, ringed while planted.
        context.saveGState()
        context.setShadow(offset:.zero,blur:6,color:light.withAlphaComponent(0.9).cgColor)
        for leg in legs {context.addEllipse(in:CGRect(x:leg.knee.x-3,y:leg.knee.y-3,width:6,height:6))}
        context.setFillColor(ink.withAlphaComponent(0.35).cgColor);context.fillPath()
        context.restoreGState()
        for leg in legs {
            context.saveGState()
            context.addEllipse(in:CGRect(x:leg.knee.x-2.3,y:leg.knee.y-2.3,width:4.6,height:4.6));context.clip()
            radial(CGPoint(x:leg.knee.x-0.5,y:leg.knee.y-0.5),2.3,[light,light.withAlphaComponent(0.95),NSColor(calibratedWhite:0.82,alpha:0.95)],[0,0.5,1])
            context.restoreGState()
        }
        dots(legs.map {($0.foot,$0.lift<0.05 ? 1.6 : 1.1)})
        context.saveGState()
        context.setShadow(offset:.zero,blur:2.5,color:light.withAlphaComponent(0.85).cgColor)
        for leg in legs where leg.lift<0.05 {context.addEllipse(in:CGRect(x:leg.foot.x-4.2,y:leg.foot.y-4.2,width:8.4,height:8.4))}
        context.setStrokeColor(glass.withAlphaComponent(0.7).cgColor);context.setLineWidth(0.5);context.strokePath()
        context.restoreGState()
    }

    /// A neon, debug-style creature: cyan limbs, pink joints and feet, a boxy body with a glowing eye.
    private func drawNeonCreature(_ context:CGContext,at p:DocumentPosition,state:CrawlerState) {
        let spawn=min(1,state.elapsed/0.65)
        let found=state.behavior == .found
        let limb=found ? NSColor.systemGreen : Self.neonCyan
        let joint=found ? NSColor.systemGreen : Self.neonPink
        context.saveGState()
        context.setAlpha(spawn)
        // Limbs with a soft glow.
        context.setShadow(offset:.zero,blur:5,color:limb.withAlphaComponent(0.7).cgColor)
        context.setStrokeColor(limb.withAlphaComponent(0.95).cgColor);context.setLineWidth(1.5);context.setLineCap(.round);context.setLineJoin(.round)
        for i in crawler.legs.legs.indices {
            let a=crawler.legs.attachment(i,body:p),k=animatedKnee(i,body:p),foot=crawler.legs.drawnFoot(i,body:p)
            context.move(to:CGPoint(x:a.x,y:a.y))
            context.addLine(to:CGPoint(x:p.x+(k.x-p.x)*spawn,y:p.y+(k.y-p.y)*spawn))
            context.addLine(to:CGPoint(x:p.x+(foot.x-p.x)*spawn,y:p.y+(foot.y-p.y)*spawn))
        }
        context.strokePath()
        // Pink joints and feet; a lifted foot is drawn smaller.
        context.setShadow(offset:.zero,blur:4,color:joint.withAlphaComponent(0.8).cgColor)
        context.setFillColor(joint.cgColor)
        for i in crawler.legs.legs.indices {
            let raw=animatedKnee(i,body:p),k=DocumentPosition(x:p.x+(raw.x-p.x)*spawn,y:p.y+(raw.y-p.y)*spawn)
            context.fillEllipse(in:CGRect(x:k.x-2,y:k.y-2,width:4,height:4))
            let foot=crawler.legs.drawnFoot(i,body:p),size=4.2-crawler.legs.legs[i].lift*1.6
            context.fillEllipse(in:CGRect(x:foot.x-size/2,y:foot.y-size/2,width:size,height:size))
        }
        context.restoreGState()
        // The body: a dark box outlined in cyan, rocking slightly with each step, with a glowing eye at the front.
        let stepBalance=crawler.reduceMotion ? 0 : crawler.legs.legs.enumerated().reduce(0.0) {sum,entry in sum+entry.element.lift*(entry.offset<4 ? 1 : -1)}
        context.saveGState()
        context.setAlpha(spawn)
        context.translateBy(x:p.x,y:p.y);context.rotate(by:crawler.legs.heading+stepBalance*0.02)
        let body=CGRect(x:-13,y:-4,width:26,height:8)
        context.setFillColor(NSColor(calibratedRed:0.03,green:0.05,blue:0.08,alpha:0.92).cgColor);context.fill(body)
        context.setShadow(offset:.zero,blur:6,color:limb.withAlphaComponent(0.8).cgColor)
        context.setStrokeColor(limb.cgColor);context.setLineWidth(1.5);context.stroke(body)
        context.setFillColor(limb.withAlphaComponent(crawler.conversation.busy ? 1 : 0.85).cgColor)
        context.fillEllipse(in:CGRect(x:5,y:-2.1,width:4.2,height:4.2))
        context.restoreGState()
    }
}

@MainActor
final class CrawlerSurface:NSView {
    let webView:WKWebView
    let overlay:CrawlerRenderer
    init(webView:WKWebView,crawler:CrawlerController) {
        self.webView=webView;overlay=CrawlerRenderer(crawler:crawler)
        super.init(frame:.zero)
        addSubview(webView);addSubview(overlay)
    }
    required init?(coder:NSCoder) {nil}
    override func layout() {super.layout();webView.frame=bounds;overlay.frame=bounds}
}
