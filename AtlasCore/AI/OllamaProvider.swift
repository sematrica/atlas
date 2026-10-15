import Foundation

/// Only a fixed loopback endpoint; no credentials, proxies, redirects or cloud models.
public final class OllamaProvider: NSObject, LLMProvider, EmbeddingProvider, URLSessionTaskDelegate, @unchecked Sendable {
    private let base:URL
    private lazy var session:URLSession = {
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=180;config.timeoutIntervalForResource=600
        config.connectionProxyDictionary=[:];config.urlCache=nil
        return URLSession(configuration:config,delegate:self,delegateQueue:nil)
    }()
    /// Validated models are re-checked at most every few minutes instead of before every request.
    private let lock=NSLock()
    private var validated:[String:(model:AIModel,date:Date)]=[:]
    private var schemaUnsupported=false
    /// NSLock may not be called directly from async code; this synchronous helper may.
    private func locked<T>(_ body:()->T)->T {lock.lock();defer {lock.unlock()};return body()}
    /// One context size for every chat request. Changing `num_ctx` between
    /// requests makes Ollama reload the model, which costs seconds each time.
    public static let contextTokens=8192
    /// Keeps the model in memory between companion messages.
    public static let keepAlive="30m"

    public init(port:Int=11434) {base=URL(string:"http://127.0.0.1:\(port)/api/")!;super.init();_ = session}
    public func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {completionHandler(nil)}
    private func request(_ path:String,_ body:[String:Any]?=nil,rawFields:[(String,String)]=[]) throws -> URLRequest {
        var request=URLRequest(url:base.appendingPathComponent(path))
        if let body {
            request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            var data=try JSONSerialization.data(withJSONObject:body)
            // Raw JSON (an ordered schema) is spliced in so its key order survives.
            if !rawFields.isEmpty,var text=String(data:data,encoding:.utf8),text.hasSuffix("}") {
                text.removeLast()
                for (key,value) in rawFields {text += ",\""+key+"\":"+value}
                text += "}"
                data=Data(text.utf8)
            }
            request.httpBody=data
        }
        return request
    }
    private func object(_ path:String,_ body:[String:Any]?=nil) async throws -> [String:Any] {
        do {
            let (data,response)=try await session.data(for:request(path,body))
            return try Self.decodeResponse(data,status:(response as? HTTPURLResponse)?.statusCode ?? 0,operation:path)
        } catch let error as URLError {
            if error.code == .cancelled {throw CancellationError()}
            if error.code == .timedOut {throw AIError.message("Local inference timed out. Try a smaller model or shorter request.")}
            throw AIError.unavailable
        }
    }
    static func decodeResponse(_ data:Data,status:Int,operation:String) throws -> [String:Any] {
        guard data.count<16*1024*1024,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw AIError.invalidResponse}
        if let error=object["error"] as? String {
            if operation == "embed",error.lowercased().contains("support") {
                throw AIError.message("This model cannot create the AI Search Index. Select a dedicated embedding model, such as nomic-embed-text, then index your articles again. Your chat model can stay unchanged.")
            }
            throw AIError.message("Ollama: " + String(error.prefix(350)))
        }
        guard status == 200 else {throw AIError.message("Ollama request failed (HTTP \(status)). Refresh Models and try again.")}
        return object
    }
    public func models() async throws -> [AIModel] {
        let obj=try await object("tags")
        guard let rows=obj["models"] as? [[String:Any]] else {throw AIError.invalidResponse}
        var result:[AIModel]=[]
        for row in rows {
            guard let name=row["name"] as? String,let digest=row["digest"] as? String,!name.contains(":cloud"),row["remote_model"] == nil else {continue}
            var capabilities=row["capabilities"] as? [String]
            if capabilities == nil {capabilities=try await object("show",["model":name])["capabilities"] as? [String]}
            result.append(AIModel(name:name,digest:digest,capabilities:capabilities ?? []))
        }
        return result
    }
    public func validate(model:String) async throws -> AIModel {
        let tags=try await object("tags")
        guard let rows=tags["models"] as? [[String:Any]],
              let row=rows.first(where:{$0["name"] as? String == model}),
              let digest=row["digest"] as? String,!model.contains(":cloud"),
              row["remote_model"] == nil,row["remote_host"] == nil else {throw AIError.unsafeModel}
        let info=try await object("show",["model":model])
        guard info["remote_model"] == nil,info["remote_host"] == nil,
              let metadata=info["model_info"] as? [String:Any],metadata["general.architecture"] != nil else {throw AIError.unsafeModel}
        let result=AIModel(name:model,digest:digest,capabilities:info["capabilities"] as? [String] ?? row["capabilities"] as? [String] ?? [])
        locked {validated[model]=(result,Date())}
        return result
    }
    /// The safety check stays (local models only), but a recent result is reused.
    private func validatedModel(_ model:String) async throws -> AIModel {
        let cached=locked {validated[model]}
        if let cached,Date().timeIntervalSince(cached.date)<600 {return cached.model}
        return try await validate(model:model)
    }
    /// Size, family, quantization and context window of an installed model.
    public func profile(model:String) async throws -> AIModelProfile {
        let checked=try await validatedModel(model)
        let info=try await object("show",["model":model])
        let details=info["details"] as? [String:Any] ?? [:]
        let metadata=info["model_info"] as? [String:Any] ?? [:]
        let architecture=metadata["general.architecture"] as? String
        var context:Int?
        if let architecture {context=(metadata[architecture+".context_length"] as? NSNumber)?.intValue}
        var parameters=AIModelProfile.parameterCount(details["parameter_size"] as? String)
        if parameters == nil,let count=(metadata["general.parameter_count"] as? NSNumber)?.doubleValue {parameters=count/1e9}
        return AIModelProfile(name:model,digest:checked.digest,parameters:parameters,family:(details["family"] as? String) ?? architecture,
                              quantization:details["quantization_level"] as? String,contextLength:context,capabilities:checked.capabilities)
    }

    public func chat(model:String,messages:[AIMessage],json:Bool=false)->AsyncThrowingStream<String,Error> {
        chat(model:model,messages:messages,format:json ? .json : .text,options:AIChatOptions())
    }

    public func chat(model:String,messages:[AIMessage],format:AIResponseFormat,options:AIChatOptions)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream { continuation in
            let task=Task {
                do {
                    let checked=try await self.validatedModel(model)
                    let thinking=checked.capabilities.contains("thinking")
                    var effective=format
                    let noSchema=self.locked {self.schemaUnsupported}
                    if case .schema=effective,noSchema {effective = .json}
                    do {
                        try await self.stream(model:model,messages:messages,format:effective,options:options,thinking:thinking,continuation:continuation)
                    } catch OllamaStreamError.formatRejected(let detail) {
                        // Ollama before 0.5 accepts only "json". Remember and retry without the schema.
                        guard case .schema=effective else {throw AIError.message("Ollama: "+detail)}
                        self.locked {self.schemaUnsupported=true}
                        try await self.stream(model:model,messages:messages,format:.json,options:options,thinking:thinking,continuation:continuation)
                    }
                    continuation.finish()
                } catch {continuation.finish(throwing:error)}
            }
            continuation.onTermination={_ in task.cancel()}
        }
    }

    private enum OllamaStreamError:Error {case formatRejected(String)}

    /// - Parameter thinking: the model reasons before answering by default (Qwen3, gpt-oss…).
    ///   Atlas asks for the answer directly: thinking adds seconds to every message.
    private func stream(model:String,messages:[AIMessage],format:AIResponseFormat,options:AIChatOptions,thinking:Bool,continuation:AsyncThrowingStream<String,Error>.Continuation) async throws {
        var body:[String:Any]=[
            "model":model,
            "messages":messages.map {["role":$0.role,"content":$0.content]},
            "stream":true,
            "keep_alive":Self.keepAlive,
            "options":["temperature":options.temperature,"num_ctx":Self.contextTokens,"num_predict":options.maxTokens]
        ]
        // gpt-oss can't switch reasoning off, only down to "low".
        if thinking {body["think"]=model.lowercased().contains("gpt-oss") ? "low" : false}
        var raw:[(String,String)]=[]
        switch format {
        case .text: break
        case .json: raw.append(("format","\"json\""))
        case .schema(let schema): raw.append(("format",schema))
        }
        let request=try self.request("chat",body,rawFields:raw)
        let (bytes,response):(URLSession.AsyncBytes,URLResponse)
        do {(bytes,response)=try await session.bytes(for:request)}
        catch let error as URLError {
            if error.code == .cancelled {throw CancellationError()}
            if error.code == .timedOut {throw AIError.message("Local inference timed out. Try a smaller model or a shorter request.")}
            throw AIError.unavailable
        }
        let status=(response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var text=""
            for try await line in bytes.lines {text += line;if text.count>2000 {break}}
            let detail=((try? JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])?["error"] as? String) ?? "HTTP \(status)"
            if case .schema=format,status == 400 || status == 500,detail.lowercased().contains("format") || detail.lowercased().contains("schema") || detail.lowercased().contains("grammar") || detail.lowercased().contains("json") {
                throw OllamaStreamError.formatRejected(detail)
            }
            throw AIError.message("Ollama: "+String(detail.prefix(350)))
        }
        var completed=false,total=0
        for try await line in bytes.lines {
            try Task.checkCancellation();total += line.utf8.count
            guard total<2*1024*1024 else {throw AIError.invalidResponse}
            guard !line.isEmpty else {continue}
            guard let row=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else {throw AIError.invalidResponse}
            if let error=row["error"] as? String {throw AIError.message("Ollama: "+String(error.prefix(350)))}
            if let message=row["message"] as? [String:Any],let text=message["content"] as? String {continuation.yield(text)}
            if row["done"] as? Bool == true {completed=true;break}
        }
        guard completed else {throw AIError.invalidResponse}
    }

    public func embeddingModel(_ name:String) async throws -> AIModel {
        let model=try await validatedModel(name)
        guard model.supportsEmbedding else {throw AIError.message("\(name) is a chat model, not an embedding model. Choose an installed embedding model to build AI Search; keep your chat model for answers.")}
        return model
    }
    public func embed(model:String,texts:[String]) async throws -> [[Float]] {
        _ = try await embeddingModel(model)
        let obj=try await object("embed",["model":model,"input":texts,"truncate":false])
        guard let rows=obj["embeddings"] as? [[Double]],rows.count == texts.count,
              let dimension=rows.first?.count,dimension>0,dimension<=16384,
              rows.allSatisfy({$0.count == dimension && $0.allSatisfy(\.isFinite)}) else {throw AIError.invalidResponse}
        return rows.map {$0.map(Float.init)}
    }
}
