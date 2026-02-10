import Foundation

struct LyricWord: Equatable {
    let text: String
    let begin: TimeInterval
    let end: TimeInterval
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let endTime: TimeInterval
    let text: String
    let words: [LyricWord]
}
