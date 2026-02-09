import Foundation
import os

private let logger = Logger(subsystem: "com.kadxy.FlowX", category: "NowPlaying")

/// 通过 osascript + MRNowPlayingRequest 获取当前播放曲目的 Adam ID
/// macOS 15.4+ mediaremoted 限制了直接调用 MRMediaRemoteGetNowPlayingInfo，
/// 但 /usr/bin/osascript 作为系统二进制可以加载私有框架并访问 MRNowPlayingRequest
enum NowPlayingService {

    private static let script = """
        use scripting additions
        use framework "/System/Library/PrivateFrameworks/MediaRemote.framework"

        set MRNowPlayingRequest to current application's NSClassFromString("MRNowPlayingRequest")

        if MRNowPlayingRequest's localNowPlayingItem() is missing value then
            return ""
        end if

        set infoDict to MRNowPlayingRequest's localNowPlayingItem()'s nowPlayingInfo()

        set storeId to infoDict's valueForKey:"kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier"
        if storeId is missing value then
            set storeId to infoDict's valueForKey:"kMRMediaRemoteNowPlayingInfoiTunesStoreSubscriptionAdamIdentifier"
        end if

        if storeId is missing value then
            return ""
        end if

        return (storeId as real) as text
        """

    /// 获取当前播放曲目的 Adam ID (catalog song ID)
    static func getNowPlayingAdamID() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe() // suppress stderr

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if output.isEmpty {
                        logger.debug("No Adam ID from osascript")
                        continuation.resume(returning: nil)
                    } else if let num = Double(output) {
                        let id = String(Int64(num))
                        logger.info("Adam ID: \(id)")
                        continuation.resume(returning: id)
                    } else {
                        logger.warning("Unexpected osascript output: \(output)")
                        continuation.resume(returning: nil)
                    }
                } catch {
                    logger.error("osascript failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
