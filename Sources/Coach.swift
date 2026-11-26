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
                    You are a friendly drum teacher talking to your student right after they played. \
                    Talk like a real person out loud: casual, warm, short, contractions, no lists, no emojis, \
                    no markdown, no headings. Two sentences max. Don't read the numbers back like a report; \
                    mention at most one number. First say naturally whether they passed the step, \
                    then give one simple feel-based tip. Early kicks mean rushing, late kicks mean dragging.
                    """,
                    generateParameters: GenerateParameters(maxTokens: 60, temperature: 0.8))
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
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        u.pitchMultiplier = 1.0
        u.preUtteranceDelay = 0.2
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
        func pick(_ o: [String]) -> String { o.randomElement()! }
        var parts: [String] = []
        let clean = s.cleanReps ?? s.reps
        let pct = s.reps > 0 ? Double(clean) / Double(s.reps) : 0

        if let o = s.outcome {
            if o.wrongTempo {
                parts.append(pick(["Hang on, that wasn't at \(o.stepBPM), so it won't count toward your step.",
                                   "Heads up, your step is at \(o.stepBPM). Set it back there and go again."]))
            } else if o.goalComplete {
                parts.append(pick(["That's it, you just finished the whole goal. Seriously, nice work.",
                                   "Goal done! You climbed the whole ladder. Be proud of that one."]))
            } else if o.passed {
                parts.append(pick(["Nice, that's a pass! Let's bump it up to \(o.nextBPM ?? o.stepBPM).",
                                   "You got it. Step passed, so next time we're going to \(o.nextBPM ?? o.stepBPM).",
                                   "That was solid. You earned the next step, \(o.nextBPM ?? o.stepBPM)."]))
            } else if o.got >= o.needed - 2 {
                parts.append(pick(["So close. \(o.got) out of \(o.needed). One more round and you've got it.",
                                   "Almost there, just a couple short. Run it again at \(o.stepBPM)."]))
            } else {
                parts.append(pick(["Not quite yet. \(o.got) out of \(o.needed) clean. Let's stay at \(o.stepBPM) a bit longer.",
                                   "That one was a little rough, and that's fine. We'll keep working \(o.stepBPM)."]))
            }
        } else if s.cleanReps != nil {
            parts.append(pct >= 0.9 ? pick(["That felt really locked in.", "Really clean, nice job."]) :
                         pct >= 0.6 ? pick(["Pretty good overall.", "Decent run, getting there."]) :
                                      pick(["That one got away from you a bit.", "Tough set, let's reset and try again."]))
        } else {
            parts.append(pick(["Nice work, that's \(s.reps) reps at \(s.bpm).", "Good set."]))
        }

        if let m = s.meanSignedMs, abs(m) >= 8 {
            parts.append(m > 0
                ? pick(["You're sitting a little behind the beat, so lean forward just a touch.",
                        "You're dragging slightly. Think about landing right on top of the click."])
                : pick(["You're rushing a bit. Relax and let the beat come to you.",
                        "You're a little ahead of the click. Breathe and sit back into it."]))
        } else if s.meanSignedMs != nil, pct >= 0.6 {
            parts.append(pick(["Your timing's right in the pocket.", "Your feel is nice and centered."]))
        }
        if let sp = s.spreadMs, sp > 20 {
            parts.append(pick(["Try to make every kick feel the same.", "Work on keeping each hit even."]))
        }
        return parts.joined(separator: " ")
    }
}
