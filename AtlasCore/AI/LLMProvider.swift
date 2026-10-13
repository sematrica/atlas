import Foundation

public struct AIModel: Codable, Sendable, Identifiable {
    public let name:String
    public let digest:String
    public let capabilities:[String]
    public var id:String {name}
    public var supportsEmbedding:Bool {capabilities.contains("embedding")}
    public var supportsChat:Bool {capabilities.contains("completion")}
    public init(name:String,digest:String,capabilities:[String]=[]) {self.name=name;self.digest=digest;self.capabilities=capabilities}
}
public struct AIMessage: Codable, Sendable {
    public let role:String
    public let content:String
    public init(_ role:String,_ content:String) {self.role=role;self.content=content}
}
public enum AIError: LocalizedError {
    case unavailable, unsafeModel, invalidResponse, message(String), staleIndex, noEvidence
    public var errorDescription:String? {
        switch self {
        case .unavailable: "Ollama is unavailable. Install or start Ollama, then Refresh Models."
        case .unsafeModel: "Choose an installed local model. Cloud-backed models are not supported."
        case .invalidResponse: "The local model returned an invalid response. Try another model."
        case .message(let text): text
        case .staleIndex: "This index uses a different package or embedding model revision. Select the original model or build a new index."
        case .noEvidence: "I couldn't find enough evidence in the indexed Wikipedia articles. Add relevant articles to AI Search."
        }
    }
}
public protocol LLMProvider: Sendable {
    func models() async throws -> [AIModel]
    func validate(model:String) async throws -> AIModel
    func chat(model:String,messages:[AIMessage],json:Bool) -> AsyncThrowingStream<String,Error>
}
public extension LLMProvider {
    func generate(model:String,prompt:String,json:Bool=false) async throws -> String {
        var answer=""
        for try await part in chat(model:model,messages:[AIMessage("user",prompt)],json:json) {answer += part}
        return answer
    }
}
public protocol EmbeddingProvider: Sendable {
    func embed(model:String,texts:[String]) async throws -> [[Float]]
}

/// Only a fixed loopback endpoint; no credentials, proxies, redirects or cloud models.
public final class OllamaProvider: NSObject, LLMProvider, EmbeddingProvider, URLSessionTaskDelegate, @unchecked Sendable {
    private let base:URL
    private lazy var session:URLSession = {
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=120;config.timeoutIntervalForResource=300
        config.connectionProxyDictionary=[:];config.urlCache=nil
        return URLSession(configuration:config,delegate:self,delegateQueue:nil)
    }()
    public init(port:Int=11434) {base=URL(string:"http://127.0.0.1:\(port)/api/")!;super.init();_ = session}
    public func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {completionHandler(nil)}
    private func request(_ path:String,_ body:[String:Any]?=nil) throws -> URLRequest {
        var request=URLRequest(url:base.appendingPathComponent(path))
        if let body {request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONSerialization.data(withJSONObject:body)}
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
        // Inference validates only the selected model. Enumerating capabilities of every
        // installed model makes a greeting depend on unrelated /show requests.
        let tags=try await object("tags")
        guard let rows=tags["models"] as? [[String:Any]],
              let row=rows.first(where:{$0["name"] as? String == model}),
              let digest=row["digest"] as? String,!model.contains(":cloud"),
              row["remote_model"] == nil,row["remote_host"] == nil else {throw AIError.unsafeModel}
        let info=try await object("show",["model":model])
        guard info["remote_model"] == nil,info["remote_host"] == nil,
              let metadata=info["model_info"] as? [String:Any],metadata["general.architecture"] != nil else {throw AIError.unsafeModel}
        return AIModel(name:model,digest:digest,capabilities:info["capabilities"] as? [String] ?? row["capabilities"] as? [String] ?? [])
    }
    public func chat(model:String,messages:[AIMessage],json:Bool=false)->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream { continuation in
            let task=Task {
                do {
                    _ = try await self.validate(model:model)
                    let contextSize=messages.reduce(0) {$0+$1.content.utf8.count}>8000 ? 8192 : 4096
                    var body:[String:Any] = ["model":model,"messages":messages.map {["role":$0.role,"content":$0.content]},"stream":true,"options":["temperature":0.1,"num_ctx":contextSize,"num_predict":900]]
                    if json {body["format"]="json"}
                    let (bytes,response)=try await self.session.bytes(for:self.request("chat",body))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {throw AIError.invalidResponse}
                    var completed=false,total=0
                    for try await line in bytes.lines {
                        try Task.checkCancellation();total += line.utf8.count
                        guard total<2*1024*1024 else {throw AIError.invalidResponse}
                        guard !line.isEmpty else {continue}
                        guard let row=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],row["error"] == nil else {throw AIError.invalidResponse}
                        if let message=row["message"] as? [String:Any],let text=message["content"] as? String {continuation.yield(text)}
                        if row["done"] as? Bool == true {completed=true;break}
                    }
                    guard completed else {throw AIError.invalidResponse};continuation.finish()
                } catch {continuation.finish(throwing:error)}
            }
            continuation.onTermination={_ in task.cancel()}
        }
    }
    public func embeddingModel(_ name:String) async throws -> AIModel {
        let model=try await validate(model:name)
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
