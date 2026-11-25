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

    private var wordBuffers: [String: AVAudioPCMBuffer] = [:]

    private struct Snapshot {
        var pattern = Counting.pattern(TimeSignature.all[0], .quarter)
        var bpm: Double = 100
        var voiceOn = true, clickOn = true
        var resetBar = false
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.attach(clickNode)
        engine.attach(voiceNode)
        engine.connect(clickNode, to: engine.mainMixerNode, format: format)
        engine.connect(voiceNode, to: engine.mainMixerNode, format: format)
        clicks = [makeClick(freq: 900, gain: 0.35), makeClick(freq: 1300, gain: 0.55), makeClick(freq: 1800, gain: 0.8)]
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
        do { try engine.start() } catch { return }
        syncSnapshot()
        queue.sync { nextSample = sr * 0.05; stepIndex = 0 }
        let startAt = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        clickNode.play(at: startAt)
        voiceNode.play(at: startAt)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        isPlaying = true
    }

    func stop() {
        timer?.cancel(); timer = nil
        clickNode.stop(); voiceNode.stop()
        engine.pause()
        isPlaying = false
        currentStep = -1
    }

    /// Push UI settings to the scheduler thread.
    func syncSnapshot() {
        let p = pattern, b = bpm, v = voiceOn, c = clickOn
        voiceNode.volume = voiceVolume
        queue.async { [weak self] in
            guard let self else { return }
            self.snap.pattern = p; self.snap.bpm = b
            self.snap.voiceOn = v; self.snap.clickOn = c
        }
    }

    private func patternChanged() {
        pattern = useCustom ? Counting.custom(customBeats) : Counting.pattern(signature, subdivision)
        syncSnapshot()
        queue.async { [weak self] in self?.snap.resetBar = true }
    }

    // MARK: - Scheduling (runs on `queue`)

    private func tick() {
        let now = currentSample()
        let horizon = now + sr * 0.15
        while nextSample < horizon {
            if snap.resetBar { stepIndex = 0; snap.resetBar = false }
            let steps = snap.pattern.steps
            if stepIndex >= steps.count { stepIndex = 0 }
            let step = steps[stepIndex]
            let stepSamples = sr * 60.0 / min(max(snap.bpm, 30), 280) * step.length
            let when = AVAudioTime(sampleTime: AVAudioFramePosition(nextSample), atRate: sr)

            if snap.clickOn {
                clickNode.scheduleBuffer(clicks[step.accent], at: when, options: [], completionHandler: nil)
            }
            if snap.voiceOn, let w = step.word, let buf = trimmed(w, maxFrames: Int(stepSamples * 0.92)) {
                voiceNode.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
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
