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
}

struct Pattern {
    let steps: [Step]
    /// Length of each step, measured in beats of the BPM unit
    /// (quarter notes for x/4, eighth notes for x/8).
    let stepBeats: Double
}

enum Counting {
    static let numbers = ["one", "two", "three", "four", "five", "six",
                          "seven", "eight", "nine", "ten", "eleven", "twelve"]
    static let syllables = ["e", "and", "a"]
    static var allWords: [String] { numbers + syllables }

    static func pattern(_ sig: TimeSignature, _ sub: Subdivision) -> Pattern {
        simple(sig, sub)
    }

    /// x/4: beat = quarter note. "1 2 3 4", "1 & 2 &", "1 e & a".
    private static func simple(_ sig: TimeSignature, _ sub: Subdivision) -> Pattern {
        let per: Int = sub == .quarter ? 1 : (sub == .eighth ? 2 : 4)
        // Accent group starts in x/8 (e.g. 6/8 = 1 and 4), every beat in x/4.
        var groupStarts = Set<Int>()
        var at = 1
        for len in sig.groups { groupStarts.insert(at); at += len }
        var steps: [Step] = []
        for b in 1...sig.beats {
            for s in 0..<per {
                if s == 0 {
                    steps.append(Step(word: numbers[b - 1], accent: b == 1 ? 2 : (groupStarts.contains(b) ? 1 : 0), display: "\(b)"))
                } else {
                    let syl = per == 2 ? "and" : syllables[s - 1]
                    steps.append(Step(word: syl, accent: 0, display: syl == "and" ? "&" : syl))
                }
            }
        }
        return Pattern(steps: steps, stepBeats: 1.0 / Double(per))
    }

    /// x/8: beat = eighth note.
    /// 4th  -> clicks every eighth, speaks only the group pulses ("1 . . 2 . .")
    /// 8th  -> speaks every eighth ("1 2 3 4 5 6")
    /// 16th -> "1 & 2 & 3 & ..."
    private static func compound(_ sig: TimeSignature, _ sub: Subdivision) -> Pattern {
        var groupStarts: [Int: Int] = [:] // eighth index -> group number
        var idx = 0
        for (g, len) in sig.groups.enumerated() { groupStarts[idx] = g + 1; idx += len }

        var steps: [Step] = []
        for i in 0..<sig.beats {
            let accent = i == 0 ? 2 : (groupStarts[i] != nil ? 1 : 0)
            switch sub {
            case .quarter:
                if let g = groupStarts[i] {
                    steps.append(Step(word: numbers[g - 1], accent: accent, display: "\(g)"))
                } else {
                    steps.append(Step(word: nil, accent: 0, display: "·"))
                }
            case .eighth:
                steps.append(Step(word: numbers[i], accent: accent, display: "\(i + 1)"))
            case .sixteenth:
                steps.append(Step(word: numbers[i], accent: accent, display: "\(i + 1)"))
                steps.append(Step(word: "and", accent: 0, display: "&"))
            }
        }
        return Pattern(steps: steps, stepBeats: sub == .sixteenth ? 0.5 : 1.0)
    }
}
