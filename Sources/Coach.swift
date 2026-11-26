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
                    then give honest constructive criticism: name the one biggest problem and one specific way \
                    to practice it (for example slowing down 10 BPM, counting out loud, relaxing the ankle). \
                    Don't only praise, even on a good run. Early kicks mean rushing, late kicks mean dragging. \
                    Never claim you changed anything. Never use headings or labels. \
                    Example reply: "Not quite, eight of ten clean. You're rushing a little, so relax your ankle and let the click come to you."
                    """,
                    generateParameters: GenerateParameters(maxTokens: 50, temperature: 0.5))
                let reply = try await session.respond(to: facts(s))
                say(Self.tidy(reply) ?? rule)
            } catch {
                say(rule)
            }
        }
    }

    /// Keep the model to two short spoken sentences; nil means fall back to the built-in coach.
    static func tidy(_ raw: String) -> String? {
        var t = raw.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let bad = ["adjust", "i've made", "i have made", "should not be changed", "feedback on", "here is", "here's your",
                   "tempo:", "consistency:", "summary", "report"]
        if t.isEmpty || bad.contains(where: lower.contains) || t.contains(":") { return nil }
        var sentences: [String] = []
        t.enumerateSubstrings(in: t.startIndex..., options: .bySentences) { sub, _, _, stop in
            if let sub { sentences.append(sub.trimmingCharacters(in: .whitespaces)) }
            if sentences.count == 2 { stop = true }
        }
        t = sentences.joined(separator: " ")
        if t.split(separator: " ").count > 45 || t.count < 10 { return nil }
        return t
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
                parts.append(pick(["So close, \(o.got) out of \(o.needed).",
                                   "Almost there, just a couple short."]))
            } else {
                parts.append(pick(["Not quite yet, \(o.got) out of \(o.needed) clean.",
                                   "That one was a little rough, and that's fine."]))
            }
        } else if s.cleanReps != nil {
            parts.append(pct >= 0.9 ? pick(["That felt really locked in.", "Really clean, nice job."]) :
                         pct >= 0.6 ? pick(["Pretty good overall.", "Decent run, getting there."]) :
                                      pick(["That one got away from you a bit.", "Tough set, let's reset and try again."]))
        } else {
            parts.append(pick(["Nice work, that's \(s.reps) reps at \(s.bpm).", "Good set."]))
        }

        // Constructive criticism: always one specific fix and how to practice it.
        let slower = max(30, (s.outcome?.stepBPM ?? s.bpm) - 10)
        if s.missed > 0 {
            parts.append(pick(["You dropped \(s.missed) kick\(s.missed == 1 ? "" : "s"). Slow it down to \(slower) and make sure every single one lands before speeding back up.",
                               "A few kicks went missing. Count the pattern out loud while you play so you don't lose your place."]))
        } else if let m = s.meanSignedMs, abs(m) >= 8 {
            parts.append(m > 0
                ? pick(["The main thing: you're landing late, about \(Int(m)) milliseconds behind. Try playing the next round with your heel up and think of hitting right on top of the click.",
                        "You're dragging, so the kicks sit just behind the beat. Turn on click only, and aim to bury the click under your kick."])
                : pick(["The main thing: you're rushing, about \(Int(-m)) milliseconds early. Relax your ankle, breathe out, and let the click come to you.",
                        "You're jumping ahead of the click. Do a set at \(slower) and focus on waiting for each beat."]))
        } else if let sp = s.spreadMs, sp > 15 {
            parts.append(pick(["Your average is fine, but the hits are uneven, some early, some late. Do a round at \(slower) and make every kick feel identical.",
                               "Consistency is the thing to work on. Keep the same motion and volume on every kick."]))
        } else if s.cleanReps == nil {
            parts.append("Turn on kick check next time so I can tell you exactly what to fix.")
        } else if pct < 1 {
            parts.append(pick(["To tighten it up, keep your foot relaxed between hits instead of resting it on the head.",
                               "Next, try it with click only and no voice, so you're relying on your own counting."]))
        } else {
            parts.append(pick(["Perfect run. To push yourself, try it once at \(s.bpm + 5) to stretch your control.",
                               "Flawless. Now try it with the click on 8ths only and keep that same feel."]))
        }
        return parts.joined(separator: " ")
    }
}
