import AVFoundation

/// What the kick is supposed to hit.
enum KickTarget: String, CaseIterable, Identifiable {
    case everyBeat = "Every beat"
    case everyCount = "Every count"
    case pattern = "My pattern"
    var id: String { rawValue }
}

/// Result for one expected kick.
enum HitMark: Equatable {
    case hit(Double)   // signed error in ms (+ = late, − = early)
    case miss
}

struct RepResult: Identifiable, Equatable {
    let id = UUID()
    let rep: Int
    let errors: [Double]   // signed ms of each matched kick
    let misses: Int
    let clean: Bool
    var hits: Int { errors.count }
    var mean: Double { errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count) }
    var meanAbs: Double { errors.isEmpty ? 0 : errors.map(abs).reduce(0, +) / Double(errors.count) }
    var spread: Double {
        guard errors.count > 1 else { return 0 }
        let m = mean
        return (errors.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(errors.count - 1)).squareRoot()
    }
}

/// Listens to the mic, finds low-frequency onsets (kick drum), and matches them
/// to the kicks the metronome expects. All matching runs on the scheduler queue.
final class KickDetector {
    struct Target { let time: Double; let step: Int; let rep: Int; let window: Double; var result: HitMark? }

    // Settings (set on queue)
    var toleranceMs: Double = 25
    var calibrationMs: Double = 0
    var sensitivity: Float = 0.5   // 0…1, higher = more sensitive

    // Callbacks (delivered on main)
    var onMark: ((Int, HitMark) -> Void)?
    var onRep: ((RepResult) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onCalibrated: ((Double) -> Void)?

    private let queue: DispatchQueue
    private var targets: [Target] = []
    private var repBuckets: [Int: (errors: [Double], misses: Int)] = [:]
    private var openReps = Set<Int>()
    private var calibrating = false
    private var calErrors: [Double] = []

    // DSP state (audio thread)
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    private var env: Float = 0, floorLevel: Float = 0.001
    private var lastOnset: Double = 0
    private var levelAcc: Float = 0, levelCount = 0
    private var inputLatency: Double = 0

    init(queue: DispatchQueue) { self.queue = queue }

    // MARK: Mic

    func install(on engine: AVAudioEngine) {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        setupLowPass(sr: Float(fmt.sampleRate), freq: 140)
        inputLatency = AVAudioSession.sharedInstance().inputLatency
        input.removeTap(onBus: 0)
        installed = true
        input.installTap(onBus: 0, bufferSize: 256, format: fmt) { [weak self] buf, when in
            self?.process(buf, when, sr: fmt.sampleRate)
        }
    }

    private var installed = false
    func remove(from engine: AVAudioEngine) {
        guard installed else { return }
        engine.inputNode.removeTap(onBus: 0); installed = false
    }

    private func setupLowPass(sr: Float, freq: Float) {
        let w = 2 * Float.pi * freq / sr, q: Float = 0.707
        let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }

    private func process(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime, sr: Double) {
        guard let d = buf.floatChannelData?[0], when.isHostTimeValid else { return }
        let base = AVAudioTime.seconds(forHostTime: when.hostTime)
        let n = Int(buf.frameLength)
        let attack: Float = 0.5, release: Float = 0.9995, floorRate: Float = 0.9998
        let ratio = 6 - 4.5 * sensitivity          // 6x floor (low sens) … 1.5x (high)
        let absMin = 0.02 - 0.018 * sensitivity
        var onsets: [Double] = []
        for i in 0..<n {
            let x = d[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            let r = abs(y)
            env = r > env ? env + (r - env) * attack : env * release
            floorLevel = floorLevel * floorRate + env * (1 - floorRate)
            levelAcc = max(levelAcc, env)
            let t = base + Double(i) / sr
            if env > absMin && env > floorLevel * ratio && t - lastOnset > 0.09 {
                lastOnset = t
                onsets.append(t - inputLatency)
            }
        }
        levelCount += n
        if levelCount > Int(sr / 20) {
            let lv = min(levelAcc * 4, 1); levelAcc = 0; levelCount = 0
            DispatchQueue.main.async { [weak self] in self?.onLevel?(lv) }
        }
        guard !onsets.isEmpty else { return }
        queue.async { [weak self] in onsets.forEach { self?.hit(at: $0) } }
    }

    // MARK: Matching (queue)

    func reset() {
        targets.removeAll(); repBuckets.removeAll(); openReps.removeAll()
        env = 0; floorLevel = 0.001
    }

    func startCalibration() { calibrating = true; calErrors.removeAll() }

    func expect(time: Double, step: Int, rep: Int, stepSeconds: Double) {
        let window = min(0.15, max(0.03, stepSeconds * 0.45))
        targets.append(Target(time: time, step: step, rep: rep, window: window, result: nil))
        openReps.insert(rep)
        if repBuckets[rep] == nil { repBuckets[rep] = ([], 0) }
    }

    private func hit(at raw: Double) {
        let t = raw - calibrationMs / 1000
        var best: Int?, bestErr = Double.infinity
        for (i, tg) in targets.enumerated() where tg.result == nil {
            let e = t - tg.time
            if abs(e) <= (calibrating ? max(tg.window, 0.3) : tg.window) && abs(e) < abs(bestErr) { best = i; bestErr = e }
        }
        guard let i = best else { return }   // stray hit, ignore
        let ms = bestErr * 1000
        if calibrating {
            calErrors.append(ms + calibrationMs)
            if calErrors.count >= 12 {
                let s = calErrors.sorted(); let med = s[s.count / 2]
                calibrating = false
                calibrationMs = med
                DispatchQueue.main.async { [weak self] in self?.onCalibrated?(med) }
            }
        }
        targets[i].result = .hit(ms)
        repBuckets[targets[i].rep]?.errors.append(ms)
        let step = targets[i].step
        DispatchQueue.main.async { [weak self] in self?.onMark?(step, .hit(ms)) }
    }

    /// Mark overdue targets as misses and close finished reps. `currentRep` = rep being scheduled.
    func sweep(now: Double, currentRep: Int) {
        for i in targets.indices where targets[i].result == nil && now > targets[i].time + targets[i].window {
            targets[i].result = .miss
            repBuckets[targets[i].rep]?.misses += 1
            let step = targets[i].step
            DispatchQueue.main.async { [weak self] in self?.onMark?(step, .miss) }
        }
        for rep in openReps.sorted() where rep < currentRep {
            if targets.contains(where: { $0.rep == rep && $0.result == nil }) { continue }
            close(rep)
        }
        targets.removeAll { $0.result != nil && now - $0.time > 2 }
    }

    /// Session ended: resolve what has already happened, close everything.
    func finish(now: Double) {
        sweep(now: now, currentRep: Int.max)
        for rep in openReps.sorted() {
            let pendingPast = targets.filter { $0.rep == rep && $0.result == nil && $0.time < now }.count
            repBuckets[rep]?.misses += pendingPast
            // Only report reps that were fully played.
            if !targets.contains(where: { $0.rep == rep && $0.result == nil && $0.time >= now }) { close(rep) }
        }
        targets.removeAll(); openReps.removeAll()
    }

    private func close(_ rep: Int) {
        openReps.remove(rep)
        guard let b = repBuckets.removeValue(forKey: rep), b.errors.count + b.misses > 0 else { return }
        let tol = toleranceMs
        let clean = b.misses == 0 && b.errors.allSatisfy { abs($0) <= tol }
        let r = RepResult(rep: rep, errors: b.errors, misses: b.misses, clean: clean)
        DispatchQueue.main.async { [weak self] in self?.onRep?(r) }
    }
}
