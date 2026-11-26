import AVFoundation
import SwiftUI
import MLXLLM
import MLXLMCommon

/// Facts about one finished session, used for the spoken verdict.
struct SessionSummary {
    let bpm: Int
    let reps: Int
    let cleanReps: Int?        // nil when Kick check was off
    let meanSignedMs: Double?  // + = late (dragging), − = early (rushing)
    let spreadMs: Double?
    let missed: Int
    let outcome: StepOutcome?
}

/// Speaks a verdict after every session. Uses an on-device Qwen model when downloaded,
/// otherwise a built-in rule-based verdict (works offline, no download).
@MainActor
final class Coach: ObservableObject {
    enum State: Equatable { case off, downloading(Double), loading, ready, failed(String) }

    static let modelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    @Published var verdictOn = UserDefaults.standard.object(forKey: "verdictOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(verdictOn, forKey: "verdictOn") }
    }
    @Published var aiOn = UserDefaults.standard.bool(forKey: "aiCoachOn") {
        didSet { UserDefaults.standard.set(aiOn, forKey: "aiCoachOn"); if aiOn { prepare() } }
    }
    @Published private(set) var state: State = .off
    @Published private(set) var lastMessage: String?
    @Published private(set) var thinking = false

    private var container: ModelContainer?
    private let voice = AVSpeechSynthesizer()

    init() { if aiOn { prepare() } }

    /// Download (first time, ~900 MB) and load the model.
    func prepare() {
        guard container == nil, state != .loading else { return }
        if case .downloading = state { return }
        state = .downloading(0)
        Task {
            do {
                let c = try await loadModelContainer(id: Self.modelID) { p in
                    Task { @MainActor in
                        self.state = p.fractionCompleted < 1 ? .downloading(p.fractionCompleted) : .loading
                    }
                }
                container = c
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func speakVerdict(_ s: SessionSummary) {
        guard verdictOn else { return }
        let rule = ruleVerdict(s)
        guard aiOn, let c = container else { say(rule); return }
        thinking = true
        Task {
            defer { thinking = false }
            do {
                let session = ChatSession(
                    c,
                    instructions: """
                    You are an encouraging but honest drum coach. Reply with at most two short spoken sentences, \
                    no lists, no emojis, no markdown. Always say first whether the step was passed. \
                    Give one concrete tip from the numbers. Rushing means kicks are early; dragging means late.
                    """,
                    generateParameters: GenerateParameters(maxTokens: 70, temperature: 0.5))
                let reply = try await session.respond(to: facts(s))
                let clean = reply.replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                say(clean.isEmpty ? rule : clean)
            } catch {
                say(rule)
            }
        }
    }

    func test() {
        speakVerdict(SessionSummary(bpm: 100, reps: 10, cleanReps: 8, meanSignedMs: -12, spreadMs: 9, missed: 1,
                                    outcome: StepOutcome(goalName: "Test", stepBPM: 100, needed: 10, got: 8,
                                                         passed: false, wrongTempo: false, nextBPM: nil, goalComplete: false)))
    }

    private func say(_ text: String) {
        lastMessage = text
        voice.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AppVoice.current
        voice.speak(u)
    }

    // MARK: Text

    private func facts(_ s: SessionSummary) -> String {
        var f = ["Tempo: \(s.bpm) BPM.", "Reps played: \(s.reps)."]
        if let c = s.cleanReps { f.append("Clean reps: \(c) of \(s.reps).") }
        if s.missed > 0 { f.append("Missed kicks: \(s.missed).") }
        if let m = s.meanSignedMs {
            f.append(abs(m) < 5 ? "Average timing: centered." :
                        "Average timing: \(Int(abs(m))) ms \(m > 0 ? "late (dragging)" : "early (rushing)").")
        }
        if let sp = s.spreadMs { f.append("Consistency spread: plus or minus \(Int(sp)) ms.") }
        if let o = s.outcome {
            if o.wrongTempo { f.append("Played at the wrong tempo for the current step (\(o.stepBPM) BPM); not counted.") }
            else if o.goalComplete { f.append("Step passed and the whole goal is complete.") }
            else if o.passed { f.append("Step passed. Next step: \(o.nextBPM ?? o.stepBPM) BPM.") }
            else { f.append("Step not passed: needed \(o.needed) clean reps, got \(o.got). Stay at \(o.stepBPM) BPM.") }
        }
        return f.joined(separator: " ")
    }

    private func ruleVerdict(_ s: SessionSummary) -> String {
        var parts: [String] = []
        if let o = s.outcome {
            if o.wrongTempo {
                parts.append("That was not at your step tempo of \(o.stepBPM), so it didn't count.")
            } else if o.goalComplete {
                parts.append("Step passed. You finished the whole goal. Great work!")
            } else if o.passed {
                parts.append("Step passed! \(o.got) clean reps. Next up, \(o.nextBPM ?? o.stepBPM) BPM.")
            } else {
                parts.append("Not yet. \(o.got) of \(o.needed) clean reps. Stay at \(o.stepBPM).")
            }
        } else if let c = s.cleanReps {
            let pct = s.reps > 0 ? Double(c) / Double(s.reps) : 0
            parts.append(pct >= 0.9 ? "Excellent. \(c) of \(s.reps) clean." :
                         pct >= 0.6 ? "Good. \(c) of \(s.reps) clean." :
                                      "Rough one. Only \(c) of \(s.reps) clean.")
        } else {
            parts.append("\(s.reps) reps at \(s.bpm).")
        }
        if let m = s.meanSignedMs, abs(m) >= 8 {
            parts.append(m > 0 ? "You're dragging about \(Int(m)) milliseconds. Push a little."
                               : "You're rushing about \(Int(-m)) milliseconds. Relax and sit back.")
        } else if s.meanSignedMs != nil {
            parts.append("Your timing is centered.")
        }
        if let sp = s.spreadMs, sp > 20 { parts.append("Work on keeping each kick the same.") }
        return parts.joined(separator: " ")
    }
}
