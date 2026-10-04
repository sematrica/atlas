import Foundation

public enum OfflineURL {
    public static func make(host: String,path: String) -> URL? {
        var parts=URLComponents(); parts.scheme="atlas"; parts.host=host
        parts.path="/"+path; return parts.url
    }
    public static func localWikipediaPath(_ url: URL) -> String? {
        guard ["http","https"].contains(url.scheme?.lowercased() ?? ""),
              let host=url.host?.lowercased(),host == "wikipedia.org" || host.hasSuffix(".wikipedia.org"),
              url.path.hasPrefix("/wiki/") else { return nil }
        return String(url.path.dropFirst(6))
    }
    public static let contentSecurityPolicy = "default-src 'none'; img-src atlas: data:; style-src atlas: 'unsafe-inline'; font-src atlas: data:; media-src atlas:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
    public static func protectHTML(_ html: String) -> String {
        let policy="<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\"><meta name=\"referrer\" content=\"no-referrer\">"
        if let range=html.range(of:"<head\\b[^>]*>",options:[.regularExpression,.caseInsensitive]) {
            var result=html; result.insert(contentsOf:policy,at:range.upperBound); return result
        }
        return "<head>\(policy)</head>"+html
    }
}
