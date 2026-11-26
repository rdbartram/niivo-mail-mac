// OfficeMCP — stdio MCP server (newline-delimited JSON-RPC 2.0) over the Compliant Office mail + calendar core.
// See docs/MCP.md. stdout carries ONLY JSON-RPC; everything else goes to stderr.
import Foundation
import OfficeTools

/// Owns the real stdout. On start it keeps a private duplicate of fd 1 for JSON-RPC and points fd 1 at stderr, so
/// a stray `print` anywhere in linked code can't corrupt the protocol stream.
final class StdoutChannel: Sendable {
    private let fd: Int32

    init() {
        fd = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    func send(_ line: String) {
        var bytes = Array((line + "\n").utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeMutableBytes { p in write(fd, p.baseAddress! + off, p.count - off) }
            if n < 0 { if errno == EINTR { continue }; return }
            off += n
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let channel = StdoutChannel()

// Relay mode (spawned by `claude -p` for the in-app agent): no mailbox access of its own, just a pipe to the app's
// private socket, where the app serves the SAME tools in-process over its live store. See docs/MCP.md.
let argv = Array(CommandLine.arguments.dropFirst())
if let i = argv.firstIndex(of: "--relay"), i + 1 < argv.count,
   let t = argv.firstIndex(of: "--relay-token"), t + 1 < argv.count {
    exit(MCPRelay.run(socketPath: argv[i + 1], token: argv[t + 1], send: { channel.send($0) }))
}

let config: ServerConfig
do { config = try ServerConfig.parse(Array(CommandLine.arguments.dropFirst())) } catch let e as ConfigError {
    if e.message != "help" { Log.err(e.message) }
    FileHandle.standardError.write(Data((ServerConfig.usage + "\n").utf8))
    exit(e.message == "help" ? 0 : 2)
}

let backend: Backend
do { backend = try await Backend.make(config) } catch {
    Log.err("startup failed")
    exit(1)
}
let audit = AuditSink.make(fixtures: backend.isFixtures, path: config.auditLogPath)
let server = MCPServer(config: config, backend: backend, audit: audit)
Log.err("ready mode=\(backend.isFixtures ? "fixtures" : "graph") ai_access=\(backend.trust.rawValue) ai_max_priority=\(backend.aiMaxPriority) triage=\(config.allowTriage) drafts=\(config.allowDrafts) tools=\(server.tools.count) policy_sources=\(backend.policySources.joined(separator: ",")) audit=\(audit.location)")

while let line = readLine(strippingNewline: true) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    if let response = await server.handle(line: line) { channel.send(response) }
}

if let f = backend.fixtureMail {
    // Proof for tests that no tool path sends: the fixture records every send() call.
    Log.err("shutdown fixtures sent=\(f.sentLog.count)")
} else {
    Log.err("shutdown")
}
exit(0)
