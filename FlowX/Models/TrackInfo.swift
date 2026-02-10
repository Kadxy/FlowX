import Foundation

struct TrackInfo: Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let persistentID: String
    let isFavorited: Bool

    static let empty = TrackInfo(
        title: "",
        artist: "",
        album: "",
        duration: 0,
        persistentID: "",
        isFavorited: false
    )

    var identity: String {
        persistentID.isEmpty ? "\(title)-\(artist)-\(album)" : persistentID
    }
}
