import AppKit

/// Opens online-meeting links in the native client when it's installed, instead of bouncing through a browser.
enum MeetingLauncher {
    /// Teams → msteams:, Zoom → zoommtg:, others stay https (their desktop apps catch the web link).
    static func nativeURL(for url: URL) -> URL? { MeetingLink.nativeURL(for: url) }

    static func handlerName(for url: URL) -> String {
        let target = nativeURL(for: url).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil ? $0 : nil } ?? url
        return NSWorkspace.shared.urlForApplication(toOpen: target)?.deletingPathExtension().lastPathComponent ?? "the browser"
    }

    static func hasNativeClient(for url: URL) -> Bool {
        nativeURL(for: url).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }

    @MainActor static func join(_ url: URL) {
        let native = nativeURL(for: url).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil ? $0 : nil }
        let target = native ?? url
        log("join → \(target.scheme ?? "?") via \(NSWorkspace.shared.urlForApplication(toOpen: target)?.lastPathComponent ?? "no handler")")
        NSWorkspace.shared.open(target, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            if let error {
                log("join failed: \(error.localizedDescription) — falling back to browser")
                if native != nil { Task { @MainActor in NSWorkspace.shared.open(url) } }
            } else {
                log("join opened \(app?.bundleIdentifier ?? "?")")
            }
        }
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("[MeetingLauncher] \(s)\n".utf8)) }
}

import SwiftUI
import CalendarCore

extension View {
    /// Double-click joins the online meeting; right-click offers Join / Open in Outlook. Nothing is offered
    /// when the policy redacts the item (private on someone else's calendar, unknown label).
    func meetingActions(_ e: CalendarEvent, _ policy: ContentPolicy) -> some View {
        let join = policy.redactDetails ? nil : e.onlineMeetingURL
        let web = policy.redactDetails ? nil : e.webLink
        return self
            .onTapGesture(count: 2) { if let join { MeetingLauncher.join(join) } }
            .contextMenu {
                if let join { Button { MeetingLauncher.join(join) } label: { Label("Join \(MeetingProvider(url: join).displayName)", systemImage: "video.fill") } }
                if let web { Button { NSWorkspace.shared.open(web) } label: { Label("Open in Outlook on the web", systemImage: "safari") } }
            }
    }
}
