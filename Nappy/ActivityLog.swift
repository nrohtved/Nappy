#if !PUBLIC
import Foundation
import AppKit
import Observation

/// In-memory + on-disk log of what Nappy does (nap, restore, skipped, errors).
@Observable
final class ActivityLog {
    static let shared = ActivityLog()

    private(set) var lines: [String] = []
    @ObservationIgnored private let maxLines = 500
    @ObservationIgnored private let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Nappy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.log")
    }()

    func add(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)"
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        append(toFile: line + "\n")
    }

    func clear() {
        lines.removeAll()
        try? Data().write(to: fileURL)
    }

    var text: String { lines.joined(separator: "\n") }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { try? Data().write(to: fileURL) }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func append(toFile s: String) {
        guard let data = s.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
#else
import Foundation

/// The public build keeps no log: every call is a no-op and its argument is never even built.
final class ActivityLog {
    static let shared = ActivityLog()
    func add(_ line: @autoclosure () -> String) {}
}
#endif
