import Foundation

public enum FitRating:String,Codable,Sendable {
    case strong,medium,weak,unknown
    public var title:String {
        switch self {
        case .strong: "Strong fit"
        case .medium: "Medium fit"
        case .weak: "Weak fit"
        case .unknown: "Fit unknown"
        }
    }
    func lowered()->FitRating {self == .strong ? .medium : self == .medium ? .weak : self}
}

/// An instant estimate from what Ollama reports about the model.
public struct ModelFitEstimate:Codable,Sendable,Equatable {
    public let rating:FitRating
    public let summary:String
    public let reasons:[String]
}

/// The result of running real Atlas requests through a model.
public struct ModelFitReport:Codable,Sendable,Equatable {
    public let model:String
    public let digest:String
    public let rating:FitRating
    public let passed:Int
    public let total:Int
    public let averageSeconds:Double
    public let failures:[String]
    public let date:Date
    public var summary:String {
        let speed=String(format:"%.1f",averageSeconds)
        switch rating {
        case .strong: return "Understood \(passed) of \(total) test requests, about \(speed) s each."
        case .medium: return "Understood \(passed) of \(total) test requests, about \(speed) s each. Unusual or multi-step phrasing may need a retry."
        case .weak: return "Understood only \(passed) of \(total) test requests. Common requests still work without the model; others may be misunderstood."
        case .unknown: return "The test could not finish."
        }
    }
}

public struct ModelFitCase:Sendable {
    public let label:String
    public let request:String
    public let check:@Sendable (CompanionPlan)->Bool
}

public enum ModelFit {
    public static func estimate(_ profile:AIModelProfile)->ModelFitEstimate {
        var reasons:[String]=[]
        guard profile.capabilities.isEmpty || profile.capabilities.contains("completion") else {
            return .init(rating:.weak,summary:"This model can't chat, so the companion can't use it.",reasons:["No chat (completion) capability"])
        }
        var rating:FitRating
        if let parameters=profile.parameters {
            let size=parameters>=1 ? String(format:"%.1fB",parameters) : String(format:"%.0fM",parameters*1000)
            if parameters>=14 {rating = .strong;reasons.append("\(size) parameters: large enough to follow Atlas's instructions closely")}
            else if parameters>=7 {rating = .medium;reasons.append("\(size) parameters: follows most instructions; rare phrasing may need a retry")}
            else {rating = .weak;reasons.append("\(size) parameters: small models often misread multi-part requests")}
        } else {
            rating = .unknown;reasons.append("Size not reported; run the fit test")
        }
        if let context=profile.contextLength {
            if context<8192 {rating=rating.lowered();reasons.append("\(context)-token context window is shorter than Atlas uses (8,192)")}
            else {reasons.append("\(context/1024)K-token context window")}
        }
        if let quantization=profile.quantization {
            let q=quantization.uppercased()
            if q.hasPrefix("Q2") || q.hasPrefix("Q3") || q.hasPrefix("IQ1") || q.hasPrefix("IQ2") {rating=rating.lowered();reasons.append("\(quantization) compression reduces accuracy")}
            else {reasons.append("\(quantization) quantization")}
        }
        let summary:String
        switch rating {
        case .strong: summary="Should understand nearly every request reliably."
        case .medium: summary="Handles most requests. Unusual or multi-step phrasing may need a retry; common requests run instantly without the model."
        case .weak: summary="Expect misunderstandings. Common requests still run instantly without the model."
        case .unknown: summary="Run the fit test to measure this model."
        }
        return .init(rating:rating,summary:summary,reasons:reasons)
    }

    static func rate(passed:Int,total:Int,averageSeconds:Double)->FitRating {
        guard total>0 else {return .unknown}
        let share=Double(passed)/Double(total)
        if share>=0.9 {return averageSeconds<=10 ? .strong : .medium}
        if share>=0.65 {return .medium}
        return .weak
    }

    /// A small fixed article so results are comparable between models.
    public static let fixture=CompanionPromptContext(
        title:"Ray Charles",
        sections:["introduction","Early life","Career","Legacy"],
        stats:"42 text blocks, 310 links, 6 images",
        opening:"[b1] § introduction\nRay Charles Robinson (September 23, 1930 – June 10, 2004) was an American singer, songwriter and pianist. He was often called “The Genius”.\n\n[b2] § introduction\nCharles was blind from the age of seven. He pioneered soul music during the 1950s by combining blues, jazz, rhythm and blues, and gospel styles.",
        coverage:"Selected excerpts; Atlas's page tools still inspect the whole page.",
        state:"idle; speed normal; links allowed")

