import XCTest
@testable import AtlasCore

/// Replies with scripted text and records what it was asked.
private final class ScriptedModel:LLMProvider,@unchecked Sendable {
    private let lock=NSLock()
    private var replies:[String]
    private(set) var requests:[[AIMessage]]=[]
    private(set) var formats:[AIResponseFormat]=[]
    init(_ replies:[String]) {self.replies=replies}
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"test",capabilities:["completion"])}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        chat(model:model,messages:messages,format:json ? .json : .text,options:AIChatOptions())
    }
    func chat(model:String,messages:[AIMessage],format:AIResponseFormat,options:AIChatOptions)->AsyncThrowingStream<String,Error> {
        lock.lock()
        requests.append(messages);formats.append(format)
        let reply=replies.isEmpty ? "{}" : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream {continuation in continuation.yield(reply);continuation.finish()}
    }
}

final class CompanionPlannerTests:XCTestCase {
    private let context=CompanionPromptContext(title:"Ray Charles",sections:["introduction","Career"],stats:"3 text blocks, 2 links, 0 images",
                                               opening:"[b1] § introduction\nRay Charles was a singer.",excerpts:"[b2] § Career\nHe recorded for Atlantic Records.",
                                               coverage:"Selected excerpts.",state:"idle",highlights:["green: adjectives ending with “w” (3)"],results:["r1: 3 adjectives ending with “w”"])

