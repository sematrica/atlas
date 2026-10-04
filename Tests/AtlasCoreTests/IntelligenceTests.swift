import XCTest
@testable import AtlasCore

final class IntelligenceTests:XCTestCase {
    func testModelCapabilitiesSeparateChatFromEmbedding() {
        let chat=AIModel(name:"llama3.1",digest:"chat",capabilities:["completion","tools"])
        let embedding=AIModel(name:"nomic-embed-text",digest:"embedding",capabilities:["embedding"])
        XCTAssertTrue(chat.supportsChat);XCTAssertFalse(chat.supportsEmbedding)
        XCTAssertTrue(embedding.supportsEmbedding);XCTAssertFalse(embedding.supportsChat)
    }
    func testOllamaEmbeddingErrorProvidesRecoveryInstructions() {
        let response=Data(#"{"error":"This server does not support embeddings. Start it with `--embeddings`"}"#.utf8)
        XCTAssertThrowsError(try OllamaProvider.decodeResponse(response,status:500,operation:"embed")) {error in
            XCTAssertTrue(error.localizedDescription.contains("dedicated embedding model"))
            XCTAssertFalse(error.localizedDescription.contains("invalid response"))
        }
    }
    func testMissingModelErrorIsPreserved() {
        let response=Data(#"{"error":"model not found"}"#.utf8)
        XCTAssertThrowsError(try OllamaProvider.decodeResponse(response,status:404,operation:"show")) {error in
            XCTAssertTrue(error.localizedDescription.contains("model not found"))
        }
    }
    func testExtractionPreservesSectionAndIgnoresScripts() {
        let article=Article(id:.init(packageID:"test",path:"Holland"),title:"Holland",html:"<script>secret noise</script><h2 id='Geography'>Geography</h2><p>Holland is a region within the Netherlands, rather than the whole country.</p>")
        let passages=TextExtractor.chunks(article)
        XCTAssertEqual(passages.count,1);XCTAssertEqual(passages[0].anchor,"Geography")
        XCTAssertEqual(passages[0].section,["Geography"]);XCTAssertFalse(passages[0].text.contains("secret"))
    }
    func testCitationIDsMustBelongToRetrievedEvidence() {
        XCTAssertTrue(AskGrounding.validCitations("Supported [1].",count:1))
        XCTAssertFalse(AskGrounding.validCitations("Invented [2].",count:1))
        XCTAssertFalse(AskGrounding.validCitations("Uncited answer",count:2))
    }
    func testCosineRejectsDifferentEmbeddingDimensions() {
        XCTAssertEqual(SemanticIndex.cosine([1,0],[1]),-1)
        XCTAssertEqual(SemanticIndex.cosine([1,0],[1,0]),1)
    }
    func testCrawlerRejectsUnseenIDsAndFabricatedQuotes() {
        let observation=CrawlerObservation(center:.zero,radius:100,viewport:.init(x:0,y:0,width:100,height:100),documentWidth:100,documentHeight:100,terrain:[])
        XCTAssertFalse(CrawlerDecision(action:"followLink",elementID:"guessed").validate(in:observation))
        XCTAssertFalse(CrawlerDecision(action:"reportFound",quote:"Invented evidence not observed",confidence:0.99).validate(in:observation))
    }
    func testIndexCanReopenAndResumeWithoutDuplicatingPassages() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AtlasIndexTest-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let metadata=try LibraryLayout().establish(at:root)
        let access=try LibraryAccess(root:root,libraryID:metadata.id)
        let package=WikipediaPackage(id:"fixture",name:"Fixture",languageCode:"en",kind:.textOnly,summary:"",version:"1",downloadURL:URL(string:"https://example.com/test.zim")!,downloadBytes:1,format:.zim,source:"test",family:"test")
        let model=AIModel(name:"fake",digest:"1",capabilities:["embedding"])
        let index=try SemanticIndex(access:access,record:PackageRecord(package:package),model:model)
        try await index.enqueue([.init(packageID:"fixture",path:"Holland")])
        try await index.build(provider:FixtureArticle(),embeddings:FixtureEmbedding())
        let reopened=try SemanticIndex(access:access,record:PackageRecord(package:package),model:model)
        try await reopened.build(provider:FixtureArticle(),embeddings:FixtureEmbedding())
        let progress=await reopened.snapshot()
        XCTAssertEqual(progress.chunks,1);XCTAssertEqual(progress.completed.count,1)
    }
    func testRealWikipediaIndexAndAnswer() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_AI_TESTS"] == "1" else {throw XCTSkip("Opt-in local Wikipedia and Ollama integration")}
        let live=URL(fileURLWithPath:"/tmp/AtlasStage2LiveLibrary")
        let metadata=try LibraryLayout().establish(at:live)
        let access=try LibraryAccess(root:live,libraryID:metadata.id)
        let record=try XCTUnwrap(PackageManifest(access:access).load().first)
        let articles=try ZIMArticleProvider(access:access,record:record)
        let matches=try await articles.search("Ray Charles",limit:20)
        let album=try XCTUnwrap(matches.first {$0.title == "Ray Charles (album)"})
        let llm=OllamaProvider();let embedding=try await llm.embeddingModel("nomic-embed-text:latest")
        let index=try SemanticIndex(access:access,record:record,model:embedding)
        try await index.enqueue([album.articleID]);try await index.build(provider:articles,embeddings:llm)
        let passages=try await index.retrieve(question:"Which record label released Ray Charles's debut album?",embeddings:llm)
        XCTAssertFalse(passages.isEmpty);XCTAssertTrue(passages.allSatisfy {$0.article == album.articleID})
        var answer=""
        for try await part in llm.chat(model:"llama3.1:latest",messages:AskGrounding.messages(question:"Which record label released Ray Charles's debut album?",history:[],passages:passages),json:false) {answer += part}
        answer=try await AskGrounding.finalize(answer,question:"Explain the retrieved facts with citations",passages:passages,provider:llm,model:"llama3.1:latest")
        XCTAssertTrue(AskGrounding.validCitations(answer,count:passages.count),answer)
        print("REAL WIKIPEDIA ASK VERIFIED: \(answer)")
    }
    func testRealLocalEmbeddingsAndGroundedAnswer() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_AI_TESTS"] == "1" else {throw XCTSkip("Opt-in local Ollama integration")}
        let llm=OllamaProvider()
        let model=try await llm.embeddingModel("nomic-embed-text:latest")
        XCTAssertTrue(model.supportsEmbedding)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AtlasAI-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let metadata=try LibraryLayout().establish(at:root)
        let access=try LibraryAccess(root:root,libraryID:metadata.id)
        let package=WikipediaPackage(id:"fixture",name:"Fixture",languageCode:"en",kind:.textOnly,summary:"",version:"1",downloadURL:URL(string:"https://example.com/test.zim")!,downloadBytes:1,format:.zim,source:"test",family:"test")
        let index=try SemanticIndex(access:access,record:PackageRecord(package:package),model:model)
        let article=ArticleID(packageID:"fixture",path:"Holland")
        try await index.enqueue([article]);try await index.build(provider:FixtureArticle(),embeddings:llm)
        let progress=await index.snapshot();XCTAssertGreaterThan(progress.chunks,0)
        let reopened=try SemanticIndex(access:access,record:PackageRecord(package:package),model:model)
        let passages=try await reopened.retrieve(question:"Difference between Holland and the Netherlands",embeddings:llm)
        XCTAssertFalse(passages.isEmpty);XCTAssertEqual(passages.first?.article,article)
        var answer=""
        for try await part in llm.chat(model:"llama3.1:latest",messages:AskGrounding.messages(question:"What is the difference between Holland and the Netherlands?",history:[],passages:passages),json:false) {answer += part}
        answer=try await AskGrounding.finalize(answer,question:"Explain the retrieved facts with citations",passages:passages,provider:llm,model:"llama3.1:latest")
        XCTAssertTrue(AskGrounding.validCitations(answer,count:passages.count),answer)
        XCTAssertTrue(answer.lowercased().contains("region"),answer)
        print("LOCAL ASK VERIFIED: \(progress.chunks) persisted chunks; \(answer)")
    }
}
private struct FixtureArticle:ArticleProvider {
    func article(for id:ArticleID) async throws -> Article {Article(id:id,title:"Holland",html:"<h2 id='Geography'>Geography</h2><p>Holland is a region on the western coast of the Netherlands. It consists of the provinces of North Holland and South Holland. The Netherlands is the country; Holland is only part of it.</p>")}
    func search(_ query:String,limit:Int) async throws -> [SearchResult] {[]}
    func info(path:String) async throws -> ArchiveResource {throw AtlasError.articleUnavailable}
    func read(path:String,offset:UInt64,length:Int) async throws -> Data {throw AtlasError.articleUnavailable}
}

private struct FixtureEmbedding:EmbeddingProvider {
    func embed(model:String,texts:[String]) async throws -> [[Float]] {texts.map {_ in [1,0,0]}}
}
