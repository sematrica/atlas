import Foundation

/// How one highlight layer is painted, parsed from the user's own color words:
/// "green", "light blue", "#ff8800", "half green half yellow", "alternate red
/// and blue", "a gradient from blue to purple", "rainbow", "underline in red",
/// "half of them green and half yellow".
public struct HighlightStyle:Codable,Sendable,Equatable {
    public enum Mode:String,Codable,Sendable {
        /// Every match in the first color.
        case solid
        /// Each match is divided into equal parts, one per color.
        case split
        /// Colors blend character by character across each match.
        case gradient
        /// Match 1 gets color 1, match 2 color 2, and so on, cycling.
        case alternate
        /// Matches are divided into consecutive groups, one per color.
        case groups
    }
    /// Hex colors, "#rrggbb".
    public var colors:[String]
    public var mode:Mode
    public var underline:Bool
    /// Color the letters instead of the background.
    public var textOnly:Bool
    /// What the legend shows, e.g. "green" or "half green, half yellow".
    public var label:String

    public init(colors:[String],mode:Mode = .solid,underline:Bool=false,textOnly:Bool=false,label:String) {
        self.colors=colors.isEmpty ? [Self.defaults[0]] : colors
        self.mode=self.colors.count == 1 && mode != .solid && mode != .gradient ? .solid : mode
        self.underline=underline;self.textOnly=textOnly;self.label=label
    }

    /// Soft defaults when the user names no color; each new layer takes the next one.
    public static let defaults=["#f5da7b","#7fdec9","#9cc9ff","#c9b3ff","#ffb38a","#ff9fbf","#b5e48c","#ffd6a5"]
    public static let defaultNames=["yellow","mint","sky blue","lavender","peach","pink","lime","apricot"]
    public static func automatic(_ index:Int)->HighlightStyle {
        let i=((index%defaults.count)+defaults.count)%defaults.count
        return .init(colors:[defaults[i]],label:defaultNames[i])
    }
}

// MARK: - Parsing

extension HighlightStyle {
    static let modeWords:Set<String>=[
        "half","halves","halfs","split","two","tone","toned","each","every","other","alternate","alternating","alternated","alternately",
        "rotate","rotating","cycle","cycling","switch","switching","gradient","gradients","fade","fading","faded","ombre","blend","blended","blending",
        "transition","from","to","into","rainbow","and","or","then","with","in","using","as","color","colors","colour","colours","colored","coloured",
        "shade","shades","of","the","them","it","those","these","word","words","letter","letters","part","parts","one","another","different",
        "underline","underlined","underlines","text","font","ink","background","highlight","highlighted","mix","mixed","mixture","first","second",
        "rest","remaining","group","groups","a","an","bit","little","very"
    ]
    static let shadeWords:[String:(mix:String,amount:Double)]=[
        "light":("#ffffff",0.45),"pale":("#ffffff",0.6),"pastel":("#ffffff",0.5),"soft":("#ffffff",0.35),"bright":("#ffffff",0.0),
        "neon":("#ffffff",0.0),"vivid":("#ffffff",0.0),"dark":("#000000",0.4),"deep":("#000000",0.25),"dim":("#000000",0.3)
    ]

