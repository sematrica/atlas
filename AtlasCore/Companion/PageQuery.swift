import Foundation

/// A composable description of what to look for in the rendered article.
///
/// The language model (or `CompanionLocalParser`) only fills this in. The
/// query is executed deterministically by `PageQueryEngine` over the complete
/// page map, so counts and highlights never depend on a model's arithmetic.
/// Every field is optional; omitted conditions do not constrain the result.
public struct PageQuery: Codable, Sendable, Equatable {
    /// word, letter, character, number, sentence, paragraph, heading, link, image, name, phrase
    public var unit: String?
    /// Text conditions. Case-insensitive unless `caseSensitive` is true.
    /// Alternatives may be separated by "|" ("a|e" means starts with a or e).
    public var startsWith: String?
    public var endsWith: String?
    public var contains: String?
    public var equals: String?
    public var notStartsWith: String?
    public var notEndsWith: String?
    public var notContains: String?
    /// Exact spellings to leave out.
    public var exclude: [String]?
    /// noun, verb, adjective, adverb, pronoun, determiner, preposition, conjunction, interjection
    public var partOfSpeech: String?
    /// person, place, organization
    public var entity: String?
    /// uppercase, lowercase, capitalized
    public var letterCase: String?
    /// letter, digit, punctuation, symbol, space, whitespace, vowel, consonant, quote, bracket, dash
    public var characterClass: String?
    /// Letters for words and names, characters for everything else.
    public var minLength: Int?
    public var maxLength: Int?
    public var length: Int?
    /// Word counts for sentences, paragraphs, headings and links.
    public var minWords: Int?
    public var maxWords: Int?
    public var section: String?
    public var excludeSections: [String]?
    public var distinct: Bool?
    public var caseSensitive: Bool?
    /// first, last, longest, shortest, frequent, rare
    public var order: String?
    public var rank: Int?
    public var limit: Int?
    /// A semantic condition judged by the language model, e.g. "related to music".
    public var meaning: String?
    /// Links only: the title of the article the link points to ("Paris").
    public var linksTo: String?

    public init(unit:String?=nil) {self.unit=unit}

    enum CodingKeys:String,CodingKey {
        case unit,startsWith,endsWith,contains,equals,notStartsWith,notEndsWith,notContains,exclude
        case partOfSpeech,entity,letterCase,characterClass,minLength,maxLength,length,minWords,maxWords
        case section,excludeSections,distinct,caseSensitive,order,rank,limit,meaning,linksTo
    }

    /// Small local models sometimes return numbers as strings, a single string
    /// instead of a list, or empty strings for fields they mean to omit.
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        unit=c.lenientString(.unit)
        startsWith=c.lenientString(.startsWith,trim:false)
        endsWith=c.lenientString(.endsWith,trim:false)
        contains=c.lenientString(.contains,trim:false)
        equals=c.lenientString(.equals,trim:false)
        notStartsWith=c.lenientString(.notStartsWith,trim:false)
        notEndsWith=c.lenientString(.notEndsWith,trim:false)
        notContains=c.lenientString(.notContains,trim:false)
        exclude=c.lenientStrings(.exclude)
        partOfSpeech=c.lenientString(.partOfSpeech)
        entity=c.lenientString(.entity)
        letterCase=c.lenientString(.letterCase)
        characterClass=c.lenientString(.characterClass)
        minLength=c.lenientInt(.minLength)
        maxLength=c.lenientInt(.maxLength)
        length=c.lenientInt(.length)
        minWords=c.lenientInt(.minWords)
        maxWords=c.lenientInt(.maxWords)
        section=c.lenientString(.section)
        excludeSections=c.lenientStrings(.excludeSections)
        distinct=c.lenientBool(.distinct)
        caseSensitive=c.lenientBool(.caseSensitive)
        order=c.lenientString(.order)
        rank=c.lenientInt(.rank)
        limit=c.lenientInt(.limit)
        meaning=c.lenientString(.meaning)
        linksTo=c.lenientString(.linksTo)
    }

    public static let units=["word","letter","character","number","sentence","paragraph","heading","link","image","name","phrase"]
    public static let partsOfSpeech=["noun","verb","adjective","adverb","pronoun","determiner","preposition","conjunction","interjection"]
    public static let entities=["person","place","organization"]
    public static let letterCases=["uppercase","lowercase","capitalized"]
    public static let characterClasses=["letter","digit","punctuation","symbol","space","whitespace","vowel","consonant","quote","bracket","dash"]
    public static let orders=["first","last","longest","shortest","frequent","rare"]

    public var isWordLike:Bool {unit == "word" || unit == "name"}
    public var isCharacterUnit:Bool {unit == "letter" || unit == "character"}
}

