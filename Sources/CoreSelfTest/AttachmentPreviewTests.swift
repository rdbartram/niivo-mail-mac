import Foundation
import CalendarCore
import MailCore

// PREVIEW: inline attachment previews — type → renderer, gate (label / rights / trust / size), auto-load plan,
// scratch-file cleanup, text excerpt. No network.
@MainActor
func runAttachmentPreviewTests() {
    section("Attachment previews: type → renderer")
    typealias K = AttachmentPreviewKind
    let cases: [(String, String, K)] = [
        ("Report.PDF", "application/octet-stream", .pdf), ("scan", "application/pdf", .pdf),
        ("photo.jpg", "image/jpeg", .image), ("IMG_1.HEIC", "application/octet-stream", .image), ("x", "image/png", .image),
        ("data.csv", "text/csv", .text), ("cfg.json", "application/json", .text), ("notes.md", "", .text), ("a", "text/plain", .text),
        ("Budget.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", .quickLook),
        ("Deck.pptx", "application/octet-stream", .quickLook), ("Brief.docx", "", .quickLook),
        ("x", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", .quickLook),
        ("logo.svg", "image/svg+xml", .none), ("x", "image/svg+xml", .none), ("page.html", "text/html", .none),
        ("message.rpmsg", "application/x-microsoft-rpmsg-message", .none), ("setup.exe", "application/octet-stream", .none),
        ("archive.zip", "application/zip", .none), ("fake.pdf.exe", "application/pdf", .none), ("blob.bin", "application/octet-stream", .none),
        ("../../etc/evil.pdf", "application/pdf", .pdf),
    ]
    let wrong = cases.filter { K.kind(name: $0.0, contentType: $0.1) != $0.2 }.map { "\($0.0)→\(K.kind(name: $0.0, contentType: $0.1))" }
    check(wrong.isEmpty, "extension first, then content type; active content / archives / rpmsg / SVG never previewed \(wrong)")
    check(K.allCases.filter(\.needsFile) == [.quickLook], "only QuickLook formats need a file; image / PDF / text render from memory")

    section("Attachment previews: gate")
    let dev = AttachmentDeviceRules(allowDownload: true, allowCopyOut: true, allowPrint: true, approvedOpenIn: [])
    let on = AttachmentPreviewSettings.default
    func att(_ name: String, _ ct: String, _ size: Int) -> AttachmentInfo {
        AttachmentInfo(id: "a-\(name)", name: name, contentType: ct, size: size, isInline: false)
    }
    let pdf = att("r.pdf", "application/pdf", 400_000), docx = att("b.docx", "", 300_000)
    func mode(_ a: AttachmentInfo, _ p: ContentPolicy = .open, _ d: AttachmentDeviceRules? = nil,
              _ s: AttachmentPreviewSettings = .default) -> AttachmentPreviewMode {
        AttachmentPreviewGate.decide(a, policy: p, device: d ?? dev, settings: s).mode
    }
    check(mode(pdf) == .automatic && mode(docx) == .automatic, "unlabelled, small → loads automatically")
    var off = on; off.enabled = false
    check(mode(pdf, .open, nil, off) == .disabled, "setting off → plain chips")
    var priv = ContentPolicy.open; priv.redactDetails = true
    if case .blocked = mode(pdf, priv) { check(true, "private → blocked") } else { check(false, "private → blocked") }
    var unk = ContentPolicy.open; unk.labelState = .unknown(id: "x")
    if case .blocked = mode(pdf, unk) { check(true, "unknown label → blocked") } else { check(false, "unknown label → blocked") }
    var enc = ContentPolicy.open; enc.bodyIsProtected = true; enc.rights = [.view]
    check(mode(pdf, enc) == .protectedPath, "encrypted mail → Purview in-memory path, nothing fetched here")
    let noDl = AttachmentDeviceRules(allowDownload: false, allowCopyOut: true, allowPrint: true, approvedOpenIn: [])
    if case .blocked = mode(pdf, .open, noDl) { check(true, "trust policy without download → blocked") } else { check(false, "no download → blocked") }
    var noExtract = ContentPolicy.open; noExtract.rights.subtract([.extract])
    if case .blocked = mode(pdf, noExtract) { check(true, "label without EXTRACT → blocked") } else { check(false, "no EXTRACT → blocked") }
    var noOffline = ContentPolicy.open; noOffline.allowOfflineDetails = false
    check(mode(docx, noOffline) == .blocked(AttachmentPreviewGate.notAllowedForLabel) && mode(pdf, noOffline) == .automatic,
          "label not allowed offline: Office file (needs a file) → 'not allowed for this label'; PDF (memory only) still previews")
    let noCopyOut = AttachmentDeviceRules(allowDownload: true, allowCopyOut: false, allowPrint: false, approvedOpenIn: [])
    check(mode(docx, .open, noCopyOut) == .automatic, "in-app preview doesn't need copy-out / print (the file never leaves the app)")
    check(mode(att("x.zip", "application/zip", 10)) == .iconOnly, "no renderer → icon only")
    let big = att("big.pdf", "application/pdf", 30 * 1024 * 1024)
    check(mode(big) == .onDemand, "over the cap (20 MB) → Load preview")
    var cap50 = on; cap50.maxMB = 50
    check(mode(big, .open, nil, cap50) == .automatic, "cap raised to 50 MB → automatic")
    check(mode(att("huge.pdf", "application/pdf", 200 * 1024 * 1024), .open, nil, cap50) == .tooLarge, "over the hard cap → icon only")
    check(AttachmentPreviewGate.acceptsFetched(21 * 1024 * 1024, requested: .automatic, settings: on) == false
          && AttachmentPreviewGate.acceptsFetched(21 * 1024 * 1024, requested: .onDemand, settings: on)
          && !AttachmentPreviewGate.acceptsFetched(10, requested: .blocked("x"), settings: on),
          "real byte count re-checked after the fetch (declared size can lie)")
    let many = (0..<30).map { att("p\($0).png", "image/png", 5 * 1024 * 1024) } + [att("z.zip", "", 1), big]
    let plan = AttachmentPreviewGate.autoPlan(many, policy: .open, device: dev, settings: on)
    check(plan.count == 12 && plan.allSatisfy { $0.name.hasSuffix(".png") },
          "auto-load plan: automatic ones only, within the 60 MB budget (\(plan.count))")
    check(AttachmentPreviewGate.autoPlan(many, policy: enc, device: dev, settings: on).isEmpty
          && AttachmentPreviewGate.autoPlan(many, policy: .open, device: dev, settings: off).isEmpty,
          "auto-load plan empty for encrypted mail and when the setting is off")

    section("Attachment previews: setting")
    check(AttachmentPreviewSettings.clamp(0) == 1024 * 1024 && AttachmentPreviewSettings.clamp(.max) == AttachmentPreviewSettings.hardCapBytes,
          "cap clamped to 1 MB … hard cap")
    if let d = UserDefaults(suiteName: "cc-selftest-preview-\(UUID().uuidString)") {
        check(AttachmentPreviewSettings.load(d) == .default && AttachmentPreviewSettings.default.enabled
              && AttachmentPreviewSettings.default.maxMB == 20, "defaults: on, 20 MB")
        var s = AttachmentPreviewSettings(enabled: false); s.maxMB = 10; s.save(d)
        check(AttachmentPreviewSettings.load(d) == s, "round-trips through UserDefaults")
    }

    section("Attachment previews: text excerpt")
    let txt = Data(("\u{FEFF}" + (1...20).map { "line \($0)" }.joined(separator: "\n")).utf8)
    check(AttachmentPreviewText.firstLines(txt, lines: 3) == "line 1\nline 2\nline 3", "first lines, BOM dropped")
    check(AttachmentPreviewText.firstLines(Data(String(repeating: "x", count: 200).utf8), lines: 1, width: 10) == "xxxxxxxxxx…", "long lines cut")
    check(AttachmentPreviewText.firstLines(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01])) == nil, "binary (NUL) → no excerpt")

    section("Attachment previews: scratch files (QuickLook)")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "cc-selftest-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? fm.createDirectory(at: root.appending(path: "stale-session"), withIntermediateDirectories: true)
    let sc = PreviewScratch(root: root)
    check(!fm.fileExists(atPath: root.appending(path: "stale-session").path), "stale sessions swept at start")
    do {
        let k1 = PreviewScratch.key(messageId: "m1", attachmentId: "a1"), k2 = PreviewScratch.key(messageId: "m1", attachmentId: "a2")
        let k3 = PreviewScratch.key(messageId: "m2", attachmentId: "a1")
        let u1 = try sc.write(Data("one".utf8), name: "../../evil.docx", key: k1)
        let u2 = try sc.write(Data("two".utf8), name: "b.xlsx", key: k2)
        let u3 = try sc.write(Data("three".utf8), name: "c.pptx", key: k3)
        check(u1.path.hasPrefix(sc.session.path + "/") && u1.lastPathComponent == "evil.docx", "sender name can't escape the session dir")
        let perm = (try? fm.attributesOfItem(atPath: u1.path)[.posixPermissions] as? Int) ?? -1
        let dperm = (try? fm.attributesOfItem(atPath: sc.session.path)[.posixPermissions] as? Int) ?? -1
        check(perm == 0o600 && dperm == 0o700, "file 0600, session dir 0700")
        let again = try sc.write(Data("1b".utf8), name: "evil.docx", key: k1)
        check(!fm.fileExists(atPath: u1.path) || again == u1, "rewrite for the same key replaces the old file")
        sc.remove(key: k1)
        check(!fm.fileExists(atPath: again.path) && sc.url(for: k1) == nil && fm.fileExists(atPath: u2.path), "collapse removes that file only")
        sc.remove(messageId: "m1")
        check(!fm.fileExists(atPath: u2.path) && fm.fileExists(atPath: u3.path), "reader change removes that message's files only")
        sc.removeAll()
        check(!fm.fileExists(atPath: u3.path) && !fm.fileExists(atPath: sc.session.path) && sc.files.isEmpty, "lock / quit removes the session")
    } catch { check(false, "scratch threw \(error)") }
    try? fm.removeItem(at: root)
}
