import Foundation
import Observation
import AtlasCore

@MainActor @Observable
final class IntelligenceModel {
    let provider=OllamaProvider()
    var models:[AIModel]=[]
    var chatModel=UserDefaults.standard.string(forKey:"atlas.chatModel") ?? ""
    var embeddingModel=UserDefaults.standard.string(forKey:"atlas.embeddingModel") ?? ""
    var chatModels:[AIModel] {models.filter(\.supportsChat)}
    var embeddingModels:[AIModel] {models.filter(\.supportsEmbedding)}
    var connection="Not checked"
    var message:String?
    var question=""
    var answer=""
    var evidence:[RetrievedPassage]=[]
    var answering=false
    var building=false
    var preparingIndex=false
    var progress=IndexProgress()
    var lastQuestion=""
    var history:[AIMessage]=[]
    /// Instant estimate of how well the chat model suits the companion.
    var fitEstimate:ModelFitEstimate?
    /// A measured fit test for the current chat model, if one was run.
    var fitReport:ModelFitReport?
    var fitTesting=false
    var fitProgress=0.0
    @ObservationIgnored var onChatModelChange:(@MainActor (String)->Void)?
    @ObservationIgnored var onFitChange:(@MainActor (ModelFitBadge?)->Void)?
    @ObservationIgnored private var fitTask:Task<Void,Never>?
    @ObservationIgnored private let storage:StorageManager
    @ObservationIgnored private var index:SemanticIndex?
    @ObservationIgnored private var indexKey=""
    @ObservationIgnored private var request:Task<Void,Never>?
    @ObservationIgnored private var buildTask:Task<Void,Never>?
    @ObservationIgnored private var polling:Task<Void,Never>?
    @ObservationIgnored private var generation=UUID()
    init(storage:StorageManager) {self.storage=storage}
    func saveSettings() {
        onChatModelChange?(chatModel)
        UserDefaults.standard.set(chatModel,forKey:"atlas.chatModel")
        UserDefaults.standard.set(embeddingModel,forKey:"atlas.embeddingModel")
    }
    func refreshModels() async {
        do {
            models=try await provider.models();connection=models.isEmpty ? "Connected · No local models installed" : "Connected · Ollama on this Mac"
            if !chatModels.contains(where:{$0.name == chatModel}) {chatModel=chatModels.first?.name ?? ""}
            if !embeddingModels.contains(where:{$0.name == embeddingModel}) {embeddingModel=embeddingModels.first?.name ?? ""}
            saveSettings()
            message=embeddingModels.isEmpty ? "No embedding model is installed. Install nomic-embed-text in Ollama, then Refresh Models. Chat models cannot build AI Search." : nil
        } catch {connection=error.localizedDescription}
    }
    /// Reads the model's size and context window and rates it instantly.
    func evaluateFit() async {
        let model=chatModel
        guard !model.isEmpty else {fitEstimate=nil;fitReport=nil;publishFit();return}
        fitReport=storedReport(model)
        do {
            let profile=try await provider.profile(model:model)
            guard model == chatModel else {return}
            fitEstimate=ModelFit.estimate(profile)
            if let report=fitReport,report.digest != profile.digest {fitReport=nil}
        } catch {
            if model == chatModel {fitEstimate=nil}
        }
        publishFit()
    }
    /// Runs real companion requests through the model and scores them.
    func runFitTest() {
        guard !fitTesting,!chatModel.isEmpty else {return}
        let model=chatModel
        fitTesting=true;fitProgress=0;message=nil
        fitTask=Task {
            do {
                let digest=(try? await provider.profile(model:model).digest) ?? ""
                let report=try await ModelFit.run(provider:provider,model:model,digest:digest) {[weak self] done,total in
                    Task {@MainActor in self?.fitProgress=Double(done)/Double(max(1,total))}
                }
                if model == chatModel {fitReport=report;store(report);publishFit()}
            } catch {
                if !(error is CancellationError) {message="The fit test stopped: "+error.localizedDescription}
            }
            fitTesting=false
        }
    }
    func cancelFitTest() {fitTask?.cancel();fitTask=nil;fitTesting=false}
    private func publishFit() {
        let badge:ModelFitBadge?
        if let report=fitReport {badge=.init(rating:report.rating,summary:report.summary,measured:true)}
        else if let estimate=fitEstimate {badge=.init(rating:estimate.rating,summary:estimate.summary,measured:false)}
        else {badge=nil}
        onFitChange?(badge)
    }
    private func storedReport(_ model:String)->ModelFitReport? {
        guard let data=UserDefaults.standard.data(forKey:"atlas.fit."+model) else {return nil}
        return try? JSONDecoder().decode(ModelFitReport.self,from:data)
    }
    private func store(_ report:ModelFitReport) {
        if let data=try? JSONEncoder().encode(report) {UserDefaults.standard.set(data,forKey:"atlas.fit."+report.model)}
    }
    func testModel() async {
        do {let text=try await provider.generate(model:chatModel,prompt:"Reply with: Atlas is ready.");message=String(text.prefix(200))}
        catch {message=error.localizedDescription}
    }
    func reset() {
        generation=UUID();request?.cancel();buildTask?.cancel();polling?.cancel();index=nil;indexKey=""
        answering=false;building=false;preparingIndex=false;answer="";evidence=[];history=[];progress=IndexProgress()
    }
    private func connect(_ record:PackageRecord) async throws -> SemanticIndex {
        let token=generation,selected=embeddingModel
        let model=try await provider.embeddingModel(embeddingModel)
        let access=try await storage.acquire()
        try Task.checkCancellation()
        guard token == generation,selected == embeddingModel else {throw CancellationError()}
        let key=access.libraryID.uuidString+record.id+record.package.version+model.digest
        if key == indexKey,let index {return index}
        guard !building else {throw AtlasError.busy}
        let next=try await Task.detached {try SemanticIndex(access:access,record:record,model:model)}.value
        try Task.checkCancellation()
        guard token == generation,selected == embeddingModel else {throw CancellationError()}
        index=next;indexKey=key;progress=await next.snapshot();return next
    }
    func loadIndex(_ record:PackageRecord?) async {
        guard let record,!embeddingModel.isEmpty else {return}
        do {_ = try await connect(record)}catch {message=error.localizedDescription}
    }
    func build(browser:BrowserModel,articles:[ArticleID]) {
        guard !building,!preparingIndex,let record=browser.record,let articleProvider=browser.provider else {return}
        preparingIndex=true
        let token=generation
        buildTask=Task {
            do {
                let store=try await connect(record);try Task.checkCancellation()
                try await store.enqueue(articles);building=true;preparingIndex=false;message=nil
                polling=Task { [self] in
                    while !Task.isCancelled {
                        let snapshot=await store.snapshot();self.progress=snapshot
                        try? await Task.sleep(for:.milliseconds(500))
                    }
                }
                try await store.build(provider:articleProvider,embeddings:provider)
                if token == generation {progress=await store.snapshot()}
            } catch {if token == generation && !(error is CancellationError) {message=error.localizedDescription}}
            if token == generation {building=false;preparingIndex=false;polling?.cancel();if let index {progress=await index.snapshot()}}
        }
    }
    func pauseIndex() {buildTask?.cancel()}
    func cancelIndex() {
        let task=buildTask;task?.cancel()
        Task {await task?.value;do {try await index?.cancelQueue();if let index {progress=await index.snapshot()}}catch {message=error.localizedDescription}}
    }
    func ask(browser:BrowserModel) {
        guard !answering,let record=browser.record else {message="Open an installed Wikipedia package first.";return}
        let text=question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else {return}
        let token=generation;answering=true;answer="";evidence=[];lastQuestion=text;message=nil
        request=Task {
            do {
                let store=try await connect(record)
                let retrieval=(history.filter {$0.role == "user"}.suffix(1).map(\.content)+[text]).joined(separator:"\n")
                let sources=try await store.retrieve(question:retrieval,embeddings:provider)
                try Task.checkCancellation();guard token == generation else {return}
                guard !sources.isEmpty else {throw AIError.noEvidence};evidence=sources
                for try await part in provider.chat(model:chatModel,messages:AskGrounding.messages(question:text,history:history,passages:sources),json:false) {
                    try Task.checkCancellation();guard token == generation else {return};answer += part
                }
                let finalized=try await AskGrounding.finalize(answer,question:text,passages:sources,provider:provider,model:chatModel)
                try Task.checkCancellation();guard token == generation else {return}
                answer=finalized
                history += [AIMessage("user",text),AIMessage("assistant",answer)];history=Array(history.suffix(6))
            } catch {if token == generation {message=Task.isCancelled ? "Answer stopped." : error.localizedDescription}}
            if token == generation {answering=false}
        }
    }
    func stopAnswer() {request?.cancel()}
}
