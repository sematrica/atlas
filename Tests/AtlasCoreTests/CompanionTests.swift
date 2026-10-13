import XCTest
@testable import AtlasCore
final class CompanionTests:XCTestCase {
    func testWholePageGrammarAndSectionRefinement() throws {
        let rect:[String:Int] = ["x":0,"y":0,"width":500,"height":60]
        let object:[String:Any] = ["document":"page","revision":1,"viewport":rect,"documentWidth":500,"documentHeight":600,"truncated":false,"links":[],"images":[],"blocks":[["id":"intro","text":"The beautiful red bird sings sweet songs.","section":"introduction","rect":rect],["id":"later","text":"A tall green tree grows.","section":"History","rect":rect]]]
        let page=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:object))
        let all=CompanionReasoning.words(page:page,kind:"adjectives",prefix:nil,section:nil)
        let intro=CompanionReasoning.words(page:page,kind:"adjectives",prefix:nil,section:"introduction")
        XCTAssertGreaterThan(all.count,intro.count);XCTAssertTrue(intro.allSatisfy {$0.id == "intro"})
        let prefixed=CompanionReasoning.words(page:page,kind:"words",prefix:"s",section:nil)
        XCTAssertEqual(prefixed.map(\.text),["sings","sweet","songs"])
        let context=CompanionContext.make(page:page,question:"tree")
        XCTAssertEqual(context.included,2);XCTAssertTrue(context.blockIDs.contains("later"))
        XCTAssertTrue(context.complete)
    }
    func testInvalidOperationAndUnsupportedKindAreRejected() throws {
        let invalid=#"{"operation":"executeJavaScript","reply":"ok"}"#
        XCTAssertFalse(try JSONDecoder().decode(CompanionDecision.self,from:Data(invalid.utf8)).valid)
        let invalidKind=#"{"operation":"words","kind":"French origin"}"#
        XCTAssertFalse(try JSONDecoder().decode(CompanionDecision.self,from:Data(invalidKind.utf8)).valid)
    }
    func testLiveConversationalReferencesAndCorrections() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_COMPANION_LIVE"] == "1" else {throw XCTSkip("Opt-in local companion conversation test")}
        let provider=OllamaProvider()
        let history=[AIMessage("user","How many adjectives are in this article?"),AIMessage("assistant","I identified 47 adjectives and saved their exact locations.")]
        let context="CURRENT PAGE: Test article. FOCUSED RESULT: adjectives-47. SAVED RESULTS: RESULT adjectives-47: adjectives; 47 exact targets; kind=adjectives; prefix=none; section=whole article."
        for request in ["Highlight them.","Show them.","Proov it.","I bet you can't point at them."] {
            let plan=try await CompanionReasoning.decide(messages:history+[.init("user",request)],context:context,provider:provider,model:"llama3.1:latest")
            print("COMPANION LIVE",request,String(decoding:try JSONEncoder().encode(plan),as:UTF8.self))
            XCTAssertEqual(plan.operation,"show",request);XCTAssertEqual(plan.resultID,"adjectives-47",request)
        }
        let correction=try await CompanionReasoning.decide(messages:history+[.init("user","Actually I meant verbs, only in the introduction.")],context:context,provider:provider,model:"llama3.1:latest")
        XCTAssertEqual(correction.operation,"words");XCTAssertEqual(correction.kind,"verbs");XCTAssertEqual(correction.section?.lowercased(),"introduction")
        let opinion=[AIMessage("user","What do you think of this article?"),AIMessage("assistant","Its argument is interesting but the evidence is limited. I saved the supporting passages.")]
        let proof=try await CompanionReasoning.decide(messages:opinion+[.init("user","Prove it.")],context:"CURRENT PAGE: Test. FOCUSED RESULT: evidence-2. SAVED RESULTS: RESULT adjectives-47: adjectives; 47 targets. RESULT evidence-2: Supporting passages; 2 targets; evidence for my interpretation.",provider:provider,model:"llama3.1:latest")
        XCTAssertEqual(proof.operation,"show");XCTAssertEqual(proof.resultID,"evidence-2")
    }
}

