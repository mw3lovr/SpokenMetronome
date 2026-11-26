import AVFoundation

/// The voice used everywhere in the app (counts, count-down, coach).
enum AppVoice {
    static let key = "voiceIdentifier"

    static var current: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: key), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return best ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// English voices installed on this phone, best quality first.
    static var english: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0, $0.name) > ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0, $1.name) }
    }

    static var best: AVSpeechSynthesisVoice? {
        english.first { $0.quality != .default }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium: q = "Premium"
        case .enhanced: q = "Enhanced"
        default: q = "Basic"
        }
        let region = v.language.replacingOccurrences(of: "en-", with: "")
        return "\(v.name) · \(region) · \(q)"
    }
}
