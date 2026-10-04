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
        last=0;link=displayLink(target:self,selector:#selector(frameTick(_:)));link?.add(to:.main,forMode:.common)
    }
    func stopAnimation() {link?.invalidate();link=nil;needsDisplay=true}
    @objc private func frameTick(_ display:CADisplayLink) {
        let dt=last == 0 ? 1.0/60 : display.timestamp-last;last=display.timestamp
        crawler.tick(dt:dt);needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        guard crawler.active,let context=NSGraphicsContext.current?.cgContext else {return}
        renderedFrames += 1
        let viewport=crawler.viewport,sx=bounds.width/max(1,viewport.width),sy=bounds.height/max(1,viewport.height)
        context.saveGState();defer {context.restoreGState()}
        context.scaleBy(x:sx,y:sy);context.translateBy(x:-viewport.x,y:-viewport.y)
        let state=crawler.agent.state,p=state.position
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
        let spawn=min(1,state.elapsed/0.65)
        context.setAlpha(spawn)
        let color=state.behavior == .found ? NSColor(calibratedRed:0.12,green:0.50,blue:0.38,alpha:1) : NSColor(calibratedWhite:0.18,alpha:1)
        // A pale narrow halo keeps the creature legible over images and dark article regions.
        for halo in [true,false] {
            context.setStrokeColor((halo ? NSColor.white.withAlphaComponent(0.8) : color).cgColor)
            context.setLineWidth(halo ? 3.2 : 1.25);context.setLineCap(.round);context.setLineJoin(.round)
            for i in crawler.legs.legs.indices {
                let a=crawler.legs.attachment(i,body:p),k=crawler.legs.knee(i,body:p),foot=crawler.legs.legs[i].foot
                context.move(to:CGPoint(x:a.x,y:a.y))
                context.addLine(to:CGPoint(x:p.x+(k.x-p.x)*spawn,y:p.y+(k.y-p.y)*spawn))
                context.addLine(to:CGPoint(x:p.x+(foot.x-p.x)*spawn,y:p.y+(foot.y-p.y)*spawn));context.strokePath()
                if crawler.debug,let _=crawler.legs.legs[i].anchorID {
                    context.setFillColor(NSColor.systemPink.cgColor);context.fillEllipse(in:CGRect(x:foot.x-2,y:foot.y-2,width:4,height:4))
                }
            }
        }
        context.translateBy(x:p.x,y:p.y);context.rotate(by:crawler.legs.heading)
        let breathing=crawler.reduceMotion ? 0 : sin(state.elapsed*3)*0.35
        context.setFillColor(color.cgColor);context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor);context.setLineWidth(0.8)
        context.addEllipse(in:CGRect(x:-9,y:-5-breathing,width:15,height:10+breathing*2));context.drawPath(using:.fillStroke)
        context.addEllipse(in:CGRect(x:3,y:-3.5,width:7,height:7));context.drawPath(using:.fillStroke)
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
