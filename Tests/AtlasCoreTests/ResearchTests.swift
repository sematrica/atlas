import XCTest
@testable import AtlasCore

private let researchText="Economic pressure and military conflict contributed to the decline."
private actor ResearchFixture:ResearchArticleProvider {
    let articles:[Article]
    init() {
        articles=[Article(id:.init(packageID:"research-test",path:"A/First"),title:"First",html:"<h1>First</h1><p>\(researchText)</p><a href='Second'>Second</a>"),Article(id:.init(packageID:"research-test",path:"A/Second"),title:"Second",html:"<h1>Second</h1><p>\(researchText) Historians disagree about the balance of causes.</p>")]
    }
    func article(for id:ArticleID) throws -> Article {guard let article=articles.first(where:{$0.id == id}) else {throw AtlasError.articleUnavailable};return article}
    func info(path:String) throws -> ArchiveResource {let a=try article(for:.init(packageID:"research-test",path:path));return .init(path:path,title:a.title,mimeType:"text/html",byteCount:UInt64(a.html.utf8.count))}
    func read(path:String,offset:UInt64,length:Int) throws -> Data {let a=try article(for:.init(packageID:"research-test",path:path));return Data(a.html.utf8).dropFirst(Int(offset)).prefix(length)}
    func search(_ query:String,limit:Int) -> [SearchResult] {articles.prefix(limit).map {SearchResult(articleID:$0.id,title:$0.title,excerpt:"")}}
    func hasArchiveFullText()->Bool {false}
    func fullTextSearch(_ query:String,limit:Int)->[SearchResult] {[]}
    func articleBatch(offset:UInt64)->ArchiveArticleBatch {
        let ids=offset<2 ? [articles[Int(offset)].id] : []
        return .init(articles:ids,next:min(3,offset+1),totalEntries:3)
    }
}
private struct ResearchLLM:LLMProvider {
    var delay=false
    func models() async throws -> [AIModel] {[]}
    func validate(model:String) async throws -> AIModel {.init(name:model,digest:"test")}
    func chat(model:String,messages:[AIMessage],json:Bool)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream {continuation in
            let task=Task {
                do {
                    if delay {try await Task.sleep(for:.seconds(30))}
                    let system=messages.first?.content ?? ""
                    let text:String
                    if system.contains("Plan offline") {text=#"{"questions":["What caused decline?"],"queries":["decline"]}"#}
                    else if system.contains("Synthesize") {text=#"{"paragraphs":[{"text":"The sources describe economic and military explanations.","sources":[0]}]}"#}
                    else {text="{\"findings\":[{\"claim\":\"Economic and military pressures contributed.\",\"passage\":0,\"quote\":\"\(researchText)\"}],\"queries\":[],\"gaps\":[\"Relative importance remains uncertain.\"]}"}
                    continuation.yield(text);continuation.finish()
                } catch {continuation.finish(throwing:error)}
            }
            continuation.onTermination={_ in task.cancel()}
        }
    }
}
final class ResearchTests:XCTestCase {
    var root:URL!
    var access:LibraryAccess!
    var record:PackageRecord!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let metadata=try LibraryLayout().establish(at:root);access=try LibraryAccess(root:root,libraryID:metadata.id)
        record=PackageRecord(package:.init(id:"research-test",name:"Research",languageCode:"eng",kind:.standard,summary:"test",version:"1",downloadURL:URL(string:"https://example.test/research.zim")!,downloadBytes:1,format:.zim,source:"Test",family:"Test"))
    }
    override func tearDownWithError() throws {access=nil;try? FileManager.default.removeItem(at:root)}
    func testWholeArchiveIndexPersistsAndResumesWithoutDuplicates() async throws {
        let store=try ResearchStore(access:access,record:record),provider=ResearchFixture()
        try await store.indexAll(provider:provider)
        let progress=try await store.progress()
        XCTAssertTrue(progress.complete);XCTAssertEqual(progress.articles,2)
        let matches=try await store.search("military",limit:20)
        XCTAssertEqual(matches.count,2)
        let reopened=try ResearchStore(access:access,record:record)
        try await reopened.indexAll(provider:provider)
        let again=try await reopened.search("military",limit:20)
        XCTAssertEqual(again.count,2)
        _ = try await reopened.search("\" OR * NEAR injection")
    }
    func testResearchBatchResumeAndCitationPersistence() async throws {
        let store=try ResearchStore(access:access,record:record),provider=ResearchFixture()
        let engine=ResearchEngine(provider:provider,llm:ResearchLLM(),store:store)
        let first=try await engine.execute(.init(question:"Why decline?",model:"test",exhaustive:true),budget:1)
        XCTAssertEqual(first.readCount,1);XCTAssertEqual(first.noteCount,1);XCTAssertTrue(first.status.contains("resume"))
        XCTAssertTrue(first.report.contains("[1]"));XCTAssertEqual(first.reportSources.first?.quote,researchText)
        let reopened=try ResearchStore(access:access,record:record)
        let savedRuns=try await reopened.recentRuns()
        let saved=try XCTUnwrap(savedRuns.first)
        let nextEngine=ResearchEngine(provider:provider,llm:ResearchLLM(),store:reopened)
        let complete=try await nextEngine.execute(saved,budget:10)
        XCTAssertEqual(complete.readCount,2);XCTAssertEqual(complete.noteCount,2);XCTAssertTrue(complete.archiveFinished)
        XCTAssertEqual(complete.status,"Research complete")
        let notes=try await reopened.notes(job:complete.id)
        XCTAssertEqual(notes.count,2)
    }
    func testEvidenceRejectsFabricatedQuotesAndBadSourceNumbers() async throws {
        let provider=ResearchFixture(),article=try await provider.article(for:.init(packageID:"research-test",path:"A/First"))
        let passages=TextExtractor.chunks(article)
        let raw=#"{"findings":[{"claim":"invented","passage":0,"quote":"This fabricated claim is not on the page."},{"claim":"wrong index","passage":99,"quote":"Economic pressure and military conflict contributed to the decline."}],"queries":[],"gaps":[]}"#
        let reading=try JSONDecoder().decode(ResearchEvidence.Reading.self,from:Data(raw.utf8))
        XCTAssertTrue(ResearchEvidence.validate(reading,passages:passages).isEmpty)
        XCTAssertEqual(ResearchEvidence.localLinks(article).first?.path,"A/Second")
    }
    func testStopLeavesAResumableCheckpoint() async throws {
        let store=try ResearchStore(access:access,record:record)
        let engine=ResearchEngine(provider:ResearchFixture(),llm:ResearchLLM(delay:true),store:store)
        let task=Task {try await engine.execute(.init(question:"Decline",model:"test"),budget:2)}
        try await Task.sleep(for:.milliseconds(100));task.cancel()
        do {_ = try await task.value;XCTFail("Cancelled research completed")} catch is CancellationError {} catch {XCTFail("Unexpected cancellation error: \(error)")}
        let saved=try await store.recentRuns()
        XCTAssertEqual(saved.first?.status,"Paused");XCTAssertEqual(saved.first?.readCount,0)
    }
    func testRevisedQuestionRetainsEvidenceInIndependentNotebook() async throws {
        let store=try ResearchStore(access:access,record:record)
        let engine=ResearchEngine(provider:ResearchFixture(),llm:ResearchLLM(),store:store)
        let original=try await engine.execute(.init(question:"Why decline?",model:"test",exhaustive:true),budget:1)
        let revised=try await store.fork(original,question:"Compare military explanations",model:"test")
        XCTAssertNotEqual(original.id,revised.id);XCTAssertEqual(revised.parentID,original.id)
        XCTAssertEqual(revised.noteCount,1);XCTAssertEqual(revised.readCount,0)
        let notes=try await store.relevantNotes(job:revised.id,question:"military")
        XCTAssertEqual(notes.count,1);XCTAssertEqual(notes.first?.quote,researchText)
        let visited=try await store.visited(job:revised.id,path:"A/First")
        XCTAssertFalse(visited)
    }
    func testLiveArchiveAndLocalModelResearch() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_RESEARCH_LIVE"] == "1" else {throw XCTSkip("Opt-in downloaded ZIM and local Ollama research test")}
        let fixture=URL(fileURLWithPath:"/tmp/AtlasStage2LiveLibrary")
        let metadata=try LibraryLayout().establish(at:fixture)
        let fixtureAccess=try LibraryAccess(root:fixture,libraryID:metadata.id)
        let installed=try XCTUnwrap(PackageManifest(access:fixtureAccess).load().first {$0.state == .installed && $0.package.format == .zim})
        let provider=try ZIMArticleProvider(access:fixtureAccess,record:installed)
        let store=try ResearchStore(access:access,record:installed)
        try await store.indexAll(provider:provider)
        let progress=try await store.progress()
        XCTAssertTrue(progress.complete);XCTAssertGreaterThan(progress.articles,0)
        let matches=try await store.search("Ray Charles")
        XCTAssertFalse(matches.isEmpty)
        if try await provider.hasArchiveFullText() {
            let hits=try await provider.fullTextSearch("Charles",limit:5)
            XCTAssertFalse(hits.isEmpty)
        }
        let engine=ResearchEngine(provider:provider,llm:OllamaProvider(),store:store)
        let result=try await engine.execute(.init(question:"What musical styles did Ray Charles combine?",model:"llama3.1:latest"),budget:1)
        print("LIVE RESEARCH: \(result.status), read \(result.readCount), notes \(result.noteCount)\n\(result.report)")
        XCTAssertEqual(result.readCount,1);XCTAssertGreaterThan(result.noteCount,0)
        XCTAssertFalse(result.reportSources.isEmpty);XCTAssertTrue(result.report.contains("[1]"))
    }
}
