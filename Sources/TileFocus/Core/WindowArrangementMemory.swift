import Foundation
import CoreGraphics

struct RememberedWindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ frame: CGRect) {
        self.x = Double(frame.origin.x)
        self.y = Double(frame.origin.y)
        self.width = Double(frame.width)
        self.height = Double(frame.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct RememberedWindowPlacement: Codable, Equatable, Identifiable {
    var id: String { signature }
    var signature: String
    var displayName: String
    var frame: RememberedWindowFrame
}

struct WindowArrangementSnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var mode: String
    var layoutKey: String
    var capturedAt: Date
    var placements: [RememberedWindowPlacement]

    init(id: UUID = UUID(), name: String, mode: AppMode, windows: [ManagedWindow], capturedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.mode = mode.rawValue
        self.capturedAt = capturedAt
        self.placements = windows
            .map {
                RememberedWindowPlacement(
                    signature: Self.signature(for: $0),
                    displayName: Self.displayName(for: $0),
                    frame: RememberedWindowFrame($0.frame)
                )
            }
            .sorted { lhs, rhs in
                if lhs.signature != rhs.signature {
                    return lhs.signature < rhs.signature
                }
                return lhs.displayName < rhs.displayName
            }
        self.layoutKey = Self.layoutKey(forSignatures: placements.map(\.signature), mode: mode)
    }

    func matches(windows: [ManagedWindow], mode: AppMode) -> Bool {
        layoutKey == Self.layoutKey(for: windows, mode: mode)
    }

    static func layoutKey(for windows: [ManagedWindow], mode: AppMode) -> String {
        layoutKey(forSignatures: windows.map { signature(for: $0) }, mode: mode)
    }

    static func layoutKey(forSignatures signatures: [String], mode: AppMode) -> String {
        "\(mode.rawValue)::\(signatures.sorted().joined(separator: "||"))"
    }

    static func signature(for window: ManagedWindow) -> String {
        let appIdentifier: String
        if let bundleIdentifier = window.bundleIdentifier, !bundleIdentifier.isEmpty {
            appIdentifier = "bundle:\(bundleIdentifier)"
        } else {
            appIdentifier = "name:\(window.appName)"
        }
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(appIdentifier)|title:\(title)".lowercased()
    }

    static func displayName(for window: ManagedWindow) -> String {
        window.title.isEmpty ? window.appName : "\(window.appName) - \(window.title)"
    }
}
