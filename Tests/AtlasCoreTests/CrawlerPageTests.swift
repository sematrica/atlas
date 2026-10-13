import XCTest
@testable import AtlasCore

final class CrawlerPageTests:XCTestCase {
    func testConnectedRouteAndNoIllegalFallbackFeet() throws {
        let points=(0...8).map {DocumentPosition(x:Double($0)*40,y:100)}
        let route=try XCTUnwrap(CrawlerPageAnalysis.route(from:.init(x:0,y:100),to:.init(x:320,y:100),footholds:points))
        XCTAssertEqual(route.last,points.last)
        XCTAssertNil(CrawlerPageAnalysis.route(from:.zero,to:.init(x:1000,y:1000),footholds:points))
        let anchors=points.enumerated().map {TerrainAnchor(id:String($0.offset),position:$0.element,kind:.text)}
        var legs=CrawlerLegController();legs.reset(at:points[0]);XCTAssertTrue(legs.plant(body:points[0],anchors:anchors))
        for step in 0...320 {
            legs.advance(body:.init(x:Double(step),y:100),velocity:.init(x:50,y:0),anchors:anchors,dt:0.02,reduceMotion:false,strict:true)
            for leg in legs.legs {XCTAssertTrue(points.contains(leg.to));if !leg.isStepping {XCTAssertTrue(points.contains(leg.foot))}}
        }
    }
    func testPageMapDecodesOlderMapsWithoutTagsOrTextRevision() throws {
        let json=#"{"document":"d","revision":3,"viewport":{"x":0,"y":0,"width":1,"height":1},"documentWidth":10,"documentHeight":10,"blocks":[{"id":"a","text":"Hi","rect":{"x":0,"y":0,"width":1,"height":1}}],"links":[],"images":[],"truncated":false}"#
        let page=try JSONDecoder().decode(CrawlerPageMap.self,from:Data(json.utf8))
        XCTAssertNil(page.textRevision);XCTAssertNil(page.blocks[0].tag);XCTAssertFalse(page.blocks[0].isHeading)
        XCTAssertTrue(page.isTextComplete)
    }
}
