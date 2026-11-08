import Foundation

/// Listens on a Unix domain socket; each connection delivers one JSON hook event.
final class EventServer: @unchecked Sendable {
    static let dir = NSString(string: "~/.notch-agents").expandingTildeInPath
    static let path = dir + "/sock"

    private var fd: Int32 = -1
    private let onEvent: @Sendable (HookEvent) -> Void

    init(onEvent: @escaping @Sendable (HookEvent) -> Void) { self.onEvent = onEvent }

    /// True if a live process already accepts connections on the socket.
    static func isAnotherInstanceListening() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        } == 0
    }

    func start() throws {
        try FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if Self.isAnotherInstanceListening() { throw NSError(domain: "sock", code: 99) }
        unlink(Self.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "sock", code: 1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw NSError(domain: "sock", code: 2) }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { throw NSError(domain: "sock", code: 3) }
        chmod(Self.path, 0o600)
        guard listen(fd, 16) == 0 else { throw NSError(domain: "sock", code: 4) }

        let listenFd = fd
        Thread.detachNewThread { [onEvent] in
            while true {
                let client = accept(listenFd, nil, nil)
                if client < 0 { return }
                DispatchQueue.global().async {
                    var data = Data()
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = read(client, &buf, buf.count)
                        if n <= 0 { break }
                        data.append(buf, count: n)
                        if data.count > 1_000_000 { break }
                    }
                    close(client)
                    if let ev = try? JSONDecoder().decode(HookEvent.self, from: data) { onEvent(ev) }
                }
            }
        }
    }
}
