import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class SynthesisProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var active = 0
    nonisolated(unsafe) static var peak = 0
    nonisolated(unsafe) static var started = 0
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.active += 1
        Self.started += 1
        Self.peak = max(Self.peak, Self.active)
        let shouldFail = Self.started == 1
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
            Self.lock.lock()
            guard !finished else { Self.lock.unlock(); return }
            finished = true
            Self.active -= 1
            Self.lock.unlock()
            if shouldFail {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                let body = #"{"audio_base64":"YXVkaW8="}"#
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if !finished { finished = true; Self.active -= 1 }
    }
    static func counts() -> (active: Int, peak: Int, started: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (active, peak, started)
    }
}

@main
struct SynthesisQueueTests {
    static func retryTests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetryProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let namespace = "retry-tests-" + UUID().uuidString
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BotSpeaker/Audio/" + namespace)
        defer { try? FileManager.default.removeItem(at: cache) }
        func run(_ statuses: [Int], cancelOnDelay: Bool = false) async throws {
            RetryProtocol.statuses = statuses
            RetryProtocol.calls = 0
            _ = try await ElevenLabsClient(session: session, retrySleep: { delay in
                assert(delay >= 2) // Retry-After is honored, including on the first attempt.
                if cancelOnDelay { throw CancellationError() }
            }).synthesize(text: UUID().uuidString, voiceID: "test", modelID: "test",
                          apiKey: "test", cacheNamespace: namespace)
        }
        try await run([429, 503, 200])
        assert(RetryProtocol.calls == 3)
        for code in [400, 401, 403, 422] {
            do { try await run([code, 200]); fatalError("Permanent error was retried") }
            catch is AppError { assert(RetryProtocol.calls == 1) }
        }
        do { try await run([503, 503, 503, 503, 200]); fatalError("Retry limit ignored") }
        catch let error as AppError {
            assert(RetryProtocol.calls == 4)
            assert(error.message.contains("fixture"))
        }
        do { try await run([429, 200], cancelOnDelay: true); fatalError("Backoff cancellation ignored") }
        catch is CancellationError { assert(RetryProtocol.calls == 1) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": formatter.string(from: Date().addingTimeInterval(30))])!
        assert(ElevenLabsClient.retryDelay(attempt: 0, response: response) > 28)
        for attempt in 0..<3 {
            let delay = ElevenLabsClient.retryDelay(attempt: attempt)
            assert(delay >= pow(2, Double(attempt)) && delay <= pow(2, Double(attempt)) + 0.25)
        }
        print("PASS: transient HTTP retries, Retry-After seconds/date, backoff, permanent errors, exhaustion, cancellation")
    }

    static func main() async throws {
        // A cancelled waiter must finish while the only slot remains occupied.
        let queue = SpeechSynthesisQueue(limit: 1)
        try await queue.acquire()
        let cancelled = Task { try await queue.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        do { try await cancelled.value; fatalError("Cancelled waiter acquired a slot") }
        catch is CancellationError {}
        await queue.release()
        try await queue.acquire()
        await queue.release()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SynthesisProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let namespace = "synthesis-queue-test-" + UUID().uuidString
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BotSpeaker/Audio/" + namespace)
        defer { try? FileManager.default.removeItem(at: cache) }
        // Separate client instances must still share the same six slots.
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<24 {
                group.addTask {
                    do {
                        _ = try await ElevenLabsClient(session: session).synthesize(
                            text: "Speech \(index)", voiceID: "test", modelID: "test",
                            apiKey: "test", cacheNamespace: namespace)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        let counts = SynthesisProtocol.counts()
        assert(successes == 24, "A transient failure must retry successfully")
        assert(counts.started == 25)
        assert(counts.peak == 6, "Requests must share a maximum of six active slots")
        assert(counts.active == 0)
        try await retryTests()
        print("Synthesis queue tests passed (24 requests, peak concurrency 6, failure recovery and cancellation).")
    }
}

final class RetryProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.statuses.removeFirst()
        Self.calls += 1
        let body = status == 200 ? #"{"audio_base64":"YXVkaW8="}"# : #"{"detail":{"message":"fixture"}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Retry-After": "2"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
