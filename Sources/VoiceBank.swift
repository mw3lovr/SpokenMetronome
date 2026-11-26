import AVFoundation

/// Pre-renders each counting word ("one"…"twelve", "e", "and", "a") into an audio
/// buffer once at launch, so the words can be scheduled sample-accurately
/// instead of relying on live speech (which lags and drifts).
final class VoiceBank {
    let format: AVAudioFormat
    private(set) var buffers: [String: AVAudioPCMBuffer] = [:]
    private let synth = AVSpeechSynthesizer()

    /// Text actually given to the voice, so syllables sound like a musician counting.
    private let spoken: [String: String] = ["e": "ee", "a": "uh", "and": "and"]

    init(format: AVAudioFormat) { self.format = format }

    func load(_ words: [String]) async {
        for w in words {
            if let b = await render(spoken[w] ?? w) { buffers[w] = b }
        }
    }

    private func render(_ text: String) async -> AVAudioPCMBuffer? {
        let utt = AVSpeechUtterance(string: text)
        utt.rate = AVSpeechUtteranceMaximumSpeechRate * 0.62
        utt.pitchMultiplier = 1.05
        utt.voice = AppVoice.current

        let chunks: [AVAudioPCMBuffer] = await withCheckedContinuation { cont in
            var collected: [AVAudioPCMBuffer] = []
            var finished = false
            synth.write(utt) { buffer in
                guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 || pcm.audioBufferList.pointee.mBuffers.mDataByteSize == 0 {
                    finished = true
                    cont.resume(returning: collected)
                } else {
                    collected.append(pcm)
                }
            }
        }
        guard let merged = merge(chunks), let converted = convert(merged) else { return nil }
        return trimSilence(converted)
    }

    private func merge(_ chunks: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = chunks.first else { return nil }
        let total = chunks.reduce(0) { $0 + Int($1.frameLength) }
        guard let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)) else { return nil }
        let bpf = Int(first.format.streamDescription.pointee.mBytesPerFrame)
        let dst = out.mutableAudioBufferList.pointee.mBuffers.mData!
        var offset = 0
        for c in chunks {
            let bytes = Int(c.frameLength) * bpf
            memcpy(dst + offset, c.audioBufferList.pointee.mBuffers.mData!, bytes)
            offset += bytes
        }
        out.frameLength = AVAudioFrameCount(total)
        return out
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let conv = AVAudioConverter(from: input.format, to: format) else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 2048
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return err == nil ? out : nil
    }

    /// Strip leading/trailing silence so the word starts exactly on the beat.
    private func trimSilence(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let d = b.floatChannelData?[0] else { return b }
        let n = Int(b.frameLength)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(d[i])) }
        guard peak > 0 else { return b }
        let thresh = peak * 0.04
        var start = 0, end = n - 1
        while start < n && abs(d[start]) < thresh { start += 1 }
        while end > start && abs(d[end]) < thresh { end -= 1 }
        let len = end - start + 1
        guard len > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(len)) else { return b }
        let gain = 0.9 / peak
        let o = out.floatChannelData![0]
        for i in 0..<len { o[i] = d[start + i] * gain }
        out.frameLength = AVAudioFrameCount(len)
        return out
    }
}
