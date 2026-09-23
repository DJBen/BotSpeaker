import Foundation

/// Accept a Teams invitation without mistaking its help/options links for a join URL.
enum RecallMeetingInput {
    static func parse(_ input: String) -> (meeting: String, passcode: String) {
        let text = input.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func match(_ pattern: String, group: Int = 0) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(result.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
        if let link = match(#"https://teams\.(?:microsoft|live)\.com/(?:meet/|l/meetup-join/)[^\s<>"']+"#) { return (link, "") }
        guard let id = match(#"\bMeeting\s+ID\s*:\s*([0-9](?:[0-9\s]*[0-9])?)"#, group: 1) else { return (text, "") }
        return (id.filter { !$0.isWhitespace }, match(#"\bPasscode\s*:\s*([^\s<>]+)"#, group: 1) ?? "")
    }

    /// nil means the caller must recover join details from previously seen bots.
    static func directURL(_ value: String, passcode: String) throws -> String? {
        guard !value.isEmpty else { throw AppError("Enter a meeting invite link or a previously used meeting ID.") }
        if let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil { return value }
        if value.contains("://") { throw AppError("Use an HTTPS meeting invite link.") }
        guard !passcode.isEmpty else { return nil }
        let id = value.filter { !$0.isWhitespace }
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw AppError("Enter a numeric Teams meeting ID with the passcode, or paste the full invitation.") }
        var url = URLComponents(string: "https://teams.microsoft.com/meet/" + id)!
        url.queryItems = [URLQueryItem(name: "p", value: passcode)]
        return url.url!.absoluteString
    }
}
