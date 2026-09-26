import Darwin
import Foundation

enum TargetResolver {
    static func addresses(for host: String) -> Set<String> {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &first) == 0 else { return [] }
        defer { if let first { freeaddrinfo(first) } }
        var addresses = Set<String>()
        var current = first
        while let entry = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.insert(ScreenSharingMonitor.normalize(String(cString: buffer)))
            }
            current = entry.pointee.ai_next
        }
        return addresses
    }
}
