import Foundation
import CalendarCore
import ProtectedContent

// MIP decrypt probe. Prints ONLY: bridge/SDK status, which fetch path worked, body length, rights, rights source,
// token-call count and a result code. Never content, subjects, addresses, owners or tokens.
//
//   swift run MIPProbe --self-check                       (offline: loads the bridge, no network)
//   swift run MIPProbe --tokens /path/tokens.json --message <id> --client-id <app-id> [--mailbox me|upn] [--event] [--policy-engine]
//
// tokens.json comes from `scripts/devtoken.py --mip …` (mode 0600): {"upn","graph","rms","sync"}.

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func out(_ s: String) { print(s); fflush(stdout) }

switch ProtectedContentService.bridgeStatus() {
case .success(let s): out("bridge: loaded, MIP SDK \(s.sdkVersion)")
case .failure(let e): out("bridge: \(e) — run scripts/build-mipbridge.sh (docs/MIP.md)"); exit(2)
}
if args.contains("--self-check") { out("self-check: ok (no network used)"); exit(0) }

guard let tokenPath = arg("--tokens"), let messageId = arg("--message") else {
    out("usage: MIPProbe --self-check | --tokens FILE --message ID --client-id ID [--mailbox me] [--event] [--policy-engine]")
    exit(64)
}
struct Tokens: Decodable { var upn: String; var graph: String; var rms: String?; var sync: String? }
guard let tdata = FileManager.default.contents(atPath: tokenPath),
      let tokens = try? JSONDecoder().decode(Tokens.self, from: tdata) else { out("tokens: unreadable"); exit(65) }
out("tokens: graph=\(true) rms=\(tokens.rms?.isEmpty == false) sync=\(tokens.sync?.isEmpty == false)")

guard let clientId = arg("--client-id") else {
    out("--client-id <app (client) ID of your Entra app registration> is required")
    exit(64)
}
let mailbox = arg("--mailbox") ?? "me"
let kind: RPMSGFetcher.Kind = args.contains("--event") ? .event : .message
let graph = tokens.graph
let fetcher = RPMSGFetcher(graphToken: { graph })

let requested = RequestLog()
let rms = tokens.rms, sync = tokens.sync
let provider: MIPTokenProvider = { req in
    requested.add(req.service.rawValue)
    switch req.service {
    case .rms: if let rms, !rms.isEmpty { return rms }
    case .policySync: if let sync, !sync.isEmpty { return sync }
    case .other: break
    }
    throw MIPBridgeError.auth(stage: 0)
}

final class RequestLog: @unchecked Sendable {
    private let l = NSLock(); private var s: [String] = []
    func add(_ x: String) { l.lock(); s.append(x); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return s }
}

let service = ProtectedContentService(configuration: .init(clientId: clientId, appName: "niivo mail MIPProbe",
                                                          cache: .byod, protectionOnly: !args.contains("--policy-engine")))
do {
    let (rpmsg, path) = try await fetcher.fetch(id: messageId, mailbox: mailbox, kind: kind)
    out("fetch: ok via \(path.rawValue), rpmsg bytes=\(rpmsg.count)")
    let r = try await service.decrypt(rpmsg: rpmsg, userEmail: tokens.upn, tokens: provider)
    out("decrypt: OK")
    out("body: \(r.bodyByteCount) bytes (html chars \(r.html.count))")
    out("rights: \(r.rights.names.joined(separator: ",")) [source \(r.rightsSource.rawValue)]")
    out("owner: \(r.owner == nil ? "absent" : "present")")
    out("token requests: \(r.tokenCalls) (\(requested.all.joined(separator: ",")))")
    service.shutdown()
    exit(0)
} catch {
    out("result: FAILED \(error)")
    out("token requests: \(requested.all.joined(separator: ","))")
    service.shutdown()
    exit(1)
}
