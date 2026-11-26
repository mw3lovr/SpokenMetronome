import AVFoundation
import SwiftUI

/// Sample-accurate metronome: a background timer looks ~150 ms ahead and schedules
/// click and voice buffers on two AVAudioPlayerNodes that share one timeline.
final class MetronomeEngine: ObservableObject {
    @Published var bpm: Double = 100

    func nudge(_ delta: Double) { bpm = min(max(bpm + delta, 30), 280) }
    @Published var signature = TimeSignature.all[0] { didSet { patternChanged() } }
    @Published var subdivision: Subdivision = .quarter { didSet { patternChanged() } }
    @Published var useCustom = false { didSet { patternChanged() } }
    @Published var customBeats: [Subdivision] = [.quarter, .eighth, .sixteenth, .quarter] { didSet { patternChanged() } }
    @Published var voiceOn = true
    @Published var clickOn = true
    @Published var voiceVolume: Float = 1.0
    // Loop / reps
    @Published var loopOn = false
    @Published var reps = 10
    @Published var barsPerRep = 1
    @Published private(set) var barsDone = 0
    var repsDone: Int { barsDone / max(barsPerRep, 1) }
    /// Called when playback ends (finished loop or manual stop) with bars completed.
    var onSessionEnd: ((_ bars: Int, _ finished: Bool) -> Void)?

    // Kick listening
    @Published var listenOn = false
    @Published var kickTarget: KickTarget = .everyBeat
    @Published var kickSteps: Set<Int> = []           // for .pattern
    @Published var toleranceMs: Double = 25 { didSet { pushDetector() } }
    @Published var sensitivity: Float = 0.5 { didSet { pushDetector() } }
    @Published var calibrationMs: Double = 0 { didSet { pushDetector() } }
    @Published private(set) var calibrating = false
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var marks: [Int: HitMark] = [:]
    @Published private(set) var lastHit: Double?
    @Published private(set) var repResults: [RepResult] = []
    @Published var micDenied = false
    private lazy var detector = KickDetector(queue: queue)
    private var hostStart: Double = 0
    private var outLatency: Double = 0

