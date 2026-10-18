import Foundation

/// The command channel: a Unix socket, one JSON request line in, one JSON reply
/// line out. Each client is read on its own thread; ops run on the main thread,
/// where WebKit lives.
final class SocketServer {
    private let path: String
    private let handle: ([String: Any], @escaping Done) -> Void

    init(path: String, handle: @escaping ([String: Any], @escaping Done) -> Void) {
        self.path = path
        self.handle = handle
    }

    /// Bind and serve. Answers false, binding nothing, when another panel already
    /// answers on this path: two panels started at once must not steal each
    /// other's socket.
    func start() -> Bool {
        if connects() { return false }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, withAddress({ bind(fd, $0, $1) }) == 0, listen(fd, 16) == 0 else {
            die("cannot listen on \(path): \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        let clients = DispatchQueue(label: "pi.socket.clients", attributes: .concurrent)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client >= 0 { clients.async { self.serve(client) } }
            }
        }
        return true
    }

    func stop() { unlink(path) }

    private func connects() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        return withAddress { connect(fd, $0, $1) } == 0
    }

    private func withAddress(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { die("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                write(client, encode(run(Data(line))))
            }
        }
    }

    /// Parse one request and wait for its reply on the main thread.
    private func run(_ line: Data) -> [String: Any] {
        guard let op = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return Reply.error(PanelError(kind: "invalid", message: "a browser op is a JSON object")).body
        }
        var reply: [String: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { self.handle(op) { reply = $0.body; sem.signal() } }
        sem.wait()
        return reply
    }

    /// A value the page returned (a Date, a DOM node) may not be JSON; encoding
    /// it would raise and kill the panel, so it becomes an error reply instead.
    private func encode(_ reply: [String: Any]) -> String {
        let safe = JSONSerialization.isValidJSONObject(reply) ? reply
            : Reply.error(PanelError(kind: "failed", message: "the reply is not JSON-serialisable")).body
        let data = (try? JSONSerialization.data(withJSONObject: safe)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ fd: Int32, _ line: String) {
        let bytes = Array((line + "\n").utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            off += n
        }
    }
}