    /// Parses a color phrase. Returns nil when it names no color at all.
    public static func parse(_ phrase:String?)->HighlightStyle? {
        guard let phrase,!phrase.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return nil}
        let text=phrase.lowercased().replacingOccurrences(of:"-",with:" ")
        let tokens=tokenize(text)
        var colors:[String]=[],names:[String]=[]
        var index=0,shade:String?
        while index<tokens.count {
            let token=tokens[index]
            if token.hasPrefix("#"),let hex=normalizeHex(token) {colors.append(hex);names.append(token);index += 1;continue}
            if shadeWords[token] != nil {shade=token;index += 1;continue}
            if token == "rainbow" {
                colors += rainbow;names.append("rainbow");index += 1;continue
            }
            var matched=false
            for width in stride(from:3,through:1,by:-1) where index+width<=tokens.count {
                let words=tokens[index..<(index+width)]
                let joined=words.joined()
                let spaced=words.joined(separator:" ")
                let candidates=shade.map {[$0+joined,joined]} ?? [joined]
                if let found=candidates.lazy.compactMap({name in namedColors[name].map {(name,$0)}}).first {
                    var hex=found.1
                    let usedShade=found.0 != joined
                    if let shade,!usedShade,let mix=shadeWords[shade],mix.amount>0 {hex=Self.mix(hex,mix.mix,mix.amount)}
                    colors.append(hex)
                    names.append((shade.map {$0+" "} ?? "")+spaced)
                    shade=nil;index += width;matched=true;break
                }
            }
            if !matched {index += 1}
        }
        guard !colors.isEmpty else {return nil}
        let has={(words:[String]) in words.contains {tokens.contains($0)}}
        let groupsRequested=text.range(of:#"\bhalf (?:of )?(?:them|the|those|these|matches|words|results)\b|\b(?:first|second) half\b|\bthe rest\b|\bremaining\b"#,options:.regularExpression) != nil
        var mode:Mode
        if colors.count == 1 {mode = .solid}
        else if groupsRequested {mode = .groups}
        else if names.contains("rainbow") && !has(["alternate","alternating","alternately","every","cycle","cycling"]) {mode = .gradient}
        else if has(["gradient","fade","fading","faded","ombre","blend","blended","blending","transition"]) || text.range(of:#"\bfrom\b.+\bto\b"#,options:.regularExpression) != nil {mode = .gradient}
        else if has(["half","halves","halfs","split","tone","toned","parts","mix","mixed"]) {mode = .split}
        else {mode = .alternate}
        let underline=has(["underline","underlined","underlines"])
        let textOnly=has(["text","font","ink"]) && !has(["background","highlight","highlighted"])
        let label=names.joined(separator:mode == .split ? " / " : mode == .gradient ? " → " : ", ")
        return .init(colors:colors,mode:mode,underline:underline,textOnly:textOnly,label:describe(label,mode:mode,underline:underline,textOnly:textOnly))
    }

    static func describe(_ names:String,mode:Mode,underline:Bool,textOnly:Bool)->String {
        var label:String
        switch mode {
        case .solid: label=names
        case .split: label="split "+names
        case .gradient: label=names == "rainbow" ? "rainbow" : "gradient "+names
        case .alternate: label="alternating "+names
        case .groups: label="groups "+names
        }
        if underline {label += " underline"}
        if textOnly {label += " text"}
        return label
    }

    /// True when every word of a phrase is color vocabulary and at least one names a color.
    /// The local parser uses this to accept "in half green and half yellow" without a model.
    public static func recognizes(_ phrase:String)->Bool {
        let tokens=tokenize(phrase.lowercased().replacingOccurrences(of:"-",with:" "))
        guard !tokens.isEmpty,parse(phrase) != nil else {return false}
        var index=0
        while index<tokens.count {
            let token=tokens[index]
            if modeWords.contains(token) || shadeWords[token] != nil || token == "rainbow" || (token.hasPrefix("#") && normalizeHex(token) != nil) {index += 1;continue}
            var matched=false
            for width in stride(from:3,through:1,by:-1) where index+width<=tokens.count {
                if namedColors[tokens[index..<(index+width)].joined()] != nil {index += width;matched=true;break}
            }
            if !matched {return false}
        }
        return true
    }

    static func tokenize(_ text:String)->[String] {
        text.split(whereSeparator:{!($0.isLetter || $0.isNumber || $0 == "#")}).map(String.init)
    }
    static func normalizeHex(_ token:String)->String? {
        let digits=token.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else {return nil}
        if digits.count == 6 {return "#"+digits}
        if digits.count == 3 {return "#"+digits.map {"\($0)\($0)"}.joined()}
        return nil
    }
    static let rainbow=["#ff3b30","#ff9500","#ffcc00","#34c759","#007aff","#5856d6","#af52de"]
}

// MARK: - Painting

/// One painted range: a text range (or whole element) and an index into the layer's colors.
public struct HighlightPaint:Codable,Sendable,Equatable {
    public let id:String
    public let start:Int?
    public let end:Int?
    public let color:Int
}

extension HighlightStyle {
    /// The colors a layer actually uses, after gradient interpolation.
    public var palette:[String] {
        guard mode == .gradient,colors.count>=2 else {return colors}
        return (0..<Self.gradientSteps).map {Self.sample(colors,at:Double($0)/Double(Self.gradientSteps-1))}
    }
    static let gradientSteps=12

    /// Splits matches into painted ranges following the style's mode.
    public func paints(for matches:[PageMatch])->[HighlightPaint] {paintsByMatch(for:matches).flatMap {$0}}

    /// The same paints grouped by match, so a tour can paint each match as the spider reaches it.
    public func paintsByMatch(for matches:[PageMatch])->[[HighlightPaint]] {
        var grouped=Array(repeating:[HighlightPaint](),count:matches.count)
        for (index,match) in matches.enumerated() {
            guard let range=match.range else {
                if let id=match.elementID {grouped[index]=[.init(id:id,start:nil,end:nil,color:wholeColor(index,total:matches.count))]}
                continue
            }
            switch mode {
            case .solid,.alternate,.groups:
                grouped[index]=[.init(id:range.id,start:range.start,end:range.end,color:wholeColor(index,total:matches.count))]
            case .split:
                grouped[index]=Self.pieces(range,parts:max(1,colors.count)).enumerated().map {.init(id:range.id,start:$0.element.start,end:$0.element.end,color:$0.offset)}
            case .gradient:
                let pieces=Self.pieces(range,parts:min(Self.gradientSteps,max(1,range.text.count)))
                grouped[index]=pieces.enumerated().map {part,piece in
                    let position=pieces.count == 1 ? 0 : Double(part)/Double(pieces.count-1)
                    return .init(id:range.id,start:piece.start,end:piece.end,color:Int((position*Double(Self.gradientSteps-1)).rounded()))
                }
            }
        }
        return grouped
    }

