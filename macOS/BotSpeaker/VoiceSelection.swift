import Foundation

/// Resolve names deterministically. An ambiguous name must never silently
/// send speech using whichever voice happened to be returned first.
enum VoiceSelection {
    struct Failure: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    static func resolve(_ raw: String?, voices: [(id: String, name: String)]) throws -> String? {
        let wanted = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !wanted.isEmpty, wanted.lowercased() != "default" else { return nil }
        if voices.contains(where: { $0.id == wanted }) { return wanted }
        let exact = voices.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        if !exact.isEmpty { return try unique(exact, query: wanted) }
        // IDs can refer to voices outside the local account's saved list,
        // including voices available to a remote attendee.
        if wanted.count >= 16, wanted.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) {
            return wanted
        }
        let partial = voices.filter { $0.name.localizedCaseInsensitiveContains(wanted) }
        if !partial.isEmpty { return try unique(partial, query: wanted) }
        throw Failure(code: "not_found", message: "No voice matches \"\(wanted)\". Run botspeaker voices --refresh, or provide an exact voice ID.")
    }

    private static func unique(_ matches: [(id: String, name: String)], query: String) throws -> String {
        guard matches.count == 1 else {
            let choices = matches.prefix(8).map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
            throw Failure(code: "ambiguous_voice", message: "Multiple voices match \"\(query)\": \(choices). Use an exact voice ID.")
        }
        return matches[0].id
    }
}
