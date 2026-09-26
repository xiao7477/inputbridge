import Foundation

enum AutomaticRouteDecision: Equatable {
    case local
    case remote(String)
    case unavailable(String)
}

enum AutomaticRouteDecider {
    static func decide(frontmostBundleIdentifier: String?,
                       outgoingScreenSharing: ScreenSharingState) -> AutomaticRouteDecision {
        guard frontmostBundleIdentifier == "com.apple.ScreenSharing" else { return .local }
        switch outgoingScreenSharing {
        case .unavailable(let detail):
            return .unavailable(detail)
        case .connected(let addresses) where addresses.count == 1:
            return .remote(addresses.first!)
        case .connected(let addresses) where addresses.isEmpty:
            return .unavailable("屏幕共享窗口在前台，但没有检测到远程连接。")
        case .connected:
            return .unavailable("同时检测到多个屏幕共享目标，无法确定输入位置。")
        }
    }
}
