import Foundation

struct TrackInfo: Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let persistentID: String
    let isFavorited: Bool
    let isDisliked: Bool

    static let empty = TrackInfo(
        title: "", artist: "", album: "",
        duration: 0, persistentID: "",
        isFavorited: false, isDisliked: false
    )

    var identity: String {
        "\(title)-\(artist)-\(album)"
    }
}
