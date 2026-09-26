import Foundation

@main
struct ScreenSharingProbe {
    static func main() {
        switch ScreenSharingMonitor.query(direction: .outgoing) {
        case .connected(let addresses):
            print("outgoing-screen-sharing-count=\(addresses.count)")
            for address in addresses.sorted() { print(address) }
        case .unavailable(let reason):
            fputs("\(reason)\n", stderr)
            exit(1)
        }
    }
}