    func wholeColor(_ index:Int,total:Int)->Int {
        let count=max(1,colors.count)
        switch mode {
        case .alternate: return index%count
        case .groups: return min(count-1,index*count/max(1,total))
        default: return 0
        }
    }

    /// Divides a range into roughly equal parts on character boundaries, in UTF-16 offsets.
    static func pieces(_ range:CrawlerPageRange,parts:Int)->[(start:Int,end:Int)] {
        let characters=Array(range.text)
        guard parts>1,characters.count>1 else {return [(range.start,range.end)]}
        let used=min(parts,characters.count)
        var result:[(start:Int,end:Int)]=[]
        var offset=range.start,consumed=0
        for part in 0..<used {
            let next=(part+1)*characters.count/used
            let width=characters[consumed..<next].reduce(0) {$0+$1.utf16.count}
            result.append((offset,offset+width))
            offset += width;consumed=next
        }
        if let last=result.last,last.end != range.end {result[result.count-1]=(last.start,range.end)}
        return result
    }

    /// Text color with enough contrast over a background color.
    public static func ink(for hex:String)->String {
        guard let rgb=components(hex) else {return "#111111"}
        let luminance=0.2126*linear(rgb.0)+0.7152*linear(rgb.1)+0.0722*linear(rgb.2)
        return luminance>0.4 ? "#111111" : "#ffffff"
    }
    static func linear(_ value:Double)->Double {value<=0.03928 ? value/12.92 : pow((value+0.055)/1.055,2.4)}
    static func components(_ hex:String)->(Double,Double,Double)? {
        guard let value=normalizeHex(hex),let number=Int(value.dropFirst(),radix:16) else {return nil}
        return (Double((number>>16)&255)/255,Double((number>>8)&255)/255,Double(number&255)/255)
    }
    static func hex(_ r:Double,_ g:Double,_ b:Double)->String {
        func byte(_ v:Double)->Int {Int((min(1,max(0,v))*255).rounded())}
        return String(format:"#%02x%02x%02x",byte(r),byte(g),byte(b))
    }
    static func mix(_ a:String,_ b:String,_ amount:Double)->String {
        guard let x=components(a),let y=components(b) else {return a}
        return hex(x.0+(y.0-x.0)*amount,x.1+(y.1-x.1)*amount,x.2+(y.2-x.2)*amount)
    }
    static func sample(_ stops:[String],at position:Double)->String {
        guard stops.count>1 else {return stops.first ?? defaults[0]}
        let scaled=min(1,max(0,position))*Double(stops.count-1)
        let lower=Int(floor(scaled)),upper=min(stops.count-1,lower+1)
        return mix(stops[lower],stops[upper],scaled-Double(lower))
    }
}

// MARK: - Named colors

extension HighlightStyle {
    /// CSS named colors plus common everyday names.
    static let namedColors:[String:String]={
        var table:[String:String]=[:]
        let css="aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgrey a9a9a9 darkgreen 006400 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 deepskyblue 00bfff dimgray 696969 dodgerblue 1e90ff firebrick b22222 floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 grey 808080 green 008000 greenyellow adff2f honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgrey d3d3d3 lightgreen 90ee90 lightpink ffb6c1 lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32"
        let extra="mint 98ff98 peach ffcba4 rose ff66cc lilac c8a2c8 sky 87ceeb sand c2b280 mustard ffdb58 emerald 50c878 jade 00a86b ruby e0115f sapphire 0f52ba amber ffbf00 cream fffdd0 charcoal 36454f scarlet ff2400 cherry de3163 lemon fff44f banana ffe135 grape 6f2da8 aubergine 3d0734 eggplant 614051 bronze cd7f32 copper b87333 rust b7410e brick cb4154 burgundy 800020 wine 722f37 ochre cc7722 sage bcb88a moss 8a9a5b pistachio 93c572 seafoam 71eeb8 apricot fbceb1 cobalt 0047ab cerulean 007ba7 periwinkle ccccff blush de5d83 bubblegum ffc1cc neonpink ff6ec7 neongreen 39ff14 neonyellow ffff33 neonblue 1f51ff golden ffd700 pinkish ffc0cb reddish ff4d4d bluish 5b9bd5 greenish 7ccd7c yellowish ffff66 purplish 9b59b6 orangish ffa64d"
        for source in [css,extra] {
            let parts=source.split(separator:" ").map(String.init)
            var i=0
            while i+1<parts.count {table[parts[i]]="#"+parts[i+1];i += 2}
        }
        return table
    }()
}
