import Foundation
import os

private let logger = Logger(subsystem: "com.kadxy.FlowX", category: "NowPlaying")

/// Retrieves the Adam ID of the currently playing track via osascript + MRNowPlayingRequest.
///
/// On macOS 15.4+, `mediaremoted` restricts direct calls to `MRMediaRemoteGetNowPlayingInfo`.
/// However, `/usr/bin/osascript` (a system binary) can load the private framework and access
/// `MRNowPlayingRequest` without the restricted entitlement.
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

    /// Returns the Adam ID (catalog song ID) of the currently playing track.
    static func getNowPlayingAdamID() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                } catch {
                    logger.error("osascript failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                // Kill the process if it doesn't finish within 5 seconds
                let timeout = DispatchWorkItem {
                    guard process.isRunning else { return }
                    logger.warning("osascript timed out, terminating")
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)

                process.waitUntilExit()
                timeout.cancel()

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
            }
        }
    }
}
