import XCTest
@testable import AtlasCore

final class CrawlerIntentLiveTests:XCTestCase {
    func testLocalModelPlansCompoundRequest() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_AI_INTENTS"] == "1" else {throw XCTSkip("Opt-in local Ollama intent test")}
        let plan=try await CrawlerIntentPlanner.plan(request:"Please move slowly, highlight verbs beginning with S except say, avoid the References section, and stay in this article.",provider:OllamaProvider(),model:"llama3.1:latest")
        print("LIVE INTENT PLAN: \(String(data:try JSONEncoder().encode(plan),encoding:.utf8)!)")
        XCTAssertNil(plan.clarification)
        XCTAssertEqual(plan.words?.partOfSpeech,"verbs")
        XCTAssertEqual(plan.words?.prefix?.lowercased(),"s")
        XCTAssertTrue(plan.words?.excluding?.contains(where:{$0.lowercased() == "say"}) ?? false)
        XCTAssertTrue(plan.avoidSections?.contains(where:{$0.lowercased() == "references"}) ?? false)
        XCTAssertTrue(plan.actions.contains {$0.action == "slower"})
        XCTAssertTrue(plan.actions.contains {$0.action == "stay"} || plan.explore == false)
    }
}
