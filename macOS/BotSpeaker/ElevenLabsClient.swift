import CryptoKit
import Foundation

struct ElevenLabsClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(apiKey: String) async throws {
        var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")!
        components.queryItems = [
            URLQueryItem(name: "page_size", value: "1"),
            URLQueryItem(name: "include_total_count", value: "false")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func listVoices(apiKey: String) async throws -> [ElevenLabsVoice] {
        var voices: [ElevenLabsVoice] = []
        var nextPageToken: String?

        repeat {
            var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")!
            var queryItems = [
                URLQueryItem(name: "page_size", value: "100"),
                URLQueryItem(name: "sort", value: "name"),
                URLQueryItem(name: "sort_direction", value: "asc"),
                URLQueryItem(name: "include_total_count", value: "false")
            ]
            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "next_page_token", value: nextPageToken))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            let page = try JSONDecoder().decode(VoicePage.self, from: data)
            voices.append(contentsOf: page.voices)
            nextPageToken = page.hasMore ? page.nextPageToken : nil
        } while nextPageToken != nil

        return voices
            .reduce(into: [String: ElevenLabsVoice]()) { $0[$1.id] = $1 }
            .values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func synthesize(
        text: String,
        voiceID: String,
        modelID: String,
        apiKey: String,
        previousText: String? = nil,
        nextText: String? = nil,
        cacheNamespace: String,
        bypassCache: Bool = false
    ) async throws -> SpeechClip {
        let cache = try cacheURLs(
            text: text,
            voiceID: voiceID,
            modelID: modelID,
            previousText: previousText,
            nextText: nextText,
            namespace: cacheNamespace
        )
        if !bypassCache,
           FileManager.default.fileExists(atPath: cache.audio.path),
           let timingData = try? Data(contentsOf: cache.timing),
           let timing = try? JSONDecoder().decode(SpeechTiming.self, from: timingData) {
            return SpeechClip(audioURL: cache.audio, timing: timing)
        }

        let encodedVoiceID = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceID
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(encodedVoiceID)/with-timestamps?output_format=mp3_44100_128")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(SpeechRequest(
            text: text,
            modelID: modelID,
            previousText: previousText,
            nextText: nextText
        ))

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let responseBody = try JSONDecoder().decode(TimedSpeechResponse.self, from: data)
        guard let audioData = Data(base64Encoded: responseBody.audioBase64), !audioData.isEmpty else {
            throw AppError("ElevenLabs returned invalid audio data.")
        }
        let timing = SpeechTiming(
            alignment: responseBody.alignment ?? responseBody.normalizedAlignment,
            sourceText: text
        )
        try audioData.write(to: cache.audio, options: .atomic)
        try JSONEncoder().encode(timing).write(to: cache.timing, options: .atomic)
        return SpeechClip(audioURL: cache.audio, timing: timing)
    }

    private func cacheURLs(
        text: String,
        voiceID: String,
        modelID: String,
        previousText: String?,
        nextText: String?,
        namespace: String
    ) throws -> (audio: URL, timing: URL) {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("BotSpeaker/Audio", isDirectory: true)
            .appendingPathComponent(safeCacheComponent(namespace), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(
            "\(voiceID)|\(modelID)|\(previousText ?? "")|\(text)|\(nextText ?? "")".utf8
        ))
            .map { String(format: "%02x", $0) }
            .joined()
        let stem = base.appendingPathComponent(digest)
        return (
            stem.appendingPathExtension("mp3"),
            stem.appendingPathExtension("timing.json")
        )
    }

    private func safeCacheComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(cleaned).replacingOccurrences(of: "--", with: "-")
        return result.isEmpty ? "unnamed-script" : String(result.prefix(100))
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw AppError("ElevenLabs returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = data.flatMap { try? JSONDecoder().decode(APIErrorEnvelope.self, from: $0) }
            let message = detail?.detail.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AppError("ElevenLabs: \(message)")
        }
    }
}

struct SpeechClip {
    let audioURL: URL
    let timing: SpeechTiming
}

struct SpeechTiming: Codable {
    let wordBoundaries: [TimeInterval]
    let sentenceBoundaries: [TimeInterval]
    let characterEndTimes: [TimeInterval]
    let characterUTF16Offsets: [Int]
    let sentenceSpans: [TimedTextSpan]

