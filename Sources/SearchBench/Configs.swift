import Foundation
import MailCore

// Configs added while improving search (each measured against the frozen baseline rows in main.swift).
func natural(_ s: MailStore, _ q: String, semantic: Bool = true, expand: Bool = true, typed: Bool = false,
             tweak: (inout SearchEngine.NaturalWeights) -> Void = { _ in }) -> [String] {
    var o = SearchEngine.Options(mailbox: "me", limit: 50); o.now = now; o.match = .natural; o.semantic = semantic; o.expand = expand
    tweak(&o.weights)
    // Ask / Enter submits the whole query (no prefix on the last word); type-ahead keeps it.
    return SearchEngine(store: s).search(typed ? q : q + " ", o).hits.map(\.id)
}

func extraConfigs() -> [Config] {
    [
        Config(name: "nat-noexp-nosem", emb: .none) { s, q in natural(s, q, semantic: false, expand: false) },
        Config(name: "nat-nosem", emb: .none) { s, q in natural(s, q, semantic: false) },
        Config(name: "ask", emb: .apple) { s, q in natural(s, q) },
        Config(name: "ask-typed", emb: .apple) { s, q in natural(s, q, typed: true) },
        // Stubbed AI parse: the merge path the app uses (SearchQuery.natural), with off-target keywords a model might add.
        Config(name: "ask+ai-noise", emb: .apple) { s, q in
            let ai = AISearchQuery(terms: ["update", "status", "information"], fromAI: true)
            var o = SearchEngine.Options(mailbox: "me", limit: 50); o.now = now; o.match = .natural
            return SearchEngine(store: s).search(SearchQuery.natural(raw: q, ai: ai, now: now), o).hits.map(\.id)
        },
        Config(name: "ask-sem0.15", emb: .apple) { s, q in natural(s, q) { $0.semantic = 0.15 } },
        Config(name: "ask-nosemonly", emb: .apple) { s, q in natural(s, q) { $0.semanticOnlyMaxRank = 0 } },
        Config(name: "ask-sem0.1-f0.5", emb: .apple) { s, q in natural(s, q) { $0.semantic = 0.1; $0.semanticFloor = 0.5; $0.semanticOnlyMaxRank = 0 } },
        Config(name: "ask-typed-sem0.1-f0.5", emb: .apple) { s, q in natural(s, q, typed: true) { $0.semantic = 0.1; $0.semanticFloor = 0.5; $0.semanticOnlyMaxRank = 0 } },
        Config(name: "ask-ctx", emb: .contextual) { s, q in natural(s, q) },
        Config(name: "ask-ctx-sem0.6", emb: .contextual) { s, q in natural(s, q) { $0.semantic = 0.6; $0.semanticFloor = 0.2 } },
        Config(name: "hub-ctx", emb: .contextual) { s, q in
            var o = SearchEngine.Options(mailbox: "me", limit: 50); o.now = now
            return SearchEngine(store: s).search(q, o).hits.map(\.id)
        },
    ]
}

func makeContextualEmbedder() -> TextEmbedder? { ContextualSentenceEmbedder() }
