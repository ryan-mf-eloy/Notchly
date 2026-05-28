import Foundation

struct WebLinkPreview: Sendable, Hashable {
    var url: URL
    var title: String
    var domain: String
    var description: String?
    var imageURL: URL?
    var faviconURL: URL?

    static func fallback(for source: AnswerSource) -> WebLinkPreview {
        let webURL = source.webURL
        let url = webURL ?? URL(string: "https://notchly.local/source")!
        let domain = webURL.flatMap { $0.host(percentEncoded: false) ?? $0.host } ?? source.displayHost
        return WebLinkPreview(
            url: url,
            title: source.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyRichAnswer ?? domain,
            domain: domain,
            description: source.snippet?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyRichAnswer,
            imageURL: nil,
            faviconURL: webURL.flatMap { defaultFaviconURL(for: $0) }
        )
    }

    static func defaultFaviconURL(for url: URL) -> URL? {
        guard let scheme = url.scheme,
              let host = url.host(percentEncoded: false) ?? url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }
}

actor WebLinkPreviewService {
    static let shared = WebLinkPreviewService()

    private var cache: [URL: WebLinkPreview] = [:]
    private let maxHTMLBytes = 200_000

    func preview(for source: AnswerSource, allowRemoteFetch: Bool) async -> WebLinkPreview {
        let fallback = WebLinkPreview.fallback(for: source)
        guard allowRemoteFetch, let url = source.webURL else { return fallback }
        if let cached = cache[url] { return cached }

        do {
            let request = Self.request(for: url)
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            guard Self.isSuccessfulPreviewStatus(statusCode) else {
                cache[url] = fallback
                return fallback
            }
            let contentType = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard contentType.isEmpty || contentType.contains("html") else {
                cache[url] = fallback
                return fallback
            }
            let htmlData = data.prefix(maxHTMLBytes)
            guard let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1) else {
                cache[url] = fallback
                return fallback
            }

            let preview = Self.preview(fromHTML: html, base: url, fallback: fallback, httpStatusCode: statusCode)
            cache[url] = preview
            return preview
        } catch {
            cache[url] = fallback
            return fallback
        }
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        return request
    }

    static func preview(fromHTML html: String, base url: URL, fallback: WebLinkPreview, httpStatusCode: Int? = 200) -> WebLinkPreview {
        guard isSuccessfulPreviewStatus(httpStatusCode),
              !isBlockedOrChallengePage(html)
        else { return fallback }

        let title = firstMetaContent(keys: ["og:title", "twitter:title"], in: html) ??
            titleTag(in: html) ??
            fallback.title
        let description = firstMetaContent(keys: ["og:description", "twitter:description", "description"], in: html) ??
            fallback.description
        let imageURL = firstMetaContent(keys: ["og:image", "twitter:image"], in: html)
            .flatMap { resolvedURL($0, base: url) }
        let faviconURL = iconURL(in: html, base: url) ?? fallback.faviconURL

        return WebLinkPreview(
            url: url,
            title: title.collapsedRichAnswerWhitespace.nilIfEmptyRichAnswer ?? fallback.title,
            domain: fallback.domain,
            description: description?.collapsedRichAnswerWhitespace.nilIfEmptyRichAnswer,
            imageURL: imageURL,
            faviconURL: faviconURL
        )
    }

    private static func isSuccessfulPreviewStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return true }
        return 200..<400 ~= statusCode
    }

    private static func isBlockedOrChallengePage(_ html: String) -> Bool {
        let title = titleTag(in: html)?.lowercased() ?? ""
        let head = String(html.prefix(12_000)).htmlPreviewDecoded.collapsedRichAnswerWhitespace.lowercased()
        let blockedTitleIndicators = [
            "access denied",
            "403 forbidden",
            "forbidden",
            "just a moment",
            "attention required",
            "robot check",
            "request blocked",
            "service unavailable"
        ]
        if blockedTitleIndicators.contains(where: { title.contains($0) }) {
            return true
        }
        if head.contains("you don't have permission to access") ||
            head.contains("you do not have permission to access") ||
            head.contains("request blocked") ||
            head.contains("verify you are human") ||
            head.contains("enable javascript and cookies") ||
            head.contains("unusual traffic") {
            return true
        }
        if head.contains("access denied") && (head.contains("akamai") || head.contains("reference #") || head.contains("generated by")) {
            return true
        }
        if head.contains("cloudflare") && (head.contains("attention required") || head.contains("just a moment") || head.contains("ray id")) {
            return true
        }
        return false
    }

    private static func firstMetaContent(keys: [String], in html: String) -> String? {
        let wanted = Set(keys.map { $0.lowercased() })
        for tag in tags(named: "meta", in: html) {
            let attributes = attributes(in: tag)
            let key = (attributes["property"] ?? attributes["name"])?.lowercased()
            guard let key, wanted.contains(key) else { continue }
            if let content = attributes["content"]?.htmlPreviewDecoded.collapsedRichAnswerWhitespace.nilIfEmptyRichAnswer {
                return content
            }
        }
        return nil
    }

    private static func iconURL(in html: String, base: URL) -> URL? {
        for tag in tags(named: "link", in: html) {
            let attributes = attributes(in: tag)
            guard let rel = attributes["rel"]?.lowercased(), rel.contains("icon"),
                  let href = attributes["href"] else { continue }
            if let url = resolvedURL(href, base: base) {
                return url
            }
        }
        return nil
    }

    private static func titleTag(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range]).htmlPreviewDecoded.collapsedRichAnswerWhitespace.nilIfEmptyRichAnswer
    }

    private static func tags(named name: String, in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<\#(name)\b[^>]*>"#, options: [.caseInsensitive]) else {
            return []
        }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html) else { return nil }
            return String(html[range])
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z_:.-]+)\s*=\s*(['"])(.*?)\2"#, options: [.caseInsensitive]) else {
            return [:]
        }
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) where match.numberOfRanges > 3 {
            guard let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 3), in: tag) else { continue }
            result[String(tag[keyRange]).lowercased()] = String(tag[valueRange]).htmlPreviewDecoded
        }
        return result
    }

    private static func resolvedURL(_ raw: String, base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String {
        self ?? ""
    }
}

private extension String {
    var htmlPreviewDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
