import Foundation

enum PlayerState: Equatable {
    case stopped
    case playing
    case paused
    case fastForwarding
    case rewinding
    case unknown

    var isPlaying: Bool {
        self == .playing
    }
}
