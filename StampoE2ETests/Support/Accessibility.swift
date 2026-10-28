import ApplicationServices
import Foundation

/// Fast, bounded AX queries distinguish an absent element from a failed read.
struct AccessibilityNode {
    let element: AXUIElement

    func attribute(_ name: String, required: Bool = false) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .success { return value }
        // Optional attributes are legitimately unsupported by many leaf nodes.
        if !required && (result == .attributeUnsupported || result == .noValue) { return nil }
        throw E2EFailure("AX attribute \(name) failed: \(result.rawValue)")
    }

    var identifier: String { get throws { try attribute(kAXIdentifierAttribute) as? String ?? "" } }
    var title: String { get throws { try attribute(kAXTitleAttribute) as? String ?? "" } }
    var value: String { get throws { try attribute(kAXValueAttribute).map { String(describing: $0) } ?? "" } }
    var role: String { get throws { try attribute(kAXRoleAttribute) as? String ?? "" } }
    var children: [AccessibilityNode] {
        get throws {
            (try attribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map { AccessibilityNode(element: $0) }
        }
    }
    var frame: CGRect? {
        get throws {
            guard let position = try attribute(kAXPositionAttribute), let size = try attribute(kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: point, size: extent)
        }
    }

    func first(where matches: (AccessibilityNode) throws -> Bool) throws -> AccessibilityNode? {
        var pending = [self]
        var visited = 0
        while visited < pending.count {
            guard visited < 2000 else { throw E2EFailure("AX traversal exceeded the 2000-node limit") }
            let node = pending[visited]
            visited += 1
            if try matches(node) { return node }
            pending += try node.children
        }
        return nil
    }

    func press() throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw E2EFailure("AXPress failed: \(result.rawValue)") }
    }
}

extension E2EApp {
    var accessibilityRoot: AccessibilityNode {
        get throws {
            guard let pid = processID ?? accessibilityProbeProcessID ?? expectedQuitProcessID else {
                throw E2EFailure("AX query has no isolated process PID")
            }
            let element = AXUIElementCreateApplication(pid)
            let timeout = AXUIElementSetMessagingTimeout(element, 2)
            guard timeout == .success else { throw E2EFailure("AX messaging timeout setup failed: \(timeout.rawValue)") }
            let root = AccessibilityNode(element: element)
            // A successful root response is required even when searching for
            // absence; a dead/unresponsive process must never look like nil.
            guard try root.attribute(kAXChildrenAttribute, required: true) is [AXUIElement] else {
                throw E2EFailure("AX root children returned a malformed response for PID \(pid)")
            }
            return root
        }
    }

    func liveElement(_ control: Control) throws -> AccessibilityNode? {
        try accessibilityRoot.first { try $0.identifier == control.rawValue }
    }
}