    static func lower(_ value:String?)->String {(value ?? "").lowercased()}

    public static let cases:[ModelFitCase]=[
        .init(label:"Green adjectives ending in w",request:"Could you put a green glow on every adjective that finishes with the letter w?") {plan in
            guard let step=plan.steps.first,step.action == "highlight",let q=step.query else {return false}
            return q.partOfSpeech == "adjective" && ModelFit.lower(q.endsWith) == "w" && ModelFit.lower(step.color).contains("green")
        },
        .init(label:"Count full stops",request:"In this article, what's the tally of full stops?") {plan in
            guard let step=plan.steps.first,step.action == "count",let q=step.query else {return false}
            return q.unit == "character" && q.equals == "."
        },
        .init(label:"Words from a to r",request:"Mark every term kicking off with 'a' and wrapping up with 'r'") {plan in
            guard let step=plan.steps.first,step.action == "highlight",let q=step.query else {return false}
            return q.unit == "word" && ModelFit.lower(q.startsWith) == "a" && ModelFit.lower(q.endsWith) == "r"
        },
        .init(label:"Count links",request:"How many hyperlinks are sitting on this page?") {plan in
            plan.steps.first?.action == "count" && plan.steps.first?.query?.unit == "link"
        },
        .init(label:"Count capital letters",request:"Can you work out how many uppercase letters there are?") {plan in
            guard let step=plan.steps.first,step.action == "count",let q=step.query else {return false}
            return q.unit == "letter" && q.letterCase == "uppercase"
        },
        .init(label:"Two-color verbs",request:"Paint the verbs half green, half yellow") {plan in
            guard let step=plan.steps.first,step.action == "highlight",step.query?.partOfSpeech == "verb" else {return false}
            return ModelFit.lower(step.color).contains("green") && ModelFit.lower(step.color).contains("yellow")
        },
        .init(label:"Walk to a section",request:"Wander over to the Career part, please") {plan in
            plan.steps.first?.action == "go" && ModelFit.lower(plan.steps.first?.place).contains("career")
        },
        .init(label:"Small talk",request:"Hey, how's your day going?") {plan in
            plan.steps.isEmpty && !(plan.reply ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        },
        .init(label:"Third longest word",request:"Bring me over to the third longest word") {plan in
            guard let step=plan.steps.first,step.action == "goto",let q=step.query else {return false}
            return q.order == "longest" && q.rank == 3
        },
        .init(label:"Open an article",request:"Pop open the article on Paris") {plan in
            plan.steps.first?.action == "open" && ModelFit.lower(plan.steps.first?.title).contains("paris")
        },
        .init(label:"Clear highlights",request:"Wipe all the highlighting off") {plan in
            plan.steps.count == 1 && plan.steps.first?.action == "clear" && plan.steps.first?.target == nil
        },
        .init(label:"Longest sentence",request:"Which sentence in the article is the longest one?") {plan in
            guard let step=plan.steps.first,["list","goto","highlight"].contains(step.action),let q=step.query else {return false}
            return q.unit == "sentence" && q.order == "longest"
        }
    ]

    public static func run(provider:any LLMProvider,model:String,digest:String,progress:@Sendable (Int,Int)->Void={_,_ in}) async throws -> ModelFitReport {
        var passed=0,seconds=0.0,failures:[String]=[]
        for (index,test) in cases.enumerated() {
            try Task.checkCancellation()
            progress(index,cases.count)
            let began=Date()
            do {
                let result=try await CompanionPlanner.plan(request:test.request,context:fixture,history:[],provider:provider,model:model)
                if test.check(result.plan) {passed += 1} else {failures.append(test.label)}
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(test.label+" (error)")
            }
            seconds += Date().timeIntervalSince(began)
        }
        progress(cases.count,cases.count)
        let average=seconds/Double(max(1,cases.count))
        return .init(model:model,digest:digest,rating:rate(passed:passed,total:cases.count,averageSeconds:average),passed:passed,total:cases.count,averageSeconds:average,failures:failures,date:Date())
    }
}
