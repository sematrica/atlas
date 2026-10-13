import SwiftUI
import AtlasCore

@MainActor @Observable
final class ResearchModel {
    var question=""
    var budget=20
    var exhaustive=false
    var run:ResearchRun?
    var jobs:[ResearchRun]=[]
    var notes:[ResearchNote]=[]
    var indexProgress=ResearchIndexProgress()
    var busy=false
    var indexing=false
    var message:String?
    var scope="Open an offline package"
    @ObservationIgnored private let storage:StorageManager
    @ObservationIgnored private var store:ResearchStore?
    @ObservationIgnored private var engine:ResearchEngine?
    @ObservationIgnored private var key=""
    @ObservationIgnored private var generation=UUID()
    @ObservationIgnored private var researchTask:Task<Void,Never>?
    @ObservationIgnored private var indexTask:Task<Void,Never>?
    @ObservationIgnored private var poll:Task<Void,Never>?
    init(storage:StorageManager) {self.storage=storage}
    func reset() {generation=UUID();researchTask?.cancel();indexTask?.cancel();poll?.cancel();store=nil;engine=nil;key="";busy=false;indexing=false;run=nil;jobs=[];notes=[];scope="Open an offline package"}
    func connect(browser:BrowserModel,ai:IntelligenceModel) async throws {
        guard let record=browser.record,let provider=browser.provider as? any ResearchArticleProvider else {throw AIError.message("Open a downloaded ZIM package first.")}
        let token=generation,access=try await storage.acquire()
        let nextKey=access.libraryID.uuidString+record.id+record.package.version
        if nextKey == key,store != nil {return}
        let next=try await Task.detached {try ResearchStore(access:access,record:record)}.value
        guard token == generation else {throw CancellationError()}
        store=next;engine=ResearchEngine(provider:provider,llm:ai.provider,store:next);key=nextKey
        jobs=try await next.recentRuns();indexProgress=try await next.progress()
        scope=try await provider.hasArchiveFullText() ? "Built-in full-text search covers this archive" : "No built-in full-text index. Build the text index for whole-archive content search."
    }
    func load(browser:BrowserModel,ai:IntelligenceModel) async {
        do {try await connect(browser:browser,ai:ai)} catch {message=error.localizedDescription}
    }
    func select(_ job:ResearchRun) {
        guard !busy else {return};run=job;question=job.question;exhaustive=job.exhaustive
        let token=generation
        Task {if let store {let loaded=(try? await store.notes(job:job.id)) ?? [];if token == generation,run?.id == job.id {notes=loaded}}}
    }
    func stop() {researchTask?.cancel();message="Stopping and saving the current checkpoint…"}
    func start(browser:BrowserModel,ai:IntelligenceModel,resume:Bool=false) {
        guard !busy,!question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!ai.chatModel.isEmpty else {return}
        busy=true;message=nil;let token=generation,goal=question,model=ai.chatModel,batch=budget,mode=exhaustive
        researchTask=Task {
            defer {if token == generation {busy=false;poll?.cancel()}}
            do {
                try await connect(browser:browser,ai:ai);try Task.checkCancellation()
                guard token == generation,let store,let engine else {return}
                var selected:ResearchRun
                if resume,let previous=run {
                    guard previous.question == goal else {throw AIError.message("Use Research This Question to start a revised question; your previous notebook stays saved.")}
                    selected=previous;selected.model=model
                } else if let previous=run,previous.question != goal {selected=try await store.fork(previous,question:goal,model:model);selected.exhaustive=mode}
                else {selected=ResearchRun(question:goal,model:model,exhaustive:mode)}
                run=selected
                poll=Task {
                    while !Task.isCancelled {
                        if let snapshot=await engine.snapshot(),snapshot.id == selected.id,token == self.generation {self.run=snapshot;self.notes=(try? await store.notes(job:snapshot.id)) ?? []}
                        try? await Task.sleep(for:.milliseconds(500))
                    }
                }
                let finished=try await engine.execute(selected,budget:batch)
                guard token == generation else {return};run=finished
            } catch {
                if token == generation {message=error is CancellationError ? "Paused. Resume to continue from the saved queue." : error.localizedDescription;if let engine,let snapshot=await engine.snapshot() {run=snapshot}}
            }
            if token == generation,let store {jobs=(try? await store.recentRuns()) ?? [];if let run {notes=(try? await store.notes(job:run.id)) ?? []}}
        }
    }
    func buildIndex(browser:BrowserModel,ai:IntelligenceModel) {
        guard !indexing else {return};indexing=true;let token=generation
        indexTask=Task {
            defer {if token == generation {indexing=false}}
            do {
                try await connect(browser:browser,ai:ai)
                guard let store,let provider=browser.provider as? any ResearchArticleProvider else {return}
                let monitor=Task {while !Task.isCancelled {if token == self.generation {self.indexProgress=(try? await store.progress()) ?? .init()};try? await Task.sleep(for:.milliseconds(500))}}
                defer {monitor.cancel()}
                try await store.indexAll(provider:provider)
                if token == generation {indexProgress=try await store.progress()}
            } catch {if token == generation {message=error is CancellationError ? "Text indexing paused; resume continues at its checkpoint." : error.localizedDescription}}
        }
    }
    func pauseIndex() {indexTask?.cancel()}
}

