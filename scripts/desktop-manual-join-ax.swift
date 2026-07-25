#!/usr/bin/env swift
import ApplicationServices
import Foundation

enum DriverError: Error, CustomStringConvertible {
    case usage(String)
    case accessibilityPermission
    case missing(String)
    case action(String, AXError)
    case value(String, AXError)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .accessibilityPermission:
            return "Accessibility permission is required to drive the macOS release UI"
        case .missing(let identifier): return "visible control did not appear: \(identifier)"
        case .action(let identifier, let error):
            return "AXPress failed for \(identifier): \(error.rawValue)"
        case .value(let identifier, let error):
            return "AX value update failed for \(identifier): \(error.rawValue)"
        }
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    attribute(element, name) as? Bool
}

func descendants(_ root: AXUIElement) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var pending = [root]
    var visited = 0
    while let element = pending.popLast(), visited < 20_000 {
        visited += 1
        found.append(element)
        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            pending.append(contentsOf: children.reversed())
        }
    }
    return found
}

func find(
    _ application: AXUIElement,
    identifier: String,
    timeout: TimeInterval = 15
) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = descendants(application).first(where: {
            stringAttribute($0, kAXIdentifierAttribute) == identifier
                && boolAttribute($0, kAXHiddenAttribute) != true
        }) {
            return element
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline

    let controls = descendants(application).compactMap { element -> String? in
        let identifier = stringAttribute(element, kAXIdentifierAttribute)
        guard !identifier.isEmpty else { return nil }
        let role = stringAttribute(element, kAXRoleAttribute)
        return "\(role):\(identifier)"
    }
    fputs("Visible AX identifiers: \(controls.joined(separator: ", "))\n", stderr)
    throw DriverError.missing(identifier)
}

func containsVisible(_ application: AXUIElement, identifier: String) -> Bool {
    descendants(application).contains {
        stringAttribute($0, kAXIdentifierAttribute) == identifier
            && boolAttribute($0, kAXHiddenAttribute) != true
    }
}

func press(
    _ application: AXUIElement,
    _ identifier: String,
    successIdentifier: String? = nil
) throws {
    let deadline = Date().addingTimeInterval(5)
    var lastError = AXError.actionUnsupported
    var attempted = false
    repeat {
        if attempted {
            if let successIdentifier,
               containsVisible(application, identifier: successIdentifier) {
                Thread.sleep(forTimeInterval: 0.25)
                return
            }
            if successIdentifier == nil,
               !containsVisible(application, identifier: identifier) {
                Thread.sleep(forTimeInterval: 0.25)
                return
            }
        }
        do {
            var element = try find(application, identifier: identifier, timeout: 0.5)
            for _ in 0..<8 {
                var actionNames: CFArray?
                let actionError = AXUIElementCopyActionNames(element, &actionNames)
                if actionError == .success,
                   let names = actionNames as? [String],
                   names.contains(kAXPressAction) {
                    attempted = true
                    let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
                    if error == .success {
                        Thread.sleep(forTimeInterval: 0.25)
                        return
                    }
                    lastError = error
                    break
                }
                guard let parent = attribute(element, kAXParentAttribute) else {
                    break
                }
                element = parent as! AXUIElement
            }
        } catch DriverError.missing {
            lastError = .cannotComplete
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    throw DriverError.action(identifier, lastError)
}

func setValue(_ application: AXUIElement, _ identifier: String, _ value: String) throws {
    let element = try find(application, identifier: identifier)
    let focusError = AXUIElementSetAttributeValue(
        element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    guard focusError == .success else {
        throw DriverError.value(identifier, focusError)
    }
    var pid = pid_t()
    let pidError = AXUIElementGetPid(application, &pid)
    guard pidError == .success else {
        throw DriverError.value(identifier, pidError)
    }

    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: keyDown
            )
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    postKey(0, flags: .maskCommand) // Command-A
    let utf16 = Array(value.utf16)
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    utf16.withUnsafeBufferPointer { buffer in
        down?.keyboardSetUnicodeString(
            stringLength: buffer.count,
            unicodeString: buffer.baseAddress
        )
    }
    down?.postToPid(pid)
    CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.postToPid(pid)

    let deadline = Date().addingTimeInterval(2)
    repeat {
        if stringAttribute(element, kAXValueAttribute) == value {
            Thread.sleep(forTimeInterval: 0.15)
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw DriverError.value(identifier, .cannotComplete)
}

func run() throws {
    let args = CommandLine.arguments
    guard args.count == 6, let pid = pid_t(args[1]) else {
        throw DriverError.usage(
            "usage: desktop-manual-join-ax <pid> <joiner|admin|joined> <value-1> <value-2> <expected-process-name>"
        )
    }
    guard AXIsProcessTrusted() else {
        throw DriverError.accessibilityPermission
    }
    let application = AXUIElementCreateApplication(pid)
    let processName = stringAttribute(application, kAXTitleAttribute)
    if !processName.isEmpty && processName != args[5] {
        throw DriverError.usage(
            "AX PID \(pid) belongs to \(processName), expected \(args[5])"
        )
    }

    switch args[2] {
    case "joiner":
        try press(
            application,
            "manual-join-choose-join",
            successIdentifier: "manual-join-expander"
        )
        try press(
            application,
            "manual-join-expander",
            successIdentifier: "manual-join-admin-id"
        )
        try setValue(application, "manual-join-admin-id", args[3])
        try setValue(application, "manual-join-network-id", args[4])
        try press(application, "manual-join-submit")
    case "admin":
        try press(
            application,
            "manual-join-admin-open",
            successIdentifier: "manual-join-admin-device-id"
        )
        try setValue(application, "manual-join-admin-device-id", args[3])
        try setValue(application, "manual-join-admin-device-name", args[4])
        try press(application, "manual-join-admin-submit")
    case "joined":
        _ = try find(application, identifier: "vpn-service-toggle")
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if containsVisible(application, identifier: "manual-join-choose-join") {
                throw DriverError.usage(
                    "joined roster is durable, but the shipped UI still shows first-run Join Network"
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
    default:
        throw DriverError.usage("phase must be joiner, admin, or joined")
    }
    print("MACOS_MANUAL_JOIN_UI_\(args[2].uppercased())_OK")
}

do {
    try run()
} catch {
    fputs("macOS manual-join UI driver failed: \(error)\n", stderr)
    exit(1)
}
