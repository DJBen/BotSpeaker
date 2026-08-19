import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var text = ExampleExcerpt.incidentManager.text
    @Published private(set) var selectedScriptID = ExampleExcerpt.incidentManager.speechScript.id
    @Published private(set) var customScripts: [CustomSpeechScript] = []
    @Published var templateSpeakerName = ""
    @Published var scriptDraftTitle = ""
    @Published var scriptDraftText = ""
    @Published private(set) var editingCustomScriptID: UUID?
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published private(set) var hasAPIKey = false
    @Published private(set) var voices: [ElevenLabsVoice] = []
    @Published private(set) var isLoadingVoices = false
    @Published private(set) var voiceLoadError: String?
    /// Result of the most recent manual device refresh, shown next to the refresh button.
    @Published private(set) var deviceRefreshFeedback: String?

    let player = AudioPlaybackController()
    let devices = AudioDeviceManager()
    let interruptionMonitor = InterruptionMonitor()

    private let keychain = KeychainStore()
    private let client = ElevenLabsClient()
    private var generationTask: Task<Void, Never>?
    private var generationID = UUID()
    private var currentSpeechSignature: String?

    var bundledScripts: [SpeechScript] {
        ExampleExcerpt.all.map(\.speechScript)
    }

    var bundledScriptGroups: [ExampleScenario] {
        ExampleExcerpt.scenarios
    }

    var availableScripts: [SpeechScript] {
        bundledScripts + customScripts.map {
            SpeechScript(
                id: "custom:\($0.id.uuidString)",
                title: $0.title,
                detail: $0.detail ?? "Custom script",
                text: $0.text,
                kind: .custom($0.id)
            )
        }
    }

    var playableScripts: [SpeechScript] {
        availableScripts.filter(\.isCustom)
    }

    var selectedScript: SpeechScript {
        availableScripts.first(where: { $0.id == selectedScriptID }) ?? ExampleExcerpt.incidentManager.speechScript
    }

    var voiceID: String {
        get { UserDefaults.standard.string(forKey: Defaults.voiceID) ?? "JBFqnCBsd6RMkjVDRZzb" }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.voiceID); objectWillChange.send() }
    }

    var modelID: String {
        get { UserDefaults.standard.string(forKey: Defaults.modelID) ?? "eleven_flash_v2_5" }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.modelID); objectWillChange.send() }
    }

    var selectedDeviceUID: String {
        get { UserDefaults.standard.string(forKey: Defaults.deviceUID) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Defaults.deviceUID)
            objectWillChange.send()
            try? player.selectOutputDevice(uid: newValue)
        }
    }

    var loopEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Defaults.loopEnabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.loopEnabled); player.isLooping = newValue; objectWillChange.send() }
    }

    var outputVolume: Double {
        get {
            guard UserDefaults.standard.object(forKey: Defaults.outputVolume) != nil else { return 1 }
            return UserDefaults.standard.double(forKey: Defaults.outputVolume)
        }
        set {
            let clamped = min(max(newValue, 0), 1)
            UserDefaults.standard.set(clamped, forKey: Defaults.outputVolume)
            player.volume = Float(clamped)
            objectWillChange.send()
        }
    }

    var interruptionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Defaults.interruptionEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: Defaults.interruptionEnabled)
            objectWillChange.send()
            if newValue {
                Task { await startInterruptionMonitoring() }
            } else {
                interruptionMonitor.stop()
                player.setInterruptionActive(false)
            }
        }
    }

    var interruptionInputUID: String {
        get { UserDefaults.standard.string(forKey: Defaults.interruptionInputUID) ?? AudioDeviceManager.defaultInputDeviceUID() ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Defaults.interruptionInputUID)
            objectWillChange.send()
            if interruptionEnabled { Task { await startInterruptionMonitoring() } }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Defaults.customScripts),
           let savedScripts = try? JSONDecoder().decode([CustomSpeechScript].self, from: data) {
            customScripts = savedScripts
        }

        let requestedID = UserDefaults.standard.string(forKey: Defaults.selectedScriptID)
            ?? ExampleExcerpt.incidentManager.speechScript.id
        let initialScript = availableScripts.first(where: { $0.id == requestedID })
            ?? ExampleExcerpt.incidentManager.speechScript
        selectedScriptID = initialScript.id
        text = initialScript.text
        if initialScript.isCustom {
            UserDefaults.standard.set(initialScript.id, forKey: Defaults.lastPlayableScriptID)
        }

        hasAPIKey = (try? keychain.read())?.isEmpty == false
        player.isLooping = loopEnabled
        player.volume = Float(outputVolume)
        devices.refresh()
        interruptionMonitor.onActivityChanged = { [weak self] isActive in
            guard let self else { return }
            self.player.setInterruptionActive(isActive)
        }

        if selectedDeviceUID.isEmpty,
           let blackHole = devices.outputDevices.first(where: { $0.isBlackHole }) {
            selectedDeviceUID = blackHole.uid
        } else if !selectedDeviceUID.isEmpty {
            try? player.selectOutputDevice(uid: selectedDeviceUID)
        }

        if interruptionEnabled {
            Task { await startInterruptionMonitoring() }
        }
    }

    /// Re-scans Core Audio, adopts BlackHole if it just showed up, and reports what happened.
    func refreshAudioDevices() {
        let hadBlackHole = devices.blackHoleStatus == .active
        devices.refresh()

        switch devices.blackHoleStatus {
        case .active:
            if selectedDeviceUID.isEmpty || devices.outputDevices.allSatisfy({ $0.uid != selectedDeviceUID }),
               let blackHole = devices.outputDevices.first(where: { $0.isBlackHole }) {
                selectedDeviceUID = blackHole.uid
            }
            deviceRefreshFeedback = hadBlackHole
                ? "Devices up to date."
                : "BlackHole found and selected."
        case .installedButNotLoaded:
            deviceRefreshFeedback = "Still not loaded — restart Core Audio."
        case .notInstalled:
            deviceRefreshFeedback = "No BlackHole device found."
        }
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError("Enter an ElevenLabs API key.") }
        try keychain.save(trimmed)
        hasAPIKey = true
    }

    func validateAndSaveAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError("Enter an ElevenLabs API key.") }
        try await client.validate(apiKey: trimmed)
        try saveAPIKey(trimmed)
        await refreshVoices()
    }

    func removeAPIKey() throws {
        try keychain.delete()
        hasAPIKey = false
        voices = []
        voiceLoadError = nil
    }

    func loadVoicesIfNeeded() async {
        guard voices.isEmpty, !isLoadingVoices else { return }
        await refreshVoices()
    }

    func refreshVoices() async {
        guard let apiKey = try? keychain.read(), !apiKey.isEmpty else {
            voices = []
            voiceLoadError = "Add an ElevenLabs API key to load voices."
            return
        }

        isLoadingVoices = true
        voiceLoadError = nil
        defer { isLoadingVoices = false }
        do {
            voices = try await client.listVoices(apiKey: apiKey)
            if voices.isEmpty {
                voiceLoadError = "No voices are available for this ElevenLabs account."
            }
        } catch {
            voiceLoadError = error.localizedDescription
        }
    }

    var selectedVoiceName: String {
        voices.first(where: { $0.id == voiceID })?.name ?? "Voice ID \(voiceID.prefix(8))…"
    }

    func selectScript(id: String) {
        guard id != selectedScriptID,
              let script = availableScripts.first(where: { $0.id == id }) else { return }
        cancelGeneration(resetPlayer: true)
        currentSpeechSignature = nil
        errorMessage = nil
        selectedScriptID = script.id
        text = script.text
        UserDefaults.standard.set(script.id, forKey: Defaults.selectedScriptID)
        if script.isCustom {
            UserDefaults.standard.set(script.id, forKey: Defaults.lastPlayableScriptID)
        }
    }

    /// The main window may be browsing a non-playable template. When the menu
    /// bar opens, return to the last saved transcript that was actually used.
    func restoreLastPlayableScriptForMenuBar() {
        guard !selectedScript.isCustom else { return }
        let defaults = UserDefaults.standard
        let requestedID = defaults.string(forKey: Defaults.lastPlayableScriptID)
        let playable = requestedID.flatMap { id in
            playableScripts.first(where: { $0.id == id })
        } ?? playableScripts.first
        guard let playable else { return }
        selectScript(id: playable.id)
    }

    func prepareScriptEditor() {
        if case let .custom(id) = selectedScript.kind,
           let script = customScripts.first(where: { $0.id == id }) {
            editingCustomScriptID = id
            scriptDraftTitle = script.title
            scriptDraftText = script.text
        } else {
            editingCustomScriptID = nil
            scriptDraftTitle = ""
            scriptDraftText = ""
        }
    }

    func prepareNewScript() {
        editingCustomScriptID = nil
        scriptDraftTitle = ""
        scriptDraftText = ""
    }

    func deleteCustomScript(id: UUID) {
        guard let index = customScripts.firstIndex(where: { $0.id == id }) else { return }
        let scriptID = "custom:\(id.uuidString)"
        let wasSelected = selectedScriptID == scriptID

        if wasSelected {
            cancelGeneration(resetPlayer: true)
            currentSpeechSignature = nil
            errorMessage = nil
        }
        customScripts.remove(at: index)
        persistCustomScripts()

        if UserDefaults.standard.string(forKey: Defaults.lastPlayableScriptID) == scriptID {
            if let replacement = customScripts.first {
                UserDefaults.standard.set(
                    "custom:\(replacement.id.uuidString)",
                    forKey: Defaults.lastPlayableScriptID
                )
            } else {
                UserDefaults.standard.removeObject(forKey: Defaults.lastPlayableScriptID)
            }
        }

        if editingCustomScriptID == id {
            editingCustomScriptID = nil
            scriptDraftTitle = ""
            scriptDraftText = ""
        }

        if wasSelected {
            let fallback = customScripts.first.map { "custom:\($0.id.uuidString)" }
                ?? ExampleExcerpt.incidentManager.speechScript.id
            selectScript(id: fallback)
        }
    }

    /// Creates a durable custom script from a built-in role template. Name
    /// substitution happens here once; later playback does not depend on the
    /// sidebar field and receives its own cache namespace.
    func createNamedScriptFromSelectedTemplate() throws {
        guard case .example = selectedScript.kind else {
            throw AppError("Choose a role template first.")
        }
        let name = templateSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError("Enter the speaker’s name.") }

        let template = selectedScript
        let resolvedText = template.text.replacingOccurrences(of: ExampleExcerpt.namePlaceholder, with: name)
        guard resolvedText != template.text else {
            throw AppError("This template does not contain a name placeholder.")
        }

        let id = UUID()
        customScripts.append(
            CustomSpeechScript(
                id: id,
                title: "\(name) — \(template.title)",
                text: resolvedText,
                detail: template.detail
            )
        )
        persistCustomScripts()
        templateSpeakerName = ""
        selectScript(id: "custom:\(id.uuidString)")
    }

    func saveScriptDraft() throws {
        let title = scriptDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let scriptText = scriptDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AppError("Give this script a name.") }
        guard !scriptText.isEmpty else { throw AppError("Add some text to the script.") }

        let id: UUID
        if let editingCustomScriptID,
           let index = customScripts.firstIndex(where: { $0.id == editingCustomScriptID }) {
            id = editingCustomScriptID
            customScripts[index].title = title
            customScripts[index].text = scriptText
        } else {
            id = UUID()
            customScripts.append(CustomSpeechScript(id: id, title: title, text: scriptText, detail: nil))
        }
        persistCustomScripts()

        let scriptID = "custom:\(id.uuidString)"
        if scriptID == selectedScriptID {
            cancelGeneration(resetPlayer: true)
            currentSpeechSignature = nil
            text = scriptText
            errorMessage = nil
        } else {
            selectScript(id: scriptID)
        }
        editingCustomScriptID = id
    }

    func primaryAction() async {
        await generateOrToggle(forceRegenerate: false)
    }

    private func generateOrToggle(forceRegenerate: Bool) async {
        errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Paste some text first."
            return
        }

        let script = selectedScript
        let signature = "\(script.id)|\(voiceID)|\(modelID)|\(trimmed)"
        if !forceRegenerate, currentSpeechSignature == signature, (player.hasAudio || isGenerating) {
            if player.isPlaying || player.isBuffering || player.isWaitingForInterruption {
                player.pause()
            } else {
                player.play()
            }
            return
        }

        guard let apiKey = try? keychain.read(), !apiKey.isEmpty else {
            hasAPIKey = false
            errorMessage = "Add your ElevenLabs API key in Settings."
            return
        }

        guard !selectedDeviceUID.isEmpty else {
            errorMessage = "Choose an audio output in Settings."
            return
        }

        do {
            let plans = SpeechTextChunker.chunks(for: text)
            guard !plans.isEmpty else {
                errorMessage = "Paste some text first."
                return
            }

            cancelGeneration(resetPlayer: false)
            try player.selectOutputDevice(uid: selectedDeviceUID)
            player.isLooping = loopEnabled
            player.beginSequence(totalChunks: plans.count)
            currentSpeechSignature = signature
            isGenerating = true

            let taskID = UUID()
            generationID = taskID
            generationTask = Task { [weak self] in
                guard let self else { return }
                await self.generateSequentially(
                    plans: plans,
                    voiceID: self.voiceID,
                    modelID: self.modelID,
                    apiKey: apiKey,
                    cacheNamespace: script.cacheNamespace,
                    bypassCache: forceRegenerate,
                    taskID: taskID
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func regenerate() async {
        await generateOrToggle(forceRegenerate: true)
    }

    func stop() {
        cancelGeneration(resetPlayer: false)
        player.finishSequence()
        player.stop()
        currentSpeechSignature = nil
    }

    func startInterruptionMonitoring() async {
        await interruptionMonitor.start(inputUID: interruptionInputUID)
    }

    private func generateSequentially(
        plans: [SpeechChunkPlan],
        voiceID: String,
        modelID: String,
        apiKey: String,
        cacheNamespace: String,
        bypassCache: Bool,
        taskID: UUID
    ) async {
        defer {
            if generationID == taskID {
                isGenerating = false
                generationTask = nil
            }
        }

        do {
            for plan in plans {
                try Task.checkCancellation()
                let clip = try await client.synthesize(
                    text: plan.text,
                    voiceID: voiceID,
                    modelID: modelID,
                    apiKey: apiKey,
                    previousText: plan.previousText,
                    nextText: plan.nextText,
                    cacheNamespace: cacheNamespace,
                    bypassCache: bypassCache
                )
                try Task.checkCancellation()
                guard generationID == taskID else { return }
                try player.append(
                    url: clip.audioURL,
                    timing: clip.timing,
                    sourceRange: plan.sourceRange
                )
            }
            guard generationID == taskID else { return }
            player.finishSequence()
        } catch is CancellationError {
            return
        } catch {
            guard generationID == taskID else { return }
            player.finishSequence()
            errorMessage = player.generatedChunkCount > 0
                ? "Generation stopped after \(player.generatedChunkCount) of \(plans.count) sections: \(error.localizedDescription)"
                : error.localizedDescription
        }
    }

    private func cancelGeneration(resetPlayer: Bool) {
        generationTask?.cancel()
        generationTask = nil
        generationID = UUID()
        isGenerating = false
        if resetPlayer { player.reset() }
    }

    private func persistCustomScripts() {
        if let data = try? JSONEncoder().encode(customScripts) {
            UserDefaults.standard.set(data, forKey: Defaults.customScripts)
        }
    }

    private enum Defaults {
        static let voiceID = "voiceID"
        static let modelID = "modelID"
        static let deviceUID = "deviceUID"
        static let loopEnabled = "loopEnabled"
        static let outputVolume = "outputVolume"
        static let interruptionEnabled = "interruptionEnabled"
        static let interruptionInputUID = "interruptionInputUID"
        static let selectedScriptID = "selectedScriptID"
        static let lastPlayableScriptID = "lastPlayableScriptID"
        static let customScripts = "customScripts"
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
