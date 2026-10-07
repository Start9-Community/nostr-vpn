import AppKit

/// Shared by the connection and selling rows, and the menu bar badge.
/// The backend supplies attention separately from translated status copy.
enum InternetExitIndicator: Equatable {
    case hidden, connecting, connected, attention

    init(vpnEnabled: Bool, source: String, active: Bool, needsAttention: Bool) {
        if !vpnEnabled || source == "direct" {
            self = .hidden
        } else if needsAttention {
            self = .attention
        } else if active {
            self = .connected
        } else {
            self = .connecting
        }
    }

    init(sellingEnabled: Bool, ready: Bool) {
        self = !sellingEnabled ? .hidden : ready ? .connected : .connecting
    }

    static func tray(connection: Self, selling: Self, vpnEnabled: Bool, vpnActive: Bool) -> Self {
        if connection == .attention { return .attention }
        if connection == .connecting || selling == .connecting || (vpnEnabled && !vpnActive) {
            return .connecting
        }
        if connection == .connected || selling == .connected || (vpnEnabled && vpnActive) {
            return .connected
        }
        return .hidden
    }

    var color: NSColor? {
        switch self {
        case .hidden: nil
        case .connecting: .systemOrange
        case .connected: .systemGreen
        case .attention: .systemRed
        }
    }

    var image: NSImage? {
        guard let color else { return nil }
        return NSImage(size: NSSize(width: 8, height: 8), flipped: false) { bounds in
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// A separate view preserves the brand icon's automatic light/dark template
/// rendering, while the badge retains its status color. Clicks reach the menu.
final class InternetExitBadgeView: NSView {
    var indicator = InternetExitIndicator.hidden {
        didSet { isHidden = indicator == .hidden; needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let color = indicator.color else { return }
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
