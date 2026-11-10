import Foundation
import Security
import CryptoKit
import BinisoftKit

/// Natural-sounding coach voice through ElevenLabs, with the user's own API key (kept in the
/// device's Keychain, never synced or sent anywhere else). Phrases are cached on the device, so a
/// line is generated once; anything that isn't ready in time falls back to the iPhone voice.
actor NaturalVoice {
    static let shared = NaturalVoice()

    struct Voice: Identifiable, Hashable, Decodable {
        let voice_id: String
        let name: String
        let labels: [String: String]?
        let preview_url: String?
        var id: String { voice_id }
        var summary: String {
            [labels?["gender"], labels?["accent"], labels?["description"] ?? labels?["descriptive"], labels?["use_case"]]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Deep, energetic male voice from ElevenLabs' default library.
    static let defaultVoiceID = "nPczCjzI2devNBz1zQrb"
    static let model = "eleven_turbo_v2_5"

    private var inFlight: [String: Task<URL?, Never>] = [:]

    // MARK: Key

    private static let keychainService = "at.binisoft.george.elevenlabs"

    nonisolated static var hasKey: Bool { apiKey != nil }

    nonisolated static var apiKey: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Stores (or with nil, removes) the key – only on this device (not in iCloud Keychain).
    nonisolated static func setAPIKey(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    nonisolated static var voiceID: String {
        UserDefaults.standard.string(forKey: Prefs.naturalVoiceID) ?? defaultVoiceID
    }

    // MARK: Audio

    /// The cached or freshly generated audio for `text`, or nil when it isn't ready within `timeout`.
    func audioFile(for text: String, timeout: Double) async -> URL? {
        let task = request(text)
        return await withTaskGroup(of: URL?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Starts generating `text` so it's ready when it's needed.
    func prefetch(_ text: String) {
        _ = request(text)
    }

    private func request(_ text: String) -> Task<URL?, Never> {
        let file = Self.cacheFile(for: text)
        if let existing = inFlight[file.lastPathComponent] { return existing }
        let task = Task<URL?, Never> {
            if FileManager.default.fileExists(atPath: file.path) { return file }
            do {
                let data = try await Self.synthesize(text)
                try data.write(to: file, options: .atomic)
                return file
            } catch {
                AppLog.warning("Natural voice: \(error.localizedDescription)", category: "voice")
                return nil
            }
        }
        inFlight[file.lastPathComponent] = task
        Task { _ = await task.value; self.finished(file.lastPathComponent) }
        return task
    }

    private func finished(_ name: String) { inFlight[name] = nil }

    private static func synthesize(_ text: String) async throws -> Data {
        guard let key = apiKey else { throw URLError(.userAuthenticationRequired) }
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.4, "similarity_boost": 0.8, "style": 0.45, "use_speaker_boost": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "ElevenLabs", code: status, userInfo: [NSLocalizedDescriptionKey: "ElevenLabs answered \(status)"])
        }
        return data
    }

    /// The voices of the account (default library + your own).
    static func voices() async throws -> [Voice] {
        guard let key = apiKey else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ElevenLabs", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't load the voices – check the API key."])
        }
        struct List: Decodable { let voices: [Voice] }
        return try JSONDecoder().decode(List.self, from: data).voices
    }

    /// Cached phrases: Caches/CoachVoice/<voice>-<hash>.mp3.
    nonisolated static func cacheFile(for text: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent("CoachVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data((voiceID + "|" + model + "|" + text).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(24)) + ".mp3")
    }

    nonisolated static func clearCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let directory = caches?.appendingPathComponent("CoachVoice", isDirectory: true) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
