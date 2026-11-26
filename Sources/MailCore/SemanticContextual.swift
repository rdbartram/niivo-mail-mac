import Foundation
import NaturalLanguage

/// SEARCHQ candidate: Apple's multilingual contextual model (`NLContextualEmbedding`, Latin script, 512-d, one space
/// for DE/EN/FR/IT/…), mean-pooled over tokens and centred on a fixed mean of neutral business sentences (raw
/// mean-pooled vectors all sit at cosine ≈ 0.7 to each other). Measured in SearchBench: see docs/SEARCH-QUALITY.md
/// before switching the app to it. nil when the model assets aren't on this Mac (no download is triggered here).
public final class ContextualSentenceEmbedder: TextEmbedder, @unchecked Sendable {
    public static let space: UInt8 = 9
    private let model: NLContextualEmbedding
    private let lock = NSLock()
    private var mean: [Double] = []

    public init?() {
        guard let m = NLContextualEmbedding(script: .latin), m.hasAvailableAssets, (try? m.load()) != nil else { return nil }
        model = m
        let neutral = ["Guten Tag, anbei die Unterlagen.", "Hi team, quick update.", "Merci pour votre message.", "Grazie per la risposta.",
                       "Können wir morgen telefonieren?", "Please find the details below.", "Termin nächste Woche", "Notes from today",
                       "Bitte um Rückmeldung bis Freitag", "Thanks and best regards", "Freundliche Grüsse", "Cordiali saluti"]
        let vs = neutral.compactMap { pooled($0) }
        guard let d = vs.first?.count else { return nil }
        mean = (0..<d).map { i in vs.reduce(0) { $0 + $1[i] } / Double(vs.count) }
    }

    private func pooled(_ text: String) -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        let t = String(text.prefix(1_000))
        guard let r = try? model.embeddingResult(for: t, language: nil) else { return nil }
        var acc = [Double](repeating: 0, count: model.dimension), n = 0
        r.enumerateTokenVectors(in: t.startIndex..<t.endIndex) { v, _ in
            for i in 0..<min(v.count, acc.count) { acc[i] += v[i] }
            n += 1; return true
        }
        guard n > 0 else { return nil }
        return acc.map { $0 / Double(n) }
    }

    private func vector(_ text: String) -> [Float]? {
        guard let v = pooled(text) else { return nil }
        return mean.isEmpty ? v.map(Float.init) : zip(v, mean).map { Float($0 - $1) }
    }

    public func embed(_ text: String) -> EmbeddedText? { vector(text).map { EmbeddedText(space: Self.space, vector: $0) } }
    public func embedQuery(_ text: String, spaces: Set<UInt8>) -> [EmbeddedText] {
        guard spaces.contains(Self.space), let v = vector(text) else { return [] }
        return [EmbeddedText(space: Self.space, vector: v)]
    }
}