    func testOneSchemaConstrainedCallProducesAPlan() async throws {
        let model=ScriptedModel([#"{"steps":[{"action":"highlight","query":{"unit":"word","partOfSpeech":"verb"},"color":"blue"}],"reply":"Blue verbs coming up."}"#])
        let result=try await CompanionPlanner.plan(request:"verbs in blue please",context:context,history:[],provider:model,model:"m")
        XCTAssertEqual(result.plan.steps.map(\.action),["highlight"])
        XCTAssertEqual(result.plan.reply,"Blue verbs coming up.")
        XCTAssertFalse(result.repaired)
        XCTAssertEqual(model.requests.count,1)
        guard case .schema(let schema)=model.formats.first else {return XCTFail("The planner must constrain decoding with the schema")}
        XCTAssertTrue(schema.contains("\"highlight\""))
        // The stable page data comes before the history and the latest message.
        let sent=model.requests[0]
        XCTAssertEqual(sent.first?.role,"system")
        XCTAssertTrue(sent[1].content.contains("CURRENT ARTICLE"))
        XCTAssertTrue(sent.last?.content.hasSuffix("USER MESSAGE: verbs in blue please") == true)
        XCTAssertTrue(sent.last?.content.contains("r1: 3 adjectives") == true)
    }

    func testInvalidPlanGetsOneRepairWithTheReason() async throws {
        let model=ScriptedModel([#"{"steps":[{"action":"count","query":{"unit":"spaceships"}}],"reply":"Hmm."}"#,
                                 #"{"steps":[{"action":"count","query":{"unit":"image"}}],"reply":"Counting images."}"#])
        let result=try await CompanionPlanner.plan(request:"how many pictures",context:context,history:[],provider:model,model:"m")
        XCTAssertTrue(result.repaired)
        XCTAssertEqual(result.plan.steps.first?.query?.unit,"image")
        XCTAssertTrue(model.requests[1].last?.content.contains("spaceships") == true,"The repair request explains what was wrong")
    }

    func testStepsThatStillFailAreReportedNotGuessed() async throws {
        let bad=#"{"steps":[{"action":"count","query":{"unit":"link"}},{"action":"teleport"}],"reply":"Sure."}"#
        let model=ScriptedModel([bad,bad])
        let result=try await CompanionPlanner.plan(request:"count links and teleport",context:context,history:[],provider:model,model:"m")
        XCTAssertEqual(result.plan.steps.map(\.action),["count"])
        XCTAssertEqual(result.rejected.count,1)
    }

    func testPlaceholderRepliesAreDropped() async throws {
        let model=ScriptedModel([#"{"steps":[],"reply":"<a short answer taken from the ARTICLE text>"}"#])
        let result=try await CompanionPlanner.plan(request:"when was he born",context:context,history:[],provider:model,model:"m")
        XCTAssertNil(result.plan.reply)
    }

    func testNoArticleContext() {
        let messages=CompanionPlanner.messages(request:"hello",context:CompanionPromptContext(),history:[.init("user","hi"),.init("assistant","Hello!")])
        XCTAssertTrue(messages[1].content.contains("NO ARTICLE IS OPEN"))
        XCTAssertEqual(messages.suffix(3).first?.content,"hi")
    }

    func testSemanticFilterOnlyAcceptsListedWords() async throws {
        let model=ScriptedModel([#"{"matches":[0,2,99]}"#])
        let chosen=try await CompanionSemanticFilter.select(["piano","house","jazz"],meaning:"related to music",provider:model,model:"m")
        XCTAssertEqual(chosen,["piano","jazz"])
    }

    func testFitEstimateAndScoring() {
        let llama=AIModelProfile(name:"llama3.1:latest",digest:"x",parameters:8.0,family:"llama",quantization:"Q4_K_M",contextLength:131072,capabilities:["completion","tools"])
        XCTAssertEqual(ModelFit.estimate(llama).rating,.medium)
        let big=AIModelProfile(name:"qwen3:32b",digest:"x",parameters:32,family:"qwen3",quantization:"Q4_K_M",contextLength:40960,capabilities:["completion"])
        XCTAssertEqual(ModelFit.estimate(big).rating,.strong)
        let tiny=AIModelProfile(name:"tiny",digest:"x",parameters:1.5,family:nil,quantization:"Q2_K",contextLength:2048,capabilities:["completion"])
        XCTAssertEqual(ModelFit.estimate(tiny).rating,.weak)
        let embed=AIModelProfile(name:"nomic",digest:"x",parameters:0.137,family:nil,quantization:nil,contextLength:2048,capabilities:["embedding"])
        XCTAssertEqual(ModelFit.estimate(embed).rating,.weak)
        XCTAssertEqual(AIModelProfile.parameterCount("8.0B"),8.0)
        XCTAssertEqual(AIModelProfile.parameterCount("567M"),0.567)
        XCTAssertEqual(ModelFit.rate(passed:12,total:12,averageSeconds:4),.strong)
        XCTAssertEqual(ModelFit.rate(passed:12,total:12,averageSeconds:20),.medium)
        XCTAssertEqual(ModelFit.rate(passed:8,total:12,averageSeconds:4),.medium)
        XCTAssertEqual(ModelFit.rate(passed:5,total:12,averageSeconds:4),.weak)
    }

    func testFitTestCasesAcceptTheIntendedPlans() async throws {
        let ideal=[
            #"{"steps":[{"action":"highlight","query":{"unit":"word","partOfSpeech":"adjective","endsWith":"w"},"color":"green"}],"reply":"ok"}"#,
            #"{"steps":[{"action":"count","query":{"unit":"character","equals":"."}}],"reply":"ok"}"#,
            #"{"steps":[{"action":"highlight","query":{"unit":"word","startsWith":"a","endsWith":"r"}}],"reply":"ok"}"#,
            #"{"steps":[{"action":"count","query":{"unit":"link"}}],"reply":"ok"}"#,
            #"{"steps":[{"action":"count","query":{"unit":"letter","letterCase":"uppercase"}}],"reply":"ok"}"#,
            #"{"steps":[{"action":"highlight","query":{"unit":"word","partOfSpeech":"verb"},"color":"half green half yellow"}],"reply":"ok"}"#,
            #"{"steps":[{"action":"go","place":"Career"}],"reply":"ok"}"#,
            #"{"steps":[],"reply":"Lovely, thanks!"}"#,
            #"{"steps":[{"action":"goto","query":{"unit":"word","order":"longest","rank":3}}],"reply":"ok"}"#,
            #"{"steps":[{"action":"open","title":"Paris"}],"reply":"ok"}"#,
            #"{"steps":[{"action":"clear"}],"reply":"ok"}"#,
            #"{"steps":[{"action":"list","query":{"unit":"sentence","order":"longest"}}],"reply":"ok"}"#
        ]
        let report=try await ModelFit.run(provider:ScriptedModel(ideal),model:"m",digest:"d")
        XCTAssertEqual(report.passed,report.total,"Failures: \(report.failures)")
        XCTAssertEqual(report.rating,.strong)
    }
}
