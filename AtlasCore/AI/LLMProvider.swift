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
/// What Ollama reports about an installed model, used by the model-fit meter.
public struct AIModelProfile: Codable, Sendable, Equatable {
    public let name:String
    public let digest:String
    /// Billions of parameters, when the model reports it ("8.0B" → 8.0).
    public let parameters:Double?
    public let family:String?
    public let quantization:String?
    public let contextLength:Int?
    public let capabilities:[String]
    public init(name:String,digest:String,parameters:Double?,family:String?,quantization:String?,contextLength:Int?,capabilities:[String]) {
        self.name=name;self.digest=digest;self.parameters=parameters;self.family=family
        self.quantization=quantization;self.contextLength=contextLength;self.capabilities=capabilities
    }
    /// "8.0B" → 8.0, "567M" → 0.567.
    public static func parameterCount(_ text:String?)->Double? {
        guard let text=text?.trimmingCharacters(in:.whitespaces).uppercased(),let unit=text.last else {return nil}
        guard unit.isLetter else {return Double(text).map {$0/1e9}}
        guard let value=Double(text.dropLast()) else {return nil}
        switch unit {
        case "B": return value
        case "M": return value/1000
        case "K": return value/1_000_000
        case "T": return value*1000
        default: return nil
        }
    }
}
public struct AIMessage: Codable, Sendable, Equatable {
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
/// How the model's reply is constrained.
public enum AIResponseFormat: Sendable, Equatable {
    case text
    /// Any JSON object.
    case json
    /// A JSON schema (serialized with its key order) that constrains decoding.
    case schema(String)
}
public struct AIChatOptions: Sendable, Equatable {
    public var temperature:Double
    /// Upper bound on generated tokens.
    public var maxTokens:Int
    public init(temperature:Double=0.1,maxTokens:Int=900) {self.temperature=temperature;self.maxTokens=maxTokens}
}
public protocol LLMProvider: Sendable {
    func models() async throws -> [AIModel]
    func validate(model:String) async throws -> AIModel
    func chat(model:String,messages:[AIMessage],json:Bool) -> AsyncThrowingStream<String,Error>
    func chat(model:String,messages:[AIMessage],format:AIResponseFormat,options:AIChatOptions) -> AsyncThrowingStream<String,Error>
}
public extension LLMProvider {
    /// Providers without schema support (test fixtures) treat a schema as plain JSON mode.
    func chat(model:String,messages:[AIMessage],format:AIResponseFormat,options:AIChatOptions) -> AsyncThrowingStream<String,Error> {
        chat(model:model,messages:messages,json:format != .text)
    }
    func generate(model:String,prompt:String,json:Bool=false) async throws -> String {
        var answer=""
        for try await part in chat(model:model,messages:[AIMessage("user",prompt)],json:json) {answer += part}
        return answer
    }
    /// Collects a whole reply, checking for cancellation and a size limit.
    func complete(model:String,messages:[AIMessage],format:AIResponseFormat = .text,options:AIChatOptions=AIChatOptions(),limit:Int=24_000) async throws -> String {
        var answer=""
        for try await part in chat(model:model,messages:messages,format:format,options:options) {
            try Task.checkCancellation()
            answer += part
            guard answer.count<limit else {throw AIError.message("The model's reply exceeded the response limit. Please retry.")}
        }
        return answer
    }
}
public protocol EmbeddingProvider: Sendable {
    func embed(model:String,texts:[String]) async throws -> [[Float]]
}
