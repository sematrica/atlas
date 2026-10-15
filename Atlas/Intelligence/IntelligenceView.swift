import SwiftUI
import AtlasCore

struct IntelligenceView:View {
    @Bindable var ai:IntelligenceModel
    @Bindable var browser:BrowserModel
    var openSource:(RetrievedPassage)->Void
    var explore:(String)->Void
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Text("Ask Sematrica").font(.system(size:32,weight:.medium,design:.serif))
                Text("Answers from your offline library, with passages you can inspect.").foregroundStyle(.secondary)
                GroupBox("Local intelligence") {
                    VStack(alignment:.leading,spacing:10) {
                        Text(ai.connection).font(.caption)
                        HStack {
                            Picker("Chat model",selection:$ai.chatModel) {Text("Choose model").tag("");ForEach(ai.chatModels) {Text($0.name).tag($0.name)}}
                            Button("Refresh Models") {Task {await ai.refreshModels()}}
                            Button("Test Model") {Task {await ai.testModel()}}.disabled(ai.chatModel.isEmpty)
                        }
                        CompanionFitRow(ai:ai)
                        Picker("Embedding model",selection:$ai.embeddingModel) {Text("Choose model").tag("");ForEach(ai.embeddingModels) {Text($0.name).tag($0.name)}}
                        Text("Provider: Ollama · Local models only. Chat models write answers; embedding models prepare AI Search. Only compatible installed models are shown.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("AI Search Index · current package") {
                    VStack(alignment:.leading,spacing:10) {
                        Text("Add articles incrementally. Answers cover indexed content; the whole encyclopedia is not indexed automatically.").font(.callout)
                        HStack {
                            Button("Index Current Article") {if let article=browser.currentArticleID {ai.build(browser:browser,articles:[article])}}
                            Button("Index Title Search Results (\(browser.results.count))") {ai.build(browser:browser,articles:browser.results.map(\.articleID))}
                        }.disabled(ai.building || ai.preparingIndex || browser.provider == nil || ai.embeddingModel.isEmpty)
                        ProgressView(value:ai.progress.fraction)
                        Text("\(ai.progress.state) · \(ai.progress.completed.count)/\(ai.progress.queue.count) articles · \(ai.progress.chunks) chunks · \(Int(ai.progress.fraction*100))% · \(ByteCountFormatter.string(fromByteCount:ai.progress.bytes,countStyle:.file))").font(.caption)
                        Text("Elapsed \(Int(ai.progress.elapsed))s" + (ai.progress.remaining.map {" · Estimated remaining \(Int($0))s"} ?? "")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if ai.building || ai.preparingIndex {Button("Pause",action:ai.pauseIndex)}else{Button("Resume") {ai.build(browser:browser,articles:[])}}
                            Button("Cancel Pending",action:ai.cancelIndex)
                        }
                    }.padding(8)
                }
                HStack(alignment:.top) {
                    TextField("Ask a question or follow up…",text:$ai.question,axis:.vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).onSubmit {ai.ask(browser:browser)}
                    if ai.answering {Button("Stop",action:ai.stopAnswer)}else{Button("Ask") {ai.ask(browser:browser)}.buttonStyle(.borderedProminent).disabled(ai.chatModel.isEmpty || ai.embeddingModel.isEmpty || ai.progress.chunks == 0)}
                }
                if ai.progress.chunks == 0 {Text("Index an article before asking. For broader questions, search relevant article titles and index those results.").font(.callout).foregroundStyle(.secondary)}
                if let message=ai.message {Text(message).foregroundStyle(.orange)}
                if !ai.answer.isEmpty {
                    Text(ai.lastQuestion).font(.headline)
                    Text(ai.answer).textSelection(.enabled).lineSpacing(5)
                    if ai.answering {Text("Draft · generating locally").font(.caption).foregroundStyle(.secondary)}
                    Button("Explore This",systemImage:"point.3.connected.trianglepath.dotted") {explore(ai.lastQuestion)}.disabled(ai.answering)
                }
                ForEach(Array(ai.evidence.enumerated()),id:\.element.id) {number,passage in
                    GroupBox {
                        VStack(alignment:.leading,spacing:8) {
                            Text("[\(number+1)] \(passage.title)").font(.headline)
                            Text(passage.section.joined(separator:" › ")).font(.caption).foregroundStyle(.secondary)
                            Text(passage.text).font(.callout).textSelection(.enabled)
                            Button("Open Local Source") {openSource(passage)}
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
                    }
                }
            }.padding(28).frame(maxWidth:950)
        }
        .task {await ai.refreshModels();await ai.evaluateFit();await ai.loadIndex(browser.record)}
        .onChange(of:ai.chatModel) {ai.saveSettings();browser.crawler.intelligence.model=ai.chatModel;Task {await ai.evaluateFit()}}
        .onChange(of:ai.embeddingModel) {ai.saveSettings();Task {await ai.loadIndex(browser.record)}}
    }
}

/// How well the chat model suits the reading companion: an instant estimate and a measured test.
private struct CompanionFitRow:View {
    @Bindable var ai:IntelligenceModel
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:8) {
                Text("Companion fit").font(.callout)
                if let report=ai.fitReport {
                    FitBadge(fit:.init(rating:report.rating,summary:report.summary,measured:true))
                    Text(report.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if let estimate=ai.fitEstimate {
                    FitBadge(fit:.init(rating:estimate.rating,summary:estimate.summary,measured:false))
                    Text(estimate.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(ai.chatModel.isEmpty ? "Choose a chat model." : "Not measured yet.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if ai.fitTesting {
                    ProgressView(value:ai.fitProgress).frame(width:110)
                    Button("Cancel",action:ai.cancelFitTest)
                } else {
                    Button("Run Fit Test",action:ai.runFitTest).disabled(ai.chatModel.isEmpty).help("Tries 12 real companion requests and measures accuracy and speed (about a minute)")
                }
            }
            if let estimate=ai.fitEstimate,ai.fitReport == nil {
                Text(estimate.reasons.joined(separator:" · ")).font(.caption2).foregroundStyle(.secondary)
            }
            if let report=ai.fitReport,!report.failures.isEmpty {
                Text("Misunderstood: "+report.failures.joined(separator:", ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
