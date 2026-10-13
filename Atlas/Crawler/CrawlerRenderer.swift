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
        // A short, bounded follow softens sharp steering changes while leaving the feet
        // planted on their document anchors and the body close to its true position.
        let blend=1-exp(-dt/0.026)
        var x=current.x+(target.x-current.x)*blend
        var y=current.y+(target.y-current.y)*blend
        let dx=target.x-x,dy=target.y-y,gap=hypot(dx,dy)
        if gap>7 {x=target.x-dx/gap*7;y=target.y-dy/gap*7}
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
        if crawler.neonStyle {drawNeonCreature(context,at:p,state:state)} else {drawAmberCreature(context,at:p,state:state)}
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

    /// Neon boxes around the words the feet touch, fading after the foot lifts.
    private func drawTouches(_ context:CGContext) {
        guard crawler.touchGlow,!crawler.touchMarks.isEmpty else {return}
        let now=ProcessInfo.processInfo.systemUptime
        for mark in crawler.touchMarks.values {
            let alpha=CrawlerController.touchAlpha(now-mark.time)
            guard alpha>0.01 else {continue}
            let color:NSColor,filled:Bool
            switch mark.style {
            case .cyanOutline: color=Self.neonCyan;filled=false
            case .blueOutline: color=Self.neonBlue;filled=false
            case .pinkFill: color=Self.neonPink;filled=true
            case .blueFill: color=Self.neonBlue;filled=true
            case .cyanFill: color=Self.neonCyan;filled=true
            }
            let box=CGRect(x:mark.rect.x-3,y:mark.rect.y-1.5,width:mark.rect.width+6,height:mark.rect.height+3)
            context.saveGState()
            context.setShadow(offset:.zero,blur:9*alpha,color:color.withAlphaComponent(0.85*alpha).cgColor)
            if filled {context.setFillColor(color.withAlphaComponent(0.34*alpha).cgColor);context.fill(box)}
            context.setStrokeColor(color.withAlphaComponent(0.95*alpha).cgColor);context.setLineWidth(1.6)
            context.stroke(box)
            context.restoreGState()
        }
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
        let body=CGRect(x:-12,y:-6,width:24,height:12)
        context.setFillColor(NSColor(calibratedRed:0.03,green:0.05,blue:0.08,alpha:0.92).cgColor);context.fill(body)
        context.setShadow(offset:.zero,blur:6,color:limb.withAlphaComponent(0.8).cgColor)
        context.setStrokeColor(limb.cgColor);context.setLineWidth(1.5);context.stroke(body)
        context.setFillColor(limb.withAlphaComponent(crawler.conversation.busy ? 1 : 0.85).cgColor)
        context.fillEllipse(in:CGRect(x:4,y:-2.6,width:5.2,height:5.2))
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
