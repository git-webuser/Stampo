import ApplicationServices
import Foundation

/// Fast, bounded AX probes let the twenty panel cycles observe 100 ms frame
/// samples without XCTest's per-query idle wait dominating the scenario.
struct AccessibilityNode {
    let element: AXUIElement

    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    var identifier: String { attribute(kAXIdentifierAttribute) as? String ?? "" }
    var title: String { attribute(kAXTitleAttribute) as? String ?? "" }
    var value: String { attribute(kAXValueAttribute).map { String(describing: $0) } ?? "" }
    var role: String { attribute(kAXRoleAttribute) as? String ?? "" }
    var children: [AccessibilityNode] {
        (attribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map { AccessibilityNode(element: $0) }
    }
    var frame: CGRect? {
        guard let position = attribute(kAXPositionAttribute), let size = attribute(kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    func first(where matches: (AccessibilityNode) -> Bool) -> AccessibilityNode? {
        var pending = [self]
        var visited = 0
        while !pending.isEmpty && visited < 2000 {
            let node = pending.removeFirst()
            visited += 1
            if matches(node) { return node }
            pending += node.children
        }
        return nil
    }

    func press() throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw E2EFailure("AXPress failed for \(identifier): \(result.rawValue)") }
    }
}

extension E2EApp {
    var accessibilityRoot: AccessibilityNode? {
        guard let processID else { return nil }
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 2)
        return AccessibilityNode(element: root)
    }

    func liveElement(_ control: Control) -> AccessibilityNode? {
        accessibilityRoot?.first { $0.identifier == control.rawValue }
    }
}