    init(
        wordBoundaries: [TimeInterval] = [],
        sentenceBoundaries: [TimeInterval] = [],
        characterEndTimes: [TimeInterval] = [],
        characterUTF16Offsets: [Int] = [],
        sentenceSpans: [TimedTextSpan] = []
    ) {
        self.wordBoundaries = wordBoundaries
        self.sentenceBoundaries = sentenceBoundaries
        self.characterEndTimes = characterEndTimes
        self.characterUTF16Offsets = characterUTF16Offsets
        self.sentenceSpans = sentenceSpans
    }

    fileprivate init(alignment: SpeechAlignment?, sourceText: String) {
        guard let alignment else {
            self.init()
            return
        }

        let count = min(alignment.characters.count, alignment.characterEndTimes.count)
        var words: [TimeInterval] = []
        var sentences: [TimeInterval] = []
        var characterTimes: [TimeInterval] = []
        var characterOffsets: [Int] = []
        var sentenceSpans: [TimedTextSpan] = []
        var utf16Offset = 0
        var sentenceStartOffset = 0
        var sentenceStartTime: TimeInterval = 0
        let sourceUTF16Length = sourceText.utf16.count
        let sentenceTerminators = CharacterSet(charactersIn: ".!?;:\n")

        for index in 0..<count {
            let character = alignment.characters[index]
            let time = alignment.characterEndTimes[index]
            utf16Offset = min(utf16Offset + character.utf16.count, sourceUTF16Length)
            characterTimes.append(time)
            characterOffsets.append(utf16Offset)
            if character.rangeOfCharacter(from: sentenceTerminators) != nil {
                sentences.append(time)
                words.append(time)
                if utf16Offset > sentenceStartOffset {
                    sentenceSpans.append(TimedTextSpan(
                        startTime: sentenceStartTime,
                        endTime: time,
                        location: sentenceStartOffset,
                        length: utf16Offset - sentenceStartOffset
                    ))
                }
                sentenceStartOffset = utf16Offset
                sentenceStartTime = time
            } else if character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil, index > 0 {
                words.append(alignment.characterEndTimes[index - 1])
            }
        }

        if sentenceStartOffset < sourceUTF16Length {
            sentenceSpans.append(TimedTextSpan(
                startTime: sentenceStartTime,
                endTime: alignment.characterEndTimes.prefix(count).last ?? sentenceStartTime,
                location: sentenceStartOffset,
                length: sourceUTF16Length - sentenceStartOffset
            ))
        }

        self.init(
            wordBoundaries: Array(Set(words)).sorted(),
            sentenceBoundaries: Array(Set(sentences)).sorted(),
            characterEndTimes: characterTimes,
            characterUTF16Offsets: characterOffsets,
            sentenceSpans: sentenceSpans
        )
    }

    func playedUTF16Offset(at time: TimeInterval) -> Int {
        guard !characterEndTimes.isEmpty else { return 0 }
        var lower = 0
        var upper = characterEndTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if characterEndTimes[middle] <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0, lower - 1 < characterUTF16Offsets.count else { return 0 }
        return characterUTF16Offsets[lower - 1]
    }
}

struct TimedTextSpan: Codable, Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let location: Int
    let length: Int
}

private struct TimedSpeechResponse: Decodable {
    let audioBase64: String
    let alignment: SpeechAlignment?
    let normalizedAlignment: SpeechAlignment?

    enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base64"
        case alignment
        case normalizedAlignment = "normalized_alignment"
    }
}

private struct SpeechAlignment: Decodable {
    let characters: [String]
    let characterStartTimes: [TimeInterval]
    let characterEndTimes: [TimeInterval]

    enum CodingKeys: String, CodingKey {
        case characters
        case characterStartTimes = "character_start_times_seconds"
        case characterEndTimes = "character_end_times_seconds"
    }
}

struct ElevenLabsVoice: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let category: String?
    let description: String?
    let labels: [String: String]

    var detail: String {
        [labels["accent"], labels["gender"], labels["use_case"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case id = "voice_id"
        case name, category, description, labels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}

private struct VoicePage: Decodable {
    let voices: [ElevenLabsVoice]
    let hasMore: Bool
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case voices
        case hasMore = "has_more"
        case nextPageToken = "next_page_token"
    }
}

private struct SpeechRequest: Encodable {
    let text: String
    let modelID: String
    let previousText: String?
    let nextText: String?

    enum CodingKeys: String, CodingKey {
        case text
        case modelID = "model_id"
        case previousText = "previous_text"
        case nextText = "next_text"
    }
}

private struct APIErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String }
    let detail: Detail
}
