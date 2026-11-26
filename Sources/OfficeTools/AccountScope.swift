import Foundation
import MailCore

// MARK: - Agent tools per account (docs/ACCOUNTS.md §4)
//
// One `Backend` (store, label engine, tokens) per account, so one `MCPServer` serves exactly one account. A tool call
// may name its account (`account`: id, sign-in address or "default"); without it, the default account answers.
// Every successful result is tagged with its account. No result ever combines accounts: the router sends a call to
// one server only, and an account it doesn't know is refused.

public enum AccountScope {
    public static let defaultId = "default"

    static let schemaProperty: JSON = [
        "type": "string",
        "description": "Which account to use (account id or sign-in address). Optional: the default account is used. One account per call.",
    ]

    /// nil = this backend may answer; otherwise the refusal text.
    static func refusal(requested: String?, backend: Backend) -> String? {
        guard let r = requested?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return nil }
        if r == defaultId || r == backend.accountId.lowercased() || r == backend.me.address.lowercased() { return nil }
        return "That account isn't available to this tool server. Each call works on one account."
    }

    static func strip(_ a: Args) -> Args {
        var o = a.o
        o["account"] = nil
        return Args(o)
    }
}

/// Routes in-app agent tool calls to the server of the named (or default) account. Never fans out.
public struct AccountToolRouter: AIToolExecutor {
    public let servers: [String: MCPServer]
    public let defaultAccount: String
    /// Sign-in address → account id, so the model can name an account by its address.
    public let aliases: [String: String]
    public let specs: [AIToolSpec]

    public init(servers: [String: MCPServer], defaultAccount: String, aliases: [String: String] = [:]) {
        self.servers = servers
        self.defaultAccount = defaultAccount
        self.aliases = Dictionary(aliases.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.specs = servers[defaultAccount]?.aiSpecs ?? servers.values.first?.aiSpecs ?? []
    }

    /// The account a call goes to, or nil when it names one that isn't signed in.
    public func resolve(argumentsJSON: String) -> String? {
        guard let o = JSON.parse(argumentsJSON.isEmpty ? "{}" : argumentsJSON)?.object,
              let raw = o["account"]?.string?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return defaultAccount }
        let k = raw.lowercased()
        if k == AccountScope.defaultId { return defaultAccount }
        if let id = servers.keys.first(where: { $0.lowercased() == k }) { return id }
        return aliases[k].flatMap { servers[$0] != nil ? $0 : nil }
    }

    public func call(_ name: String, argumentsJSON: String) async -> AIToolResult {
        guard let id = resolve(argumentsJSON: argumentsJSON), let server = servers[id] else {
            return AIToolResult(text: JSON.object(["error": "No such account. Name one signed-in account, or leave it out for the default."]).encoded,
                                isError: true)
        }
        // The chosen server checks the account again and tags the result: hand it its own id.
        var args = JSON.parse(argumentsJSON.isEmpty ? "{}" : argumentsJSON)?.object ?? [:]
        args["account"] = .string(server.backend.accountId)
        return await server.callTool(name, argumentsJSON: JSON.object(args).encoded)
    }
}
