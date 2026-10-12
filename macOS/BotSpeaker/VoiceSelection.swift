import Foundation

/// Resolve names deterministically. An ambiguous name must never silently
/// send speech using whichever voice happened to be returned first.
enum VoiceSelection {
    struct Failure: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    struct BotDefault: Identifiable {
        let id = UUID()
        var name: String
        var voice: String
    }

    static func botDefaults(count: Int, voices: [(id: String, name: String)], existingNames: [String]) -> [BotDefault] {
        var used = Set(existingNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var selectedVoices: Set<String> = []
        let available = voices.map { (id: $0.id, name: ElevenLabsVoice.shortName(from: $0.name)) }
            .shuffled().filter { !$0.name.isEmpty }
        return (0..<count).map { index in
            let chosen = available.first { !used.contains(String($0.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)).lowercased()) }
                ?? available.first { !selectedVoices.contains($0.id) }
                ?? (available.isEmpty ? nil : available[index % available.count])
            let base = String((chosen?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "BotSpeaker").prefix(100))
            var name = base
            var suffix = 2
            while used.contains(name.lowercased()) {
                let ending = " \(suffix)"
                name = String(base.prefix(100 - ending.count)) + ending
                suffix += 1
            }
            used.insert(name.lowercased())
            if let chosen { selectedVoices.insert(chosen.id) }
            return BotDefault(name: name, voice: chosen?.id ?? "")
        }
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