    var cleanReps: Int { repResults.filter(\.clean).count }
    private var allErrors: [Double] { repResults.flatMap(\.errors) }
    var sessionMeanAbs: Double? { allErrors.isEmpty ? nil : allErrors.map(abs).reduce(0, +) / Double(allErrors.count) }
    var sessionSpread: Double? {
        let e = allErrors; guard e.count > 1 else { return nil }
        let mean = e.reduce(0, +) / Double(e.count)
        return (e.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(e.count - 1)).squareRoot()
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var currentStep = -1
    @Published private(set) var pattern = Counting.pattern(TimeSignature.all[0], .quarter)

    private let engine = AVAudioEngine()
    private let clickNode = AVAudioPlayerNode()
    private let voiceNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var sr: Double { format.sampleRate }
    private lazy var voices = VoiceBank(format: format)
    private var clicks: [AVAudioPCMBuffer] = []

    private let queue = DispatchQueue(label: "metronome.scheduler", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // Scheduler state (touched only on `queue`)
    private var nextSample: Double = 0
    private var stepIndex = 0
    private var snap = Snapshot()

    private var qBars = 0
    private var startedBar = false
    private var finishing = false
    private var wordBuffers: [String: AVAudioPCMBuffer] = [:]

    private struct Snapshot {
        var pattern = Counting.pattern(TimeSignature.all[0], .quarter)
        var bpm: Double = 100
        var voiceOn = true, clickOn = true
        var resetBar = false
        var totalBars: Int? = nil
        var listen = false
        var kickTarget: KickTarget = .everyBeat
        var kickSteps: Set<Int> = []
        var barsPerRep = 1
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.attach(clickNode)
        engine.attach(voiceNode)
        engine.connect(clickNode, to: engine.mainMixerNode, format: format)
        engine.connect(voiceNode, to: engine.mainMixerNode, format: format)
        clicks = [makeClick(freq: 900, gain: 0.35), makeClick(freq: 1300, gain: 0.55), makeClick(freq: 1800, gain: 0.8)]
        if let saved = UserDefaults.standard.object(forKey: "kickCalibrationMs") as? Double { calibrationMs = saved }
        detector.onMark = { [weak self] step, mark in
            guard let self, self.isPlaying else { return }
            self.marks[step] = mark
            if case .hit(let ms) = mark { self.lastHit = ms }
        }
        detector.onRep = { [weak self] r in self?.repResults.append(r) }
        detector.onLevel = { [weak self] lv in self?.micLevel = lv }
        detector.onCalibrated = { [weak self] ms in
            self?.calibrating = false
            self?.calibrationMs = ms
            UserDefaults.standard.set(ms, forKey: "kickCalibrationMs")
        }
        pushDetector()
        let bank = voices
        Task { [weak self] in
            await bank.load(Counting.allWords)
            let loaded = bank.buffers
            self?.queue.async { self?.wordBuffers = loaded }
            await MainActor.run { self?.isReady = true }
        }
    }

    func toggle() { isPlaying ? stop() : start() }

    func start() {
        guard !isPlaying else { return }
        let session = AVAudioSession.sharedInstance()
        if listenOn {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try? session.setPreferredIOBufferDuration(0.005)
            try? session.setActive(true)
            detector.install(on: engine)
        } else {
            detector.remove(from: engine)
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
        outLatency = session.outputLatency + session.ioBufferDuration
        marks = [:]; lastHit = nil; repResults = []
        queue.sync { detector.reset() }
        do { try engine.start() } catch { return }
        syncSnapshot()
        queue.sync { nextSample = sr * 0.05; stepIndex = 0; qBars = 0; startedBar = false; finishing = false }
        barsDone = 0
        let startAt = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        hostStart = AVAudioTime.seconds(forHostTime: startAt.hostTime)
        let hs = hostStart, ol = outLatency
        queue.sync { self.qHostStart = hs; self.qOutLatency = ol }
        clickNode.play(at: startAt)
        voiceNode.play(at: startAt)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        isPlaying = true
    }

    func stop() { end(finished: false) }

    private func end(finished: Bool) {
        guard isPlaying else { return }
        timer?.cancel(); timer = nil
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        queue.sync { if snap.listen { detector.finish(now: now) } }
        let bars = barsDone
        DispatchQueue.main.async { [weak self] in self?.onSessionEnd?(bars, finished) }
        calibrating = false
        if listenOn { detector.remove(from: engine) }
        clickNode.stop(); voiceNode.stop()
        engine.pause()
        isPlaying = false
        currentStep = -1
    }

    /// Push UI settings to the scheduler thread.
    func syncSnapshot() {
        let p = pattern, b = bpm, v = voiceOn, c = clickOn
        let total: Int? = loopOn ? max(reps, 1) * max(barsPerRep, 1) : nil
        let li = listenOn, kt = kickTarget, ks = kickSteps, bpr = loopOn ? max(barsPerRep, 1) : 1
        voiceNode.volume = voiceVolume
        queue.async { [weak self] in
            guard let self else { return }
            self.snap.pattern = p; self.snap.bpm = b
            self.snap.voiceOn = v; self.snap.clickOn = c
            self.snap.totalBars = total
            self.snap.listen = li; self.snap.kickTarget = kt
            self.snap.kickSteps = ks; self.snap.barsPerRep = bpr
        }
    }

    private func patternChanged() {
        pattern = useCustom ? Counting.custom(customBeats) : Counting.pattern(signature, subdivision)
        kickSteps = []
        syncSnapshot()
        queue.async { [weak self] in self?.snap.resetBar = true }
    }

    func toggleKickStep(_ i: Int) {
        if kickSteps.contains(i) { kickSteps.remove(i) } else { kickSteps.insert(i) }
        syncSnapshot()
    }

    func calibrate() {
        calibrating = true
        queue.async { [weak self] in self?.detector.startCalibration() }
    }

    func requestMic(_ done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async { self.micDenied = !ok; done(ok) }
        }
    }

    private func pushDetector() {
        let t = toleranceMs, s = sensitivity, c = calibrationMs
        queue.async { [weak self] in
            self?.detector.toleranceMs = t; self?.detector.sensitivity = s; self?.detector.calibrationMs = c
        }
    }

    private var qHostStart: Double = 0
    private var qOutLatency: Double = 0

    private func isKickTarget(_ i: Int, _ step: Step) -> Bool {
        switch snap.kickTarget {
        case .everyBeat: return step.word.map { Counting.numbers.contains($0) } ?? false
        case .everyCount: return step.word != nil
        case .pattern: return snap.kickSteps.contains(i)
        }
    }

    // MARK: - Scheduling (runs on `queue`)

    private func tick() {
        if finishing { return }
        if snap.listen {
            detector.sweep(now: AVAudioTime.seconds(forHostTime: mach_absolute_time()),
                           currentRep: qBars / max(snap.barsPerRep, 1))
        }
        let now = currentSample()
        let horizon = now + sr * 0.15
        while nextSample < horizon {
            if snap.resetBar { stepIndex = 0; snap.resetBar = false }
            let steps = snap.pattern.steps
            if stepIndex >= steps.count { stepIndex = 0 }
            if stepIndex == 0 {
                if startedBar {
                    qBars += 1
                    let bars = qBars
                    let d = max(0, (nextSample - now) / sr)
                    let done = snap.totalBars.map { bars >= $0 } ?? false
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                        guard let self, self.isPlaying else { return }
                        self.barsDone = bars
                        if done { self.end(finished: true) }
                    }
                    if done { finishing = true; return }
                }
                startedBar = true
            }
            let step = steps[stepIndex]
            let stepSamples = sr * 60.0 / min(max(snap.bpm, 30), 280) * step.length
            let when = AVAudioTime(sampleTime: AVAudioFramePosition(nextSample), atRate: sr)

            if snap.clickOn {
                clickNode.scheduleBuffer(clicks[step.accent], at: when, options: [], completionHandler: nil)
            }
            if snap.voiceOn, let w = step.word, let buf = trimmed(w, maxFrames: Int(stepSamples * 0.92)) {
                voiceNode.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
            }

            if snap.listen && isKickTarget(stepIndex, step) {
                detector.expect(time: qHostStart + nextSample / sr + qOutLatency,
                                step: stepIndex, rep: qBars / max(snap.barsPerRep, 1),
                                stepSeconds: stepSamples / sr)
            }

            let idx = stepIndex
            let delay = max(0, (nextSample - now) / sr)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentStep = idx
            }

            nextSample += stepSamples
            stepIndex += 1
        }
    }

    private func currentSample() -> Double {
        guard let nt = clickNode.lastRenderTime,
              let pt = clickNode.playerTime(forNodeTime: nt) else { return 0 }
        return max(0, Double(pt.sampleTime))
    }

    /// Cut a word short if it would run into the next count (fast 16ths).
    private func trimmed(_ word: String, maxFrames: Int) -> AVAudioPCMBuffer? {
        guard let src = wordBuffers[word] else { return nil }
        let len = min(Int(src.frameLength), max(maxFrames, 1))
        if len == Int(src.frameLength) { return src }
        guard let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(len)) else { return nil }
        let s = src.floatChannelData![0], o = out.floatChannelData![0]
        let fade = min(256, len)
        for i in 0..<len {
            let g: Float = i >= len - fade ? Float(len - i) / Float(fade) : 1
            o[i] = s[i] * g
        }
        out.frameLength = AVAudioFrameCount(len)
        return out
    }

    private func makeClick(freq: Double, gain: Float) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.03)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        let d = b.floatChannelData![0]
        for i in 0..<n {
            let t = Double(i) / sr
            d[i] = Float(sin(2 * .pi * freq * t) * exp(-t * 160)) * gain
        }
        b.frameLength = AVAudioFrameCount(n)
        return b
    }
}