private actor PlainConversationFixture:LLMProvider {
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"test")}
    nonisolated func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream {continuation in
            if json {continuation.finish(throwing:AIError.invalidResponse)}
            else {continuation.yield("Hello! We can chat without an article open.");continuation.finish()}
        }
    }
}
private actor CorrectingSelectionFixture:LLMProvider {
    private var attempts=0
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"test")}
    func count() -> Int {attempts}
    private func next() -> String {
        attempts += 1
        if attempts == 1 {return #"{"operation":"select","unit":"word","order":"longest","demonstrate":true}"#}
        return #"{"operation":"select","unit":"word","order":"first","demonstrate":true}"#
    }
    nonisolated func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream {continuation in
            Task {
                continuation.yield(await self.next())
                continuation.finish()
            }
        }
    }
}
extension CompanionTests {
    func testPageMeasurementsCountUnicodeLettersAndKeepExtractionCoverage() throws {
        let rect:[String:Int]=["x":0,"y":0,"width":500,"height":40]
        let blocks:[[String:Any]]=[
            ["id":"intro","text":"Café e\u{301}lan A1 2? 🐝","section":"introduction","rect":rect],
            ["id":"later","text":"B3.","section":"History","rect":rect]
        ]
        func page(textTruncated:Bool,mediaTruncated:Bool)->CrawlerPageMap {
            let object:[String:Any]=["document":"page","revision":1,"viewport":rect,"documentWidth":500,"documentHeight":600,"truncated":textTruncated || mediaTruncated,"textTruncated":textTruncated,"mediaTruncated":mediaTruncated,"blocks":blocks,"links":[],"images":[]]
            return try! JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:object))
        }
        let whole=page(textTruncated:false,mediaTruncated:true)
        let letters=try XCTUnwrap(CrawlerPageAnalysis.measure(whole,metric:"letters"))
        XCTAssertEqual(letters.count,10) // Two accented graphemes each count as one letter.
        XCTAssertTrue(letters.complete) // Media truncation does not truncate text.
        XCTAssertEqual(letters.inspectedBlocks,2)
        XCTAssertEqual(letters.matchedBlocks,2)
        XCTAssertEqual(CrawlerPageAnalysis.measure(whole,metric:"letters",literal:"é")?.count,2)
        XCTAssertEqual(CrawlerPageAnalysis.measure(whole,metric:"digits")?.count,3)
        XCTAssertEqual(CrawlerPageAnalysis.measure(whole,metric:"numbers")?.count,3)
        XCTAssertEqual(CrawlerPageAnalysis.measure(whole,metric:"punctuation")?.count,2)
        XCTAssertEqual(CrawlerPageAnalysis.measure(whole,metric:"spaces")?.count,4)
        XCTAssertEqual(CrawlerPageAnalysis.measure(whole,metric:"characters",exclude:["spaces","punctuation"])?.count,whole.blocks.map { $0.text.filter {$0 != " " && $0 != "?" && $0 != "."}.count }.reduce(0,+))
        XCTAssertEqual(CrawlerPageAnalysis.measure(whole,metric:"textBlocks",section:"History")?.count,1)
        XCTAssertNil(CrawlerPageAnalysis.measure(whole,metric:"letters",section:"Unknown"))
        XCTAssertFalse(CrawlerPageAnalysis.measure(page(textTruncated:true,mediaTruncated:false),metric:"letters")!.complete)
    }

    func testMeasurementPlansPreserveExplicitUnitsFiltersAndExclusions() throws {
        func plan(_ json:String) throws -> CompanionDecision {
            try JSONDecoder().decode(CompanionDecision.self,from:Data(json.utf8))
        }
        let letters=try plan(#"{"operation":"measure","metric":"letters"}"#)
        let digits=try plan(#"{"operation":"measure","metric":"digits"}"#)
        let characters=try plan(#"{"operation":"measure","metric":"characters","exclude":["spaces","punctuation"]}"#)
        let rawCharacters=try plan(#"{"operation":"measure","metric":"characters"}"#)
        let filteredWords=try plan(#"{"operation":"measure","metric":"words","distinct":true,"prefix":"a"}"#)
        let plainWords=try plan(#"{"operation":"measure","metric":"words"}"#)
        let history=try plan(#"{"operation":"measure","metric":"letters","section":"History"}"#)
        let literal=try plan(#"{"operation":"measure","metric":"letters","literal":"e"}"#)
        let clarification=try plan(#"{"operation":"clarify","reply":"I cannot exclude vowels with this count tool."}"#)
        let requested="How many letters in this article (exluding numbers and non-letter characters)?"
        XCTAssertTrue(letters.consistent(with:requested))
        XCTAssertFalse(digits.consistent(with:requested))
        XCTAssertFalse(rawCharacters.consistent(with:requested))
        XCTAssertTrue(characters.consistent(with:"How many characters excluding spaces and punctuation?"))
        XCTAssertFalse(rawCharacters.consistent(with:"How many characters excluding spaces and punctuation?"))
        XCTAssertFalse(characters.consistent(with:"How many characters excluding spaces?"))
        XCTAssertTrue(filteredWords.consistent(with:"Count unique words starting with a"))
        XCTAssertFalse(plainWords.consistent(with:"Count unique words starting with a"))
        XCTAssertTrue(history.consistent(with:"How many letters in the History section?"))
        XCTAssertFalse(letters.consistent(with:"How many letters in the History section?"))
        XCTAssertTrue(literal.consistent(with:"How many e letters are in this article?"))
        XCTAssertFalse(letters.consistent(with:"How many e letters are in this article?"))
        XCTAssertFalse(letters.consistent(with:"Count letters excluding vowels"))
        XCTAssertTrue(clarification.consistent(with:"Count letters excluding vowels"))
        XCTAssertFalse(try plan(#"{"operation":"measure","metric":"characters","exclude":["links"]}"#).valid)
        XCTAssertEqual(CompanionToolCatalog.toolID(for:"measure"),"measure")
        XCTAssertEqual(CompanionToolCatalog.toolID(for:"show"),"crawler")
    }

    func testPlannerRepairsWrongTargetBeforeExecuting() async throws {
        let provider=CorrectingSelectionFixture()
        let decision=try await CompanionReasoning.decide(messages:[.init("user","Go to the first word of this article")],provider:provider,model:"test",allowedOperations:["select","clarify"])
        XCTAssertEqual(decision.operation,"select")
        XCTAssertEqual(decision.order,"first")
        let attempts=await provider.count()
        XCTAssertEqual(attempts,2)
    }
    func testExactSelectionPlansPreserveTargetMovementAndFootRestrictions() throws {
        func plan(_ json:String) throws -> CompanionDecision {
            try JSONDecoder().decode(CompanionDecision.self,from:Data(json.utf8))
        }
        let first=try plan(#"{"operation":"select","unit":"word","order":"first","demonstrate":true}"#)
        let longest=try plan(#"{"operation":"select","unit":"word","order":"longest","demonstrate":true}"#)
        let constrained=try plan(#"{"operation":"select","unit":"word","order":"longest","demonstrate":true,"footholds":["noun","verb"]}"#)
        let question=try plan(#"{"operation":"select","unit":"word","order":"longest","demonstrate":false}"#)
        let clarification=try plan(#"{"operation":"clarify","reply":"I cannot use adjective-only foot landings."}"#)
        XCTAssertTrue(first.consistent(with:"Go to the first word of this article?"))
        XCTAssertFalse(longest.consistent(with:"Go to the first word of this article?"))
        XCTAssertFalse(question.consistent(with:"Go to the first word of this article?"))
        XCTAssertTrue(question.consistent(with:"What is the longest word in this article?"))
        XCTAssertFalse(longest.consistent(with:"What is the longest word in this article?"))
        XCTAssertTrue(constrained.consistent(with:"Go to the longest word but do so only stepping on nouns or verbs"))
        XCTAssertFalse(longest.consistent(with:"Go to the longest word but do so only stepping on nouns or verbs"))
        XCTAssertFalse(constrained.consistent(with:"Go to the longest word"))
        XCTAssertFalse(clarification.consistent(with:"Go to the first word"))
        XCTAssertTrue(clarification.consistent(with:"Go to the longest word stepping only on adjectives"))
        XCTAssertFalse(longest.consistent(with:"Go to the longest word stepping only on adjectives"))
        for request in [
            "Go to the longest word but don't step on nouns",
            "Go to the longest word but don’t step on nouns",
            "Go to the longest word but can't step on nouns",
            "Go to the longest word but do not step on nouns"
        ] {
            XCTAssertFalse(constrained.consistent(with:request),request)
            XCTAssertTrue(clarification.consistent(with:request),request)
        }
        XCTAssertTrue(clarification.consistent(with:"Go to the first word and the longest word"))
        XCTAssertFalse(first.consistent(with:"Go to the first word and the longest word"))
    }
    func testOrdinalSelectionAndSentenceSelectionPlans() throws {
        func plan(_ json:String) throws -> CompanionDecision {
            try JSONDecoder().decode(CompanionDecision.self,from:Data(json.utf8))
        }
        let ordinal=try plan(#"{"operation":"select","unit":"word","order":"nthLongest","rank":2,"distinct":true,"demonstrate":false}"#)
        let firstSentence=try plan(#"{"operation":"select","unit":"sentence","order":"first","demonstrate":true}"#)
        XCTAssertTrue(ordinal.consistent(with:"What's the second largest word here?"))
        XCTAssertFalse(ordinal.consistent(with:"What's the third longest word here?"))
        XCTAssertTrue(firstSentence.consistent(with:"Point to the first sentence in the article"))
        XCTAssertFalse(firstSentence.consistent(with:"Point to the last sentence in the article"))
        XCTAssertFalse(try plan(#"{"operation":"select","unit":"word","order":"first","rank":1}"#).valid)
    }
    func testNoPageConversationDoesNotRequestJSON() async throws {
        let reply=try await CompanionReasoning.converse(messages:[.init("user","hello")],provider:PlainConversationFixture(),model:"test")
        XCTAssertTrue(reply.contains("Hello"))
    }
    func testDiscussionIgnoresUnusedFilterFields() throws {
        let json=#"{"operation":"discuss","kind":"greeting","reply":"Hello!","sources":[]}"#
        XCTAssertTrue(try JSONDecoder().decode(CompanionDecision.self,from:Data(json.utf8)).valid)
    }
    func testDiscussionWithoutAnAnswerIsInvalid() throws {
        for json in [#"{"operation":"discuss"}"#,#"{"operation":"discuss","reply":"   "}"#] {
            XCTAssertFalse(try JSONDecoder().decode(CompanionDecision.self,from:Data(json.utf8)).valid)
        }
    }
    func testRankedWordDecisionAcceptsOrdinalAndRejectsInvalidRank() throws {
        let good=#"{"operation":"rankedWord","rank":2,"distinct":true}"#
        let bad=#"{"operation":"rankedWord","rank":0}"#
        let missing=#"{"operation":"rankedWord"}"#
        XCTAssertTrue(try JSONDecoder().decode(CompanionDecision.self,from:Data(good.utf8)).valid)
        XCTAssertFalse(try JSONDecoder().decode(CompanionDecision.self,from:Data(bad.utf8)).valid)
        XCTAssertFalse(try JSONDecoder().decode(CompanionDecision.self,from:Data(missing.utf8)).valid)
    }
    func testLongArticleContextReportsPartialCoverageAndChunksCoverEveryBlock() throws {
        let rect:[String:Int]=["x":0,"y":0,"width":500,"height":60]
        let blocks=(0..<12).map {i -> [String:Any] in
            ["id":"b\(i)","text":String(repeating:i == 10 ? "nebula " : "ordinary ",count:90),"section":"Section \(i)","rect":rect]
        }
        let object:[String:Any]=["document":"page","revision":1,"viewport":rect,"documentWidth":500,"documentHeight":600,"truncated":false,"blocks":blocks,"links":[],"images":[]]
        let page=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:object))
        let selected=CompanionContext.make(page:page,question:"Tell me about the nebula",limit:2300)
        XCTAssertFalse(selected.complete)
        XCTAssertTrue(selected.coverageNote.contains("not the full article"))
        XCTAssertTrue(selected.blockIDs.contains("b10"))
        let chunks=CompanionContext.chunks(page:page,limit:1700)
        XCTAssertGreaterThan(chunks.count,1)
        XCTAssertEqual(chunks.reduce(into:Set<String>()) {$0.formUnion($1.blockIDs)},Set(blocks.compactMap {$0["id"] as? String}))
        XCTAssertTrue(chunks.allSatisfy {!$0.complete})
    }
    func testArticleChunkingKeepsTailOfOversizedParagraph() throws {
        let rect:[String:Int]=["x":0,"y":0,"width":500,"height":60]
        let body=String(repeating:"middle ",count:750)+"last paragraph fact"
        let object:[String:Any]=["document":"page","revision":1,"viewport":rect,"documentWidth":500,"documentHeight":600,"truncated":false,"blocks":[["id":"long","text":body,"section":"Introduction","rect":rect]],"links":[],"images":[]]
        let page=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:object))
        let chunks=CompanionContext.chunks(page:page,limit:1200)
        XCTAssertGreaterThan(chunks.count,1)
        XCTAssertTrue(chunks.last?.text.contains("last paragraph fact") == true)
        XCTAssertTrue(chunks.allSatisfy {$0.blockIDs == ["long"]})
    }
    func testLiveNoArticleConversation() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_COMPANION_LIVE"] == "1" else {throw XCTSkip("Opt-in local companion greeting test")}
        var history:[AIMessage]=[]
        for message in ["hello","hi","Can we talk about music without opening Wikipedia?"] {
            history.append(.init("user",message))
            let reply=try await CompanionReasoning.converse(messages:history,provider:OllamaProvider(),model:"llama3.1:latest")
            print("NO ARTICLE CHAT:",message,"->",reply)
            XCTAssertFalse(reply.isEmpty);XCTAssertFalse(reply.hasPrefix("{"))
            history.append(.init("assistant",reply))
        }
        let withPage=try await CompanionReasoning.decide(messages:[.init("user","hello")],context:"CURRENT PAGE: Birds. PAGE EXCERPTS: [p1] Birds have feathers. SAVED RESULTS: none.",provider:OllamaProvider(),model:"llama3.1:latest")
        XCTAssertEqual(withPage.operation,"discuss");XCTAssertFalse((withPage.reply ?? "").isEmpty)
    }
    func testLiveSecondLongestWordUsesOrdinalPageTool() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_COMPANION_LIVE"] == "1" else {throw XCTSkip("Opt-in local ordinal-word model test")}
        let context="CURRENT PAGE: Test article. SAVED RESULTS: none. ARTICLE COVERAGE: full rendered article. PAGE TEXT: [p1] Astronomy and butterflies are discussed here."
        let decision=try await CompanionReasoning.decide(
            messages:[.init("user","what's the second longest word here?")],
            context:context,provider:OllamaProvider(),model:"llama3.1:latest",
            allowedOperations:["rankedWord","words","clarify"])
        XCTAssertEqual(decision.operation,"rankedWord")
        XCTAssertEqual(decision.rank,2)
    }
    func testLiveScreenshotMovementRequestsKeepTargetAndFootRules() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_COMPANION_LIVE"] == "1" else {throw XCTSkip("Opt-in local screenshot request model test")}
        let provider=OllamaProvider()
        let context="CURRENT PAGE: Large language model. ARTICLE COVERAGE: page tools inspect full article. SAVED RESULTS: none. PAGE TEXT: [p1] Language models analyze words."
        let constrained=try await CompanionReasoning.decide(
            messages:[.init("user","Go to the longest word in this article but do so only stepping on nouns or verbs")],
            context:context,provider:provider,model:"llama3.1:latest",allowedOperations:["select","clarify"])
        XCTAssertEqual(constrained.operation,"select")
        XCTAssertEqual(constrained.unit,"word")
        XCTAssertEqual(constrained.order,"longest")
        XCTAssertEqual(Set(constrained.footholds ?? []),Set(["noun","verb"]))
        XCTAssertEqual(constrained.demonstrate,true)
        let first=try await CompanionReasoning.decide(
            messages:[.init("user","go to the first word of this article?")],
            context:context,provider:provider,model:"llama3.1:latest",allowedOperations:["select","clarify"])
        XCTAssertEqual(first.operation,"select")
        XCTAssertEqual(first.unit,"word")
        XCTAssertEqual(first.order,"first")
        XCTAssertEqual(first.demonstrate,true)
        XCTAssertTrue((first.footholds ?? []).isEmpty)
    }
}