struct ResearchView:View {
    @Bindable var research:ResearchModel
    @Bindable var ai:IntelligenceModel
    @Bindable var browser:BrowserModel
    var openSource:(RetrievedPassage)->Void
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("Research Sematrica").font(.system(size:32,weight:.medium,design:.serif))
                Text("Independent research across your open offline Wikipedia package. Saved evidence, resumable reading, and cited reports.").foregroundStyle(.secondary)
                GroupBox("Archive search") {
                    VStack(alignment:.leading,spacing:8) {
                        Text(research.scope)
                        Text("Text index: \(research.indexProgress.articles) articles · \(research.indexProgress.cursor)/\(research.indexProgress.total) archive entries examined · \(research.indexProgress.skipped) skipped").font(.caption)
                        if research.indexProgress.total>0 {ProgressView(value:Double(research.indexProgress.cursor),total:Double(research.indexProgress.total))}
                        HStack {
                            if research.indexing {Button("Pause Index",action:research.pauseIndex)}else{Button(research.indexProgress.complete ? "Index Complete" : "Build / Resume Text Index") {research.buildIndex(browser:browser,ai:ai)}.disabled(research.indexProgress.complete || browser.provider == nil)}
                            Text("No embedding model required. A full index can take substantial disk space and time.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
                }
                HStack {
                    Picker("Chat model",selection:$ai.chatModel) {Text("Choose model").tag("");ForEach(ai.chatModels) {Text($0.name).tag($0.name)}}
                    Button("Refresh Models") {Task {await ai.refreshModels()}}
                }.disabled(research.busy)
                TextField("Research question…",text:$research.question,axis:.vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(research.busy)
                HStack {
                    Stepper("Articles per batch: \(research.budget)",value:$research.budget,in:1...10000,step:10)
                    Toggle("Sequentially review every article",isOn:$research.exhaustive).toggleStyle(.checkbox)
                }.disabled(research.busy)
                Text(research.exhaustive ? "Sequential review is resumable across batches. It examines selected passages from each readable article, not every sentence. Failures are counted separately." : "Search broadly, then read relevant articles and follow offline links. This is selective research, not an exhaustive scan.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if research.busy {Button("Pause & Save",action:research.stop)}else {
                        Button(research.run.map {$0.question != research.question} == true ? "Research Revised Question" : "Research This Question") {research.start(browser:browser,ai:ai)}.buttonStyle(.borderedProminent).disabled(ai.chatModel.isEmpty || research.question.isEmpty || browser.provider == nil)
                        if research.run != nil {Button("Resume Saved Queue") {research.start(browser:browser,ai:ai,resume:true)}.disabled(ai.chatModel.isEmpty)}
                    }
                    Menu("Saved Research") {ForEach(research.jobs) {job in Button(job.question) {research.select(job)}}}.disabled(research.busy)
                }
                if let message=research.message {Text(message).foregroundStyle(.orange)}
                Text("To redirect: pause, revise the question, then choose Research Revised Question. Earlier evidence is retained in the new notebook.").font(.caption).foregroundStyle(.secondary)
                if let run=research.run {
                    Text(run.status).font(.headline)
                    Text(run.currentArticle).foregroundStyle(.secondary)
                    Text("\(run.readCount) articles read · \(run.failedCount) unavailable · \(run.passagesExamined) passages evaluated · \(run.noteCount) evidence notes · \(run.queue.count) queued").font(.caption)
                    Text(run.searchScope).font(.caption).foregroundStyle(.secondary)
                    if run.exhaustive {Text("Archive traversal: \(run.archiveCursor)/\(run.archiveTotal) entries enumerated; queued articles may not yet have been read.").font(.caption)}
                    DisclosureGroup("Research questions") {ForEach(Array(run.subquestions.enumerated()),id:\.offset) {_,text in Text("• "+text).frame(maxWidth:.infinity,alignment:.leading)}}
                    if !run.report.isEmpty {
                        Text("Research report").font(.title2)
                        Text(run.report).textSelection(.enabled)
                        Text("AI synthesis; quotations and citation IDs are validated, but that does not prove every interpretation. This report uses \(run.reportSources.count) selected evidence notes from \(run.noteCount) stored notes.").font(.caption).foregroundStyle(.secondary)
                        Button("Copy Report") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(run.question+"\n\n"+run.report+"\n\n"+run.reportSources.enumerated().map {"[\($0.offset+1)] \($0.element.source.title) — \($0.element.source.article.path)\n\($0.element.quote)"}.joined(separator:"\n\n"),forType:.string)}
                        ForEach(Array(run.reportSources.enumerated()),id:\.element.id) {i,note in
                            VStack(alignment:.leading) {Text("[\(i+1)] "+note.source.title).font(.headline);Text(note.quote).textSelection(.enabled);Button("Open / Highlight Source") {openSource(note.source)}}.padding(8)
                        }
                    }
                    DisclosureGroup("Open questions and disagreements") {ForEach(Array(run.gaps.enumerated()),id:\.offset) {_,text in Text("• "+text).frame(maxWidth:.infinity,alignment:.leading)}}
                    DisclosureGroup("Evidence notebook · latest 100 notes") {
                        ForEach(research.notes) {note in VStack(alignment:.leading,spacing:4) {Text(note.claim);Text(note.quote).font(.caption).foregroundStyle(.secondary);Button(note.source.title) {openSource(note.source)}}.padding(.vertical,6)}
                    }
                }
            }.padding(28).frame(maxWidth:1000,alignment:.leading)
        }
        .task {await ai.refreshModels();await research.load(browser:browser,ai:ai)}
        .onChange(of:ai.chatModel) {ai.saveSettings()}
        .onChange(of:browser.record?.id) {research.reset();Task {await research.load(browser:browser,ai:ai)}}
    }
}
