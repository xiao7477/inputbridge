import Foundation

@main
struct AutomaticRouteSmoke {
    static func main() {
        let connection = ScreenSharingState.connected(["192.168.1.20"])
        precondition(AutomaticRouteDecider.decide(frontmostBundleIdentifier: "com.tencent.xinWeChat",
                                                   outgoingScreenSharing: connection) == .local)
        precondition(AutomaticRouteDecider.decide(frontmostBundleIdentifier: "com.apple.ScreenSharing",
                                                   outgoingScreenSharing: connection) == .remote("192.168.1.20"))
        precondition(AutomaticRouteDecider.decide(frontmostBundleIdentifier: "com.apple.ScreenSharing",
                                                   outgoingScreenSharing: .connected([])) ==
                     .unavailable("屏幕共享窗口在前台，但没有检测到远程连接。"))
        print("PASS: 本机与屏幕共享输入自动分流")
    }
}
