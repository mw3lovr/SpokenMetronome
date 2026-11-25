import Foundation

/// A time signature. For x/8 meters, `groups` says how the eighths are grouped
/// (e.g. 6/8 = 3+3, 7/8 = 2+2+3) so accents and "quarter" counting make musical sense.
struct TimeSignature: Hashable, Identifiable {
    let beats: Int
    let unit: Int          // 4 or 8
    var id: String { "\(beats)/\(unit)" }
    var label: String { "\(beats)/\(unit)" }

    var groups: [Int] {
        guard unit == 8 else { return Array(repeating: 1, count: beats) }
        switch beats {
        case 3:  return [3]
        case 5:  return [3, 2]
        case 6:  return [3, 3]
        case 7:  return [2, 2, 3]
        case 9:  return [3, 3, 3]
        case 12: return [3, 3, 3, 3]
        default: return Array(repeating: 1, count: beats)
        }
    }

    static let all: [TimeSignature] = [
        .init(beats: 4, unit: 4), .init(beats: 2, unit: 4), .init(beats: 3, unit: 4),
        .init(beats: 5, unit: 4), .init(beats: 6, unit: 4), .init(beats: 7, unit: 4),
        .init(beats: 3, unit: 8), .init(beats: 5, unit: 8), .init(beats: 6, unit: 8),
        .init(beats: 7, unit: 8), .init(beats: 9, unit: 8), .init(beats: 12, unit: 8)
    ]
}

enum Subdivision: String, CaseIterable, Identifiable {
    case quarter = "4th", eighth = "8th", sixteenth = "16th"
    var id: String { rawValue }
}

/// One tick of the metronome.
struct Step: Equatable {
    let word: String?   // what gets spoken (nil = silent)
    let accent: Int     // 2 = downbeat, 1 = beat/group start, 0 = subdivision
    let display: String // what is shown on screen
    let length: Double  // duration in beats of the BPM unit
    var beat: Int = 0   // which beat of the bar this step belongs to
}

struct Pattern {
    let steps: [Step]
}

enum Counting {
    static let numbers = ["one", "two", "three", "four", "five", "six",
                          "seven", "eight", "nine", "ten", "eleven", "twelve"]
    static let syllables = ["e", "and", "a"]
    static var allWords: [String] { numbers + syllables }

    /// Standard bar: every beat uses the same subdivision.
    static func pattern(_ sig: TimeSignature, _ sub: Subdivision) -> Pattern {
        var groupStarts = Set<Int>()
        var at = 1
        for len in sig.groups { groupStarts.insert(at); at += len }
        let accents = (1...sig.beats).map { $0 == 1 ? 2 : (groupStarts.contains($0) ? 1 : 0) }
        return build(Array(repeating: sub, count: sig.beats), accents: accents)
    }

    /// Custom bar: each beat has its own subdivision.
    static func custom(_ beats: [Subdivision]) -> Pattern {
        build(beats, accents: beats.indices.map { $0 == 0 ? 2 : 1 })
    }

    private static func build(_ beats: [Subdivision], accents: [Int]) -> Pattern {
        var steps: [Step] = []
        for (i, sub) in beats.enumerated() {
            let b = i + 1
            let per = sub == .quarter ? 1 : (sub == .eighth ? 2 : 4)
            let len = 1.0 / Double(per)
            for s in 0..<per {
                if s == 0 {
                    steps.append(Step(word: numbers[i], accent: accents[i], display: "\(b)", length: len, beat: i))
                } else {
                    let syl = per == 2 ? "and" : syllables[s - 1]
                    steps.append(Step(word: syl, accent: 0, display: syl == "and" ? "&" : syl, length: len, beat: i))
                }
            }
        }
        return Pattern(steps: steps)
    }
}
