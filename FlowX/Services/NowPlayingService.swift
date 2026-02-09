import Foundation
import os

private let logger = Logger(subsystem: "com.kadxy.FlowX", category: "NowPlaying")

/// 通过 MediaRemote 私有框架获取当前播放曲目的 Adam ID (catalog song ID)
/// 需要 app 使用有效开发者证书签名（非 ad-hoc），否则 mediaremoted 会拒绝访问
enum NowPlayingService {
    private static let bundle: CFBundle? = {
        CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        )
    }()

    private typealias MRGetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping (CFDictionary) -> Void) -> Void
    private typealias MRRegister = @convention(c) (DispatchQueue) -> Void

    private static let getNowPlayingInfoFunc: MRGetNowPlayingInfo? = {
        guard let bundle,
              let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString)
        else {
            logger.error("Failed to load MRMediaRemoteGetNowPlayingInfo")
            return nil
        }
        return unsafeBitCast(ptr, to: MRGetNowPlayingInfo.self)
    }()

    /// 必须在 app 启动时调用，注册后才能访问 NowPlaying 信息
    static func register() {
        guard let bundle,
              let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString)
        else {
            logger.error("Failed to load MRMediaRemoteRegisterForNowPlayingNotifications")
            return
        }
        unsafeBitCast(ptr, to: MRRegister.self)(DispatchQueue.main)
        logger.info("Registered for NowPlaying notifications")
    }

    /// 获取当前播放曲目的 Adam ID (catalog song ID)
    static func getNowPlayingAdamID() async -> String? {
        guard let fn = getNowPlayingInfoFunc else { return nil }

        return await withCheckedContinuation { continuation in
            fn(DispatchQueue.main) { info in
                let dict = info as NSDictionary

                if let id = dict["kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier"] as? Int, id > 0 {
                    logger.info("Adam ID: \(id)")
                    continuation.resume(returning: String(id))
                } else if let id = dict["kMRMediaRemoteNowPlayingInfoiTunesStoreSubscriptionAdamIdentifier"] as? Int, id > 0 {
                    logger.info("Adam ID (subscription): \(id)")
                    continuation.resume(returning: String(id))
                } else {
                    logger.info("No Adam ID found")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