// MARK: - Normalization

extension PageQuery {
    static func fold(_ value:String)->String {
        value.lowercased()
            .replacingOccurrences(of:"_",with:" ")
            .replacingOccurrences(of:"-",with:" ")
            .split(whereSeparator:\.isWhitespace).joined(separator:" ")
    }

    /// Maps the many ways a model or person can name a target onto the
    /// executable vocabulary. Unknown values are kept so validation can explain them.
    public func normalized()->PageQuery {
        var q=self
        for key in [\PageQuery.startsWith,\.endsWith,\.contains,\.equals,\.notStartsWith,\.notEndsWith,\.notContains,\.section,\.meaning,\.linksTo] {
            if let value=q[keyPath:key],value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {q[keyPath:key]=nil}
        }
        if let value=q.linksTo {q.linksTo=Self.stripQuotes(value.trimmingCharacters(in:.whitespacesAndNewlines));if q.unit == nil {q.unit="link"}}
        // Quotes a model copies from the request ("'a'") are not part of the spelling.
        for key in [\PageQuery.startsWith,\.endsWith,\.contains,\.equals,\.notStartsWith,\.notEndsWith,\.notContains] {
            if let value=q[keyPath:key] {q[keyPath:key]=Self.stripQuotes(value)}
        }
        q.exclude=q.exclude?.map {Self.stripQuotes($0.trimmingCharacters(in:.whitespacesAndNewlines))}.filter {!$0.isEmpty}
        if q.exclude?.isEmpty == true {q.exclude=nil}
        q.excludeSections=q.excludeSections?.map {$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {!$0.isEmpty}
        if q.excludeSections?.isEmpty == true {q.excludeSections=nil}
        for key in [\PageQuery.minLength,\.maxLength,\.length,\.minWords,\.maxWords,\.rank,\.limit] {
            if let value=q[keyPath:key],value<0 {q[keyPath:key]=nil}
        }
        if q.rank == 0 {q.rank=nil}
        if q.limit == 0 {q.limit=nil}
        if q.minLength == 0 {q.minLength=nil}
        if q.minWords == 0 {q.minWords=nil}

        if let pos=q.partOfSpeech {q.partOfSpeech=Self.normalizePartOfSpeech(pos)}
        if let entity=q.entity {q.entity=Self.normalizeEntity(entity)}
        if let value=q.characterClass {q.characterClass=Self.normalizeCharacterClass(value)}
        if let unit=q.unit {q.applyUnit(Self.fold(unit))}
        if let value=q.letterCase {q.letterCase=Self.normalizeLetterCase(value,unit:q.unit)}
        if let order=q.order {q.order=Self.normalizeOrder(order)}
        if let section=q.section {q.section=Self.normalizeSection(section)}
        q.excludeSections=q.excludeSections?.map(Self.normalizeSection)

        if q.unit == nil {
            if q.entity != nil {q.unit="name"}
            else if q.characterClass != nil {q.unit=["vowel","consonant","letter"].contains(q.characterClass!) ? "letter" : "character"}
            else {q.unit="word"}
        }
        if q.entity != nil && q.unit == "word" {q.unit="name"}
        // "letter" units with a letter class are expressed by the class itself.
        if q.unit == "letter",q.characterClass == "letter" {q.characterClass=nil}
        if q.unit == "character",q.characterClass == "vowel" || q.characterClass == "consonant" {q.unit="letter"}
        // A multi-character literal is a phrase search, not a character class.
        if q.isCharacterUnit,let equals=q.equals,equals.count>1 {q.unit="phrase"}
        if q.unit == "word",let equals=q.equals,equals.contains(where:\.isWhitespace) {q.unit="phrase"}
        if q.unit == "phrase",q.equals == nil,let contains=q.contains {q.equals=contains;q.contains=nil}
        if q.rank != nil && q.order == nil {q.order="first"}
        if let order=q.order,Self.orders.contains(order),q.rank == nil,q.limit == nil {q.limit=1}
        return q
    }

    static func stripQuotes(_ value:String)->String {
        let quotes=CharacterSet(charactersIn:"\"'“”‘’«»`")
        let trimmed=value.trimmingCharacters(in:quotes)
        return trimmed.isEmpty ? value : trimmed
    }

    mutating func applyUnit(_ raw:String) {
        let value=raw
        func set(_ unit:String) {self.unit=unit}
        func punctuation(_ literal:String) {set("character");if equals == nil {equals=literal}}
        switch value {
        case "word","words","term","terms","token","tokens","vocabulary": set("word")
        case "letter","letters","alphabetic character","alphabetic characters","alphabet letters": set("letter")
        case "character","characters","char","chars","glyph","glyphs": set("character")
        case "number","numbers","numeral","numerals","figure numbers": set("number")
        case "sentence","sentences": set("sentence")
        case "paragraph","paragraphs","block","blocks","text block","text blocks": set("paragraph")
        case "heading","headings","header","headers","section","sections","subheading","subheadings","section heading","section headings","title","titles": set("heading")
        case "link","links","hyperlink","hyperlinks","url","urls","anchor","anchors": set("link")
        case "image","images","picture","pictures","photo","photos","figure","figures","illustration","illustrations","img": set("image")
        case "name","names","proper noun","proper nouns","named entity","named entities","entity","entities": set("name")
        case "person","people","persons","person name","person names","people names","personal name","personal names","human","humans":
            set("name");if entity == nil {entity="person"}
        case "place","places","place name","place names","location","locations","city","cities","country","countries":
            set("name");if entity == nil {entity="place"}
        case "organization","organizations","organisation","organisations","company","companies","institution","institutions","organization name","organization names":
            set("name");if entity == nil {entity="organization"}
        case "phrase","phrases","text","string","strings","occurrence","occurrences","times","mention","mentions": set("phrase")
        case "capital letter","capital letters","uppercase letter","uppercase letters","upper case letter","upper case letters","capitals","caps":
            set("letter");letterCase="uppercase"
        case "lowercase letter","lowercase letters","lower case letter","lower case letters","small letter","small letters":
            set("letter");letterCase="lowercase"
        case "capitalized word","capitalized words","capitalised word","capitalised words":
            set("word");letterCase="capitalized"
        case "vowel","vowels": set("letter");characterClass="vowel"
        case "consonant","consonants": set("letter");characterClass="consonant"
        case "digit","digits": set("character");characterClass="digit"
        case "punctuation","punctuation mark","punctuation marks","punctuations": set("character");characterClass="punctuation"
        case "symbol","symbols": set("character");characterClass="symbol"
        case "space","spaces","blank","blanks": set("character");characterClass="space"
        case "whitespace","whitespaces","white space","white spaces": set("character");characterClass="whitespace"
        case "quote","quotes","quotation mark","quotation marks","quote mark","quote marks": set("character");characterClass="quote"
        case "bracket","brackets","parenthesis","parentheses","paren","parens": set("character");characterClass="bracket"
        case "dash","dashes","hyphen","hyphens": set("character");characterClass="dash"
        case "dot","dots","period","periods","full stop","full stops","fullstop","fullstops": punctuation(".")
        case "comma","commas": punctuation(",")
        case "colon","colons": punctuation(":")
        case "semicolon","semicolons","semi colon","semi colons": punctuation(";")
        case "question mark","question marks": punctuation("?")
        case "exclamation mark","exclamation marks","exclamation point","exclamation points": punctuation("!")
        case "apostrophe","apostrophes": punctuation("'")
        case "slash","slashes": punctuation("/")
        case "ampersand","ampersands": punctuation("&")
        default:
            if let pos=Self.partOfSpeechUnit(value) {set("word");if partOfSpeech == nil {partOfSpeech=pos}}
            else {set(value)}
        }
    }

    static func partOfSpeechUnit(_ value:String)->String? {
        let stripped=value.hasSuffix(" words") ? String(value.dropLast(6)) : value
        let pos=normalizePartOfSpeech(stripped)
        return partsOfSpeech.contains(pos) ? pos : nil
    }

    static func normalizePartOfSpeech(_ raw:String)->String {
        switch fold(raw) {
        case "noun","nouns","common noun","common nouns": return "noun"
        case "verb","verbs","action word","action words": return "verb"
        case "adjective","adjectives","adj","adjs","describing word","describing words": return "adjective"
        case "adverb","adverbs","adv": return "adverb"
        case "pronoun","pronouns": return "pronoun"
        case "determiner","determiners","article","articles": return "determiner"
        case "preposition","prepositions": return "preposition"
        case "conjunction","conjunctions": return "conjunction"
        case "interjection","interjections": return "interjection"
        default: return fold(raw)
        }
    }
    static func normalizeEntity(_ raw:String)->String {
        switch fold(raw) {
        case "person","people","persons","personal name","person name","human","personalname": return "person"
        case "place","places","location","locations","city","country","place name","placename","geographic": return "place"
        case "organization","organisation","organizations","organisations","company","companies","institution","org","organizationname": return "organization"
        default: return fold(raw)
        }
    }
    static func normalizeLetterCase(_ raw:String,unit:String?)->String {
        switch fold(raw) {
        case "uppercase","upper case","upper","all caps","allcaps","caps","all capitals","block capitals": return "uppercase"
        case "lowercase","lower case","lower","small": return "lowercase"
        case "capitalized","capitalised","title case","titlecase","initial capital","capital initial","proper case": return "capitalized"
        case "capital","capitals": return unit == "word" ? "capitalized" : "uppercase"
        default: return fold(raw)
        }
    }
    static func normalizeCharacterClass(_ raw:String)->String {
        switch fold(raw) {
        case "letter","letters","alphabetic","alpha": return "letter"
        case "digit","digits","number","numbers","numeric","numeral","numerals": return "digit"
        case "punctuation","punctuations","punctuation mark","punctuation marks": return "punctuation"
        case "symbol","symbols": return "symbol"
        case "space","spaces","blank": return "space"
        case "whitespace","white space","whitespaces": return "whitespace"
        case "vowel","vowels": return "vowel"
        case "consonant","consonants": return "consonant"
        case "quote","quotes","quotation mark","quotation marks": return "quote"
        case "bracket","brackets","parenthesis","parentheses": return "bracket"
        case "dash","dashes","hyphen","hyphens": return "dash"
        default: return fold(raw)
        }
    }
    static func normalizeOrder(_ raw:String)->String? {
        switch fold(raw) {
        case "first","beginning","earliest","start","firstly": return "first"
        case "last","final","end","latest","lastly": return "last"
        case "longest","largest","biggest","longer","long","most letters": return "longest"
        case "shortest","smallest","shorter","short","fewest letters": return "shortest"
        case "frequent","most frequent","most common","common","popular","most used","repeated","frequency": return "frequent"
        case "rare","rarest","least common","least frequent","least used": return "rare"
        case "","none","document","reading","reading order","page","default","any": return nil
        default: return fold(raw)
        }
    }
    /// "the Early life section" → "Early life"; "intro" → "introduction".
    public static func normalizeSectionName(_ raw:String)->String {normalizeSection(raw)}
    static func normalizeSection(_ raw:String)->String {
        var value=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        let lowered=value.lowercased()
        if ["intro","introduction","lead","lead section","the introduction","the intro","opening","summary","lede"].contains(lowered) {return "introduction"}
        for suffix in [" section"," part"," chapter"," heading"] where value.lowercased().hasSuffix(suffix) {
            value=String(value.dropLast(suffix.count))
        }
        if value.lowercased().hasPrefix("the ") {value=String(value.dropFirst(4))}
        return value.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}

// MARK: - Validation

extension PageQuery {
    /// Human-readable problems with a normalized query. Empty means executable.
    public var problems:[String] {
        var issues:[String]=[]
        let unit=self.unit ?? "word"
        if !Self.units.contains(unit) {issues.append("unknown unit “\(unit)”; use one of \(Self.units.joined(separator:", "))")}
        if let pos=partOfSpeech,!Self.partsOfSpeech.contains(pos) {issues.append("unknown partOfSpeech “\(pos)”")}
        if partOfSpeech != nil && unit != "word" {issues.append("partOfSpeech only applies to words")}
        if let entity,!Self.entities.contains(entity) {issues.append("unknown entity “\(entity)”")}
        if let letterCase,!Self.letterCases.contains(letterCase) {issues.append("unknown letterCase “\(letterCase)”")}
        if let characterClass {
            if !Self.characterClasses.contains(characterClass) {issues.append("unknown characterClass “\(characterClass)”")}
            else if !isCharacterUnit {issues.append("characterClass only applies to letters and characters")}
        }
        if let order,!Self.orders.contains(order) {issues.append("unknown order “\(order)”")}
        if unit == "phrase",equals == nil {issues.append("a phrase search needs the text to find in equals")}
        if linksTo != nil && unit != "link" {issues.append("linksTo only applies to links")}
        for (name,value) in [("rank",rank),("limit",limit)] {
            if let value,value>100_000 {issues.append("\(name) is too large")}
        }
        for (name,value) in [("minLength",minLength),("maxLength",maxLength),("length",length),("minWords",minWords),("maxWords",maxWords)] {
            if let value,value>10_000 {issues.append("\(name) is too large")}
        }
        if let minLength,let maxLength,minLength>maxLength {issues.append("minLength is greater than maxLength")}
        for value in [startsWith,endsWith,contains,equals,notStartsWith,notEndsWith,notContains,section,meaning,linksTo].compactMap({$0}) where value.count>300 {
            issues.append("a text condition is longer than 300 characters")
        }
        if (exclude ?? []).count>200 {issues.append("too many excluded words")}
        return issues
    }
}

// MARK: - Plain-language description

extension PageQuery {
    /// "adjectives ending with “w”", "capital letters", "the 2nd longest word in “Career”".
    public var summary:String {
        let q=normalized()
        var phrase=q.nounPhrase(plural:true)
        var conditions:[String]=[]
        func quoted(_ value:String)->String {value.split(separator:"|").map {"“\($0)”"}.joined(separator:" or ")}
        if let value=q.startsWith {conditions.append("starting with \(quoted(value))")}
        if let value=q.endsWith {conditions.append("ending with \(quoted(value))")}
        if let value=q.contains {conditions.append("containing \(quoted(value))")}
        if let value=q.equals,q.unit != "phrase",!(q.isCharacterUnit && Self.punctuationName(value) != nil) {conditions.append("spelled \(quoted(value))")}
        if let value=q.notStartsWith {conditions.append("not starting with \(quoted(value))")}
        if let value=q.notEndsWith {conditions.append("not ending with \(quoted(value))")}
        if let value=q.notContains {conditions.append("without \(quoted(value))")}
        if let value=q.linksTo {conditions.append("to “\(value)”")}
        let measure=q.isWordLike ? "letters" : "characters"
        if let length=q.length {conditions.append("with exactly \(length) \(measure)")}
        else if let minLength=q.minLength,let maxLength=q.maxLength {conditions.append("with \(minLength)–\(maxLength) \(measure)")}
        else if let minLength=q.minLength {conditions.append("with at least \(minLength) \(measure)")}
        else if let maxLength=q.maxLength {conditions.append("with at most \(maxLength) \(measure)")}
        if let minWords=q.minWords,let maxWords=q.maxWords {conditions.append("with \(minWords)–\(maxWords) words")}
        else if let minWords=q.minWords {conditions.append("with at least \(minWords) words")}
        else if let maxWords=q.maxWords {conditions.append("with at most \(maxWords) words")}
        if let meaning=q.meaning {conditions.append("that match “\(meaning)”")}
        if let exclude=q.exclude,!exclude.isEmpty {conditions.append("except "+exclude.prefix(6).map {"“\($0)”"}.joined(separator:", ")+(exclude.count>6 ? "…" : ""))}
        if let section=q.section {conditions.append(section == "introduction" ? "in the introduction" : "in “\(section)”")}
        if let excluded=q.excludeSections,!excluded.isEmpty {conditions.append("outside "+excluded.map {"“\($0)”"}.joined(separator:", "))}
        if !conditions.isEmpty {phrase += " "+conditions.joined(separator:" and ").replacingOccurrences(of:" and in ",with:" in ")}

        guard let order=q.order else {return phrase}
        let singular=q.nounPhrase(plural:false)
        let rest=conditions.isEmpty ? "" : " "+conditions.joined(separator:" and ").replacingOccurrences(of:" and in ",with:" in ")
        let count=q.limit ?? 1
        let ordinal=q.rank.map {Self.ordinal($0)+" "} ?? ""
        let adjective:String
        switch order {
        case "first": adjective="first"
        case "last": adjective="last"
        case "longest": adjective="longest"
        case "shortest": adjective="shortest"
        case "frequent": adjective="most common"
        case "rare": adjective="least common"
        default: adjective=order
        }
        if q.rank != nil || count == 1 {return "the \(ordinal)\(adjective) \(singular)\(rest)"}
        if order == "first" || order == "last" {return "the \(adjective) \(count) \(q.nounPhrase(plural:true))\(rest)"}
        return "the \(count) \(adjective) \(q.nounPhrase(plural:true))\(rest)"
    }

    public func nounPhrase(plural:Bool)->String {
        let unit=self.unit ?? "word"
        let distinctPrefix=distinct == true ? "unique " : ""
        func pick(_ one:String,_ many:String)->String {distinctPrefix+(plural ? many : one)}
        switch unit {
        case "word":
            let base:String
            if let pos=partOfSpeech {base=pos} else {base="word"}
            var noun=plural ? Self.plural(base) : base
            switch letterCase {
            case "capitalized": noun="capitalized "+noun
            case "uppercase": noun="all-caps "+noun
            case "lowercase": noun="lowercase "+noun
            default: break
            }
            return distinctPrefix+noun
        case "letter":
            var noun=plural ? "letters" : "letter"
            switch characterClass {
            case "vowel": noun=plural ? "vowels" : "vowel"
            case "consonant": noun=plural ? "consonants" : "consonant"
            default: break
            }
            switch letterCase {
            case "uppercase": noun=(characterClass == nil ? "capital " : "uppercase ")+noun
            case "lowercase": noun="lowercase "+noun
            default: break
            }
            if let equals {return plural ? "occurrences of the letter “\(equals)”" : "letter “\(equals)”"}
            return distinctPrefix+noun
        case "character":
            if let equals,let name=Self.punctuationName(equals) {return pick(name.one,name.many)+" (\(equals))"}
            if let equals {return pick("“\(equals)” character","“\(equals)” characters")}
            switch characterClass {
            case "digit": return pick("digit","digits")
            case "punctuation": return pick("punctuation mark","punctuation marks")
            case "symbol": return pick("symbol","symbols")
            case "space": return pick("space","spaces")
            case "whitespace": return pick("whitespace character","whitespace characters")
            case "quote": return pick("quotation mark","quotation marks")
            case "bracket": return pick("bracket","brackets")
            case "dash": return pick("dash","dashes")
            case "letter": return pick("letter","letters")
            default:
                switch letterCase {
                case "uppercase": return pick("uppercase character","uppercase characters")
                case "lowercase": return pick("lowercase character","lowercase characters")
                default: return pick("character","characters")
                }
            }
        case "number": return pick("number","numbers")
        case "sentence": return pick("sentence","sentences")
        case "paragraph": return pick("paragraph","paragraphs")
        case "heading": return pick("heading","headings")
        case "link": return pick("link","links")
        case "image": return pick("image","images")
        case "name":
            switch entity {
            case "person": return pick("person’s name","people’s names")
            case "place": return pick("place name","place names")
            case "organization": return pick("organization name","organization names")
            default: return pick("name","names")
            }
        case "phrase": return plural ? "occurrences of “\(equals ?? "")”" : "occurrence of “\(equals ?? "")”"
        default: return pick(unit,unit+"s")
        }
    }

    static func plural(_ noun:String)->String {
        if noun.hasSuffix("s") {return noun}
        return noun+"s"
    }
    static func ordinal(_ value:Int)->String {
        let names=[1:"",2:"2nd",3:"3rd"]
        if value == 1 {return ""}
        if let name=names[value],!(11...13).contains(value%100) {return name}
        let suffix:String
        switch (value%10,value%100) {
        case (_,11...13): suffix="th"
        case (1,_): suffix="st"
        case (2,_): suffix="nd"
        case (3,_): suffix="rd"
        default: suffix="th"
        }
        return "\(value)\(suffix)"
    }
    static func punctuationName(_ value:String)->(one:String,many:String)? {
        switch value {
        case ".": return ("period","periods")
        case ",": return ("comma","commas")
        case ":": return ("colon","colons")
        case ";": return ("semicolon","semicolons")
        case "?": return ("question mark","question marks")
        case "!": return ("exclamation mark","exclamation marks")
        case "'": return ("apostrophe","apostrophes")
        case "-": return ("hyphen","hyphens")
        case "/": return ("slash","slashes")
        case "&": return ("ampersand","ampersands")
        case "(",")": return ("parenthesis","parentheses")
        default: return nil
        }
    }
}

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    func lenientString(_ key:Key,trim:Bool=true)->String? {
        if let value=try? decodeIfPresent(String.self,forKey:key) {
            let cleaned=value.trimmingCharacters(in:.whitespacesAndNewlines)
            if cleaned.isEmpty || ["null","none","nil","n/a"].contains(cleaned.lowercased()) {return nil}
            return trim ? cleaned : value
        }
        if let value=try? decodeIfPresent(Int.self,forKey:key) {return String(value)}
        if let value=try? decodeIfPresent([String].self,forKey:key),let first=value.first(where:{!$0.isEmpty}) {return first}
        return nil
    }
    func lenientInt(_ key:Key)->Int? {
        if let value=try? decodeIfPresent(Int.self,forKey:key) {return value}
        if let value=try? decodeIfPresent(Double.self,forKey:key),value.isFinite,abs(value)<1_000_000 {return Int(value.rounded())}
        if let value=try? decodeIfPresent(String.self,forKey:key) {
            let digits=value.trimmingCharacters(in:.whitespacesAndNewlines)
            if let number=Int(digits) {return number}
            return PageQuery.numberWords[digits.lowercased()]
        }
        return nil
    }
    func lenientBool(_ key:Key)->Bool? {
        if let value=try? decodeIfPresent(Bool.self,forKey:key) {return value}
        if let value=try? decodeIfPresent(String.self,forKey:key) {
            switch value.lowercased().trimmingCharacters(in:.whitespacesAndNewlines) {
            case "true","yes","1": return true
            case "false","no","0": return false
            default: return nil
            }
        }
        if let value=try? decodeIfPresent(Int.self,forKey:key) {return value != 0}
        return nil
    }
    func lenientStrings(_ key:Key)->[String]? {
        if let values=try? decodeIfPresent([String].self,forKey:key) {
            let cleaned=values.map {$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {!$0.isEmpty}
            return cleaned.isEmpty ? nil : cleaned
        }
        if let value=try? decodeIfPresent(String.self,forKey:key) {
            let cleaned=value.split(separator:",").map {$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {!$0.isEmpty}
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }
}

extension PageQuery {
    static let numberWords:[String:Int]=[
        "one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,"eight":8,"nine":9,"ten":10,
        "eleven":11,"twelve":12,"thirteen":13,"fourteen":14,"fifteen":15,"sixteen":16,"seventeen":17,"eighteen":18,"nineteen":19,"twenty":20,
        "first":1,"second":2,"third":3,"fourth":4,"fifth":5,"sixth":6,"seventh":7,"eighth":8,"ninth":9,"tenth":10
    ]
}
