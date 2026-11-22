import XCTest
@testable import AtlasCore

final class VisitedArticleGraphTests:XCTestCase {
    func testVisitsPersistAsOneCardAndConnectByDirectAndSharedLinks() throws {
        var graph=VisitedArticleGraph()
        graph.record(packageID:"wiki",packageName:"Wikipedia",path:"A/Alpha",title:"Alpha",
                     outgoingPaths:["A/Beta","A/Shared", "A/Shared"])
        graph.record(packageID:"wiki",packageName:"Wikipedia",path:"A/Beta",title:"Beta",
                     outgoingPaths:["A/Shared","A/Alpha"])
        graph.record(packageID:"other",packageName:"Other",path:"A/Gamma",title:"Gamma",
                     outgoingPaths:["A/Alpha","A/Shared"])
        graph.record(packageID:"wiki",packageName:"Wikipedia",path:"A/Alpha",title:"Alpha",
                     outgoingPaths:["A/Beta","A/Shared"])
        XCTAssertEqual(graph.articles.count,3)
        XCTAssertEqual(graph.articles[0].visitCount,2)
        let connections=graph.connections()
        XCTAssertEqual(connections.count,1)
        XCTAssertTrue(connections[0].forward)
        XCTAssertTrue(connections[0].backward)
        XCTAssertEqual(connections[0].sharedPaths,["shared"])
        let restored=try JSONDecoder().decode(VisitedArticleGraph.self,from:JSONEncoder().encode(graph))
        XCTAssertEqual(restored.articles.count,3)
        XCTAssertEqual(restored.connections(),connections)
    }

    func testDragPositionIsBoundedAndSurvivesEncoding() throws {
        var graph=VisitedArticleGraph()
        graph.record(packageID:"wiki",packageName:"Wikipedia",path:"A/A",title:"A",outgoingPaths:[])
        graph.move(graph.articles[0].id,to:1200,900)
        let restored=try JSONDecoder().decode(VisitedArticleGraph.self,from:JSONEncoder().encode(graph))
        XCTAssertEqual(restored.articles[0].x,1200)
        XCTAssertEqual(restored.articles[0].y,900)
    }
}
