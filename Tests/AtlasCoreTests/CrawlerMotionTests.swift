import XCTest
@testable import AtlasCore

final class CrawlerMotionTests: XCTestCase {
    private func observation(at position: DocumentPosition) -> CrawlerObservation {
        CrawlerObservation(center: position, radius: 220,
                           viewport: TerrainRect(x: 0, y: 0, width: 1000, height: 800),
                           documentWidth: 1000, documentHeight: 800, terrain: [])
    }

    func testGuidanceRetargetKeepsMomentumAndTurnsGradually() {
        var crawler = ProceduralCrawlerAgent(seed: 7)
        crawler.start(position: DocumentPosition(x: 200, y: 200), mission: .freeCrawl)
        crawler.guide(to: DocumentPosition(x: 750, y: 200))
        for _ in 0..<24 {
            crawler.perceive(observation(at: crawler.state.position))
            crawler.advance(dt: 1.0 / 60)
        }
        let before = crawler.state.velocity
        XCTAssertGreaterThan(before.x, 150)

        crawler.guide(to: DocumentPosition(x: crawler.state.position.x, y: 650))
        XCTAssertEqual(crawler.state.velocity, before)
        crawler.perceive(observation(at: crawler.state.position))
        crawler.advance(dt: 1.0 / 60)
        let after = crawler.state.velocity
        XCTAssertGreaterThan(after.x, 0, "The body should carry through a turn")
        XCTAssertGreaterThan(after.y, 0, "The crawler should start steering immediately")
        XCTAssertLessThan(hypot(after.x - before.x, after.y - before.y), 100)
    }

    func testVoluntaryInspectionSettlesBeforeStopping() {
        var crawler = ProceduralCrawlerAgent(seed: 7)
        crawler.start(position: DocumentPosition(x: 200, y: 200), mission: .freeCrawl)
        crawler.guide(to: DocumentPosition(x: 750, y: 200))
        for _ in 0..<24 {
            crawler.perceive(observation(at: crawler.state.position))
            crawler.advance(dt: 1.0 / 60)
        }
        let moving = hypot(crawler.state.velocity.x, crawler.state.velocity.y)
        crawler.inspect(for: 0.3)
        crawler.perceive(observation(at: crawler.state.position))
        crawler.advance(dt: 1.0 / 60)
        let settling = hypot(crawler.state.velocity.x, crawler.state.velocity.y)
        XCTAssertGreaterThan(settling, 0)
        XCTAssertLessThan(settling, moving)
        crawler.pause()
        XCTAssertEqual(crawler.state.velocity, .zero, "Pause remains immediate")
    }

    func testMovementStaysInsideDocumentWhenGoalIsOutside() {
        var crawler = ProceduralCrawlerAgent(seed: 7)
        crawler.start(position: DocumentPosition(x: 40, y: 40), mission: .freeCrawl)
        crawler.guide(to: DocumentPosition(x: -200, y: -200))
        for _ in 0..<90 {
            crawler.perceive(observation(at: crawler.state.position))
            crawler.advance(dt: 1.0 / 60, speed: 600)
            XCTAssertGreaterThanOrEqual(crawler.state.position.x, 20)
            XCTAssertGreaterThanOrEqual(crawler.state.position.y, 20)
        }
    }

    func testGuidedMoveComesToRestAtItsDestination() {
        var crawler = ProceduralCrawlerAgent(seed: 7)
        let destination = DocumentPosition(x: 380, y: 200)
        crawler.start(position: DocumentPosition(x: 200, y: 200), mission: .freeCrawl)
        crawler.guide(to: destination)
        for _ in 0..<240 where crawler.state.behavior != .paused {
            crawler.perceive(observation(at: crawler.state.position))
            crawler.advance(dt: 1.0 / 60)
        }
        XCTAssertEqual(crawler.state.behavior, .paused)
        XCTAssertLessThan(crawler.state.position.distance(to: destination), 8)
    }
}
