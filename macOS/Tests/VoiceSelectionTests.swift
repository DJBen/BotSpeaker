import Foundation

// The app's simple error wrapper; this harness compiles only the voice client.
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class MockVoicesProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var pages: [String] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let body = Self.pages.isEmpty ? "{}" : Self.pages.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct VoiceSelectionTests {
    static func check(_ condition: @autoclosure () throws -> Bool) rethrows {
        let passed = try condition()
        assert(passed)
    }

    static func main() async throws {
        let voices = [(id: "id-adam", name: "Adam"), (id: "id-adam-two", name: "Adam - Warm"),
                      (id: "id-alice", name: "Alice"), (id: "id-twin-one", name: "Twin"),
                      (id: "id-twin-two", name: "TWIN")]
        for empty in [nil, "", "  ", "Default"] as [String?] {
            try check(VoiceSelection.resolve(empty, voices: voices) == nil)
        }
        try check(VoiceSelection.resolve("id-adam-two", voices: voices) == "id-adam-two")
        try check(VoiceSelection.resolve(" adam ", voices: voices) == "id-adam")
        try check(VoiceSelection.resolve("warm", voices: voices) == "id-adam-two")
        try check(VoiceSelection.resolve("1234567890ABCDEFGHIJ", voices: voices) == "1234567890ABCDEFGHIJ")
        for (query, code) in [("a", "ambiguous_voice"), ("twin", "ambiguous_voice"), ("not-a-voice", "not_found")] {
            do { _ = try VoiceSelection.resolve(query, voices: voices); fatalError("Accepted \(query)") }
            catch let error as VoiceSelection.Failure { assert(error.code == code) }
        }
        print("PASS: empty/default, ID, exact/partial names, unknown IDs, ambiguity, and missing voices")

        let catalog = (1...6).map { (id: "voice-\($0)", name: "Voice \($0)") }
        for _ in 0..<20 {
            let defaults = VoiceSelection.botDefaults(count: 5, voices: catalog, existingNames: [" voice 1 "])
            assert(defaults.count == 5)
            assert(Set(defaults.map(\.name)).count == 5)
            assert(Set(defaults.map(\.voice)).count == 5)
            assert(defaults.allSatisfy { item in catalog.contains { $0.id == item.voice && $0.name == item.name } && item.name != "Voice 1" })
            let mostlyUsed = VoiceSelection.botDefaults(count: 5, voices: catalog, existingNames: Array(catalog.dropFirst().map(\.name)))
            assert(Set(mostlyUsed.map(\.voice)).count == 5)
            let single = VoiceSelection.botDefaults(count: 1, voices: catalog, existingNames: Array(catalog.dropFirst().map(\.name)))
            assert(single[0].name == "Voice 1" && single[0].voice == "voice-1")
        }
        let described = [(id: "alice", name: "Alice - Clear, Engaging Educator"),
                         (id: "brian", name: "Brian — Deep, Resonant"),
                         (id: "mary", name: "Mary-Jane - Friendly — American"),
                         (id: "jean", name: "Jean Luc - Warm"),
                         (id: "zoe", name: "Zoe")]
        let bareNames = ["alice": "Alice", "brian": "Brian", "mary": "Mary-Jane", "jean": "Jean Luc", "zoe": "Zoe"]
        for count in [1, 5] {
            let defaults = VoiceSelection.botDefaults(count: count, voices: described, existingNames: [])
            assert(defaults.count == count)
            assert(defaults.allSatisfy { bareNames[$0.voice] == $0.name })
        }
        let unusedShortName = VoiceSelection.botDefaults(count: 1, voices: described, existingNames: ["Alice", "Brian", "Mary-Jane", "Jean Luc"])
        assert(unusedShortName[0].name == "Zoe" && unusedShortName[0].voice == "zoe")
        print("PASS: single and five-bot names omit descriptions, preserve compound names and voice IDs, and avoid existing short names")
        let empty = VoiceSelection.botDefaults(count: 5, voices: [], existingNames: ["BotSpeaker"])
        assert(Set(empty.map(\.name)).count == 5 && empty.allSatisfy { $0.voice.isEmpty && $0.name != "BotSpeaker" })
        let duplicates = VoiceSelection.botDefaults(count: 5, voices: [("a", "Twin"), ("b", "TWIN")], existingNames: ["twin"])
        assert(Set(duplicates.map { $0.name.lowercased() }).count == 5)
        let longName = String(repeating: "x", count: 120)
        let longDefaults = VoiceSelection.botDefaults(count: 5, voices: [("a", longName)], existingNames: [])
        assert(longDefaults.allSatisfy { $0.name.count <= 100 } && Set(longDefaults.map(\.name)).count == 5)
        print("PASS: bot defaults avoid existing names, bind distinct voices, and handle exhausted, empty, duplicate, and long names")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockVoicesProtocol.self]
        let client = ElevenLabsClient(session: URLSession(configuration: configuration))
        MockVoicesProtocol.pages = [
            #"{"voices":[{"voice_id":"b","name":"Zoe"}],"has_more":true,"next_page_token":"a+b/="}"#,
            #"{"voices":[{"voice_id":"a","name":"Alice","labels":null},{"voice_id":"b","name":"Zoe"}],"has_more":false}"#
        ]
        let list = try await client.listVoices(apiKey: "test-key")
        assert(list.map(\.id) == ["a", "b"])
        let query = URLComponents(url: MockVoicesProtocol.requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        assert(query.first(where: { $0.name == "next_page_token" })?.value == "a+b/=")
        assert(MockVoicesProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "xi-api-key") == "test-key" })
        print("PASS: paginated voice catalog, token encoding, deduplication, sorting, optional labels")
        for pages in [
            [#"{"voices":[],"has_more":true}"#],
            [#"{"voices":[],"has_more":true,"next_page_token":"repeat"}"#,
             #"{"voices":[],"has_more":true,"next_page_token":"repeat"}"#]
        ] {
            MockVoicesProtocol.pages = pages
            do { _ = try await client.listVoices(apiKey: "test-key"); fatalError("Accepted broken pagination") }
            catch is AppError {}
        }
        print("PASS: missing/repeated pagination tokens fail instead of truncating or looping")
    }
}
