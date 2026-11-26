import Foundation
import CryptoKit
import CalendarCore
import MailCore
import TrustCore

// The in-app side of the shared tool layer: the same MCPServer (defs, gate, untrusted wrapping, audit) driven
// in-process for OpenAI/on-device, or over a private unix socket for `claude -p` (OfficeMCP --relay).

extension Backend {
    /// A backend over the APP's live sync/store. Read-only by construction: the server is created with
    /// `--read-only` semantics and nothing here calls `syncNow()` (which flushes the outbox).
    /// `aiMaxPriority`: pass `Int.max` for the on-device tier (the priority ceiling is a cloud rule).
    public static func inProcess(sync: MailSync, store: MailStore, calendar: CalendarService, engine: CachedLabelPolicyEngine,
                                 calendars: [CalendarInfo], me: EmailAddress, trust: TrustAIAccess, aiMaxPriority: Int) -> Backend {
        Backend(sync: sync, store: store, calendar: calendar, engine: engine, calendars: calendars, me: me, identities: [],
                trust: trust, aiMaxPriority: aiMaxPriority, policySources: ["app"], fixtureMail: nil)
    }
}

extension ToolDef {
    var aiSpec: AIToolSpec {
        var schema: [String: JSON] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return AIToolSpec(name: name, description: description, parametersJSON: JSON.object(schema).encoded)
    }
}

extension MCPServer {
    /// Read-only, no drafts, no triage: the only configuration the AI agent ever gets.
    public static func agent(backend: Backend, audit: AuditSink) -> MCPServer {
        var c = ServerConfig(); c.allowTriage = false; c.allowDrafts = false
        return MCPServer(config: c, backend: backend, audit: audit)
    }

    public nonisolated var aiSpecs: [AIToolSpec] { tools.map(\.aiSpec) }

    /// Cached header by id (tests / parity checks; no gate applied — never hand this to a model).
    public func fixtureHeader(_ id: String) -> MailMessage? { try? backend.store.message(id: id, includeBody: false) }

    /// One tool call without JSON-RPC framing (same path as `tools/call`).
    public func callTool(_ name: String, argumentsJSON: String) async -> AIToolResult {
        let id = "c"
        let line = "{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"method\":\"tools/call\",\"params\":{\"name\":\(JSON.string(name).encoded),\"arguments\":\(argumentsJSON.isEmpty ? "{}" : argumentsJSON)}}"
        lastResult = nil
        guard let resp = await handle(line: line), let o = JSON.parse(resp) else {
            return AIToolResult(text: "{\"error\":\"The request failed.\"}", isError: true)
        }
        if let r = lastResult { return r }
        let msg = o["error"]?["message"]?.string ?? "The request failed."
        return AIToolResult(text: JSON.object(["error": .string(msg)]).encoded, isError: true)
    }
}

/// `AIToolExecutor` over an in-process agent server.
public struct OfficeToolExecutor: AIToolExecutor {
    public let server: MCPServer
    public let specs: [AIToolSpec]
    public init(server: MCPServer) { self.server = server; self.specs = server.aiSpecs }
    public func call(_ name: String, argumentsJSON: String) async -> AIToolResult {
        await server.callTool(name, argumentsJSON: argumentsJSON)
    }
}

// MARK: - Private socket host for `claude -p` (OfficeMCP --relay <socket> --relay-token <hex>)

/// Listens on a unix socket in a fresh 0700 directory, accepts ONE connection, requires the per-run token as the
/// first line, then serves JSON-RPC lines from the in-process server. Closed by `stop()` (or deinit).
public final class MCPSocketHost: @unchecked Sendable {
    public let socketPath: String
    public let token: String
    let dir: URL
    let server: MCPServer
    private var listenFD: Int32 = -1
    private var connFD: Int32 = -1
    private let lock = NSLock()

    public init(server: MCPServer) throws {
        self.server = server
        token = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        // /tmp keeps the path well under sun_path's 104 bytes; the directory is private to this user.
        dir = URL(fileURLWithPath: "/tmp/niivo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socketPath = dir.appending(path: "s").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = b }; p[bytes.count] = 0 }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        chmod(socketPath, 0o600)
        listenFD = fd
        Thread.detachNewThread { [self] in serve() }
    }

    deinit { stop() }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
        if connFD >= 0 { shutdown(connFD, SHUT_RDWR); close(connFD); connFD = -1 }
        try? FileManager.default.removeItem(at: dir)
    }

    private func serve() {
        lock.lock(); let lfd = listenFD; lock.unlock()
        guard lfd >= 0 else { return }
        let c = accept(lfd, nil, nil)
        lock.lock()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }   // single connection
        connFD = c
        lock.unlock()
        guard c >= 0 else { return }
        var buf = Data(), first = true
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                buf.removeSubrange(buf.startIndex...nl)
                if first {
                    first = false
                    guard line == token else { stop(); return }
                    continue
                }
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let box = ResponseBox(), sem = DispatchSemaphore(value: 0)
                let server = self.server
                Task.detached { box.value = await server.handle(line: line); sem.signal() }
                sem.wait()
                if let r = box.value { Self.writeAll(c, r + "\n") }
            }
            if buf.count > 4_000_000 { break }
        }
        stop()
    }

    static func writeAll(_ fd: Int32, _ s: String) {
        var bytes = Array(s.utf8), off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress! + off, $0.count - off) }
            if n < 0 { if errno == EINTR { continue }; return }
            off += n
        }
    }
}

private final class ResponseBox: @unchecked Sendable { var value: String? }

/// OfficeMCP relay mode: stdin → socket (after the token line), socket → stdout. No mailbox access of its own.
public enum MCPRelay {
    public static func run(socketPath: String, token: String, send: @escaping @Sendable (String) -> Void) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 1 }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return 2 }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = b }; p[bytes.count] = 0 }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { Log.err("relay: connect failed"); return 1 }
        MCPSocketHost.writeAll(fd, token + "\n")
        Thread.detachNewThread {
            var buf = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { exit(0) }
                buf.append(contentsOf: chunk[0..<n])
                while let nl = buf.firstIndex(of: 0x0A) {
                    send(String(decoding: buf[buf.startIndex..<nl], as: UTF8.self))
                    buf.removeSubrange(buf.startIndex...nl)
                }
            }
        }
        while let line = readLine(strippingNewline: true) { MCPSocketHost.writeAll(fd, line + "\n") }
        shutdown(fd, SHUT_WR)
        Thread.sleep(forTimeInterval: 0.5)
        return 0
    }
}
