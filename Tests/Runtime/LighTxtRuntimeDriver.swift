#if LIGHTXT_STANDALONE_RUNTIME_DRIVER
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Exact-process runtime driver used by the signed Release acceptance pass.
///
/// Every command takes an explicit PID (except `launch`). This intentionally
/// avoids application-name targeting: a developer may have another LighTxt
/// build open while the isolated QA copy is exercised.
@main
struct LighTxtRuntimeDriver {
    static func main() {
        do {
            try run()
        } catch {
            let message = "LighTxtRuntimeDriver: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { throw DriverError.usage }
        arguments.removeFirst()

        switch command {
        case "trusted":
            print(AXIsProcessTrusted() ? "true" : "false")
        case "make-json":
            let parsed = try ParsedArguments(arguments)
            let destination = URL(fileURLWithPath: try parsed.required("path"))
            let itemCount = parsed.int("items") ?? 520
            let payloadBytes = parsed.int("payload-bytes") ?? (512 << 10)
            try makePagedJSON(
                destination: destination,
                itemCount: itemCount,
                payloadBytes: payloadBytes
            )
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            print("path=\(destination.path) bytes=\(size) items=\(itemCount)")
        case "launch":
            try launch(arguments)
        case "wait-running":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let timeout = parsed.double("timeout") ?? 15
            try wait(timeout: timeout, message: "PID \(pid) did not become accessible") {
                NSRunningApplication(processIdentifier: pid) != nil && application(pid: pid) != nil
            }
            print(pid)
        case "dump":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let maximumDepth = parsed.int("depth") ?? 14
            let maximumElements = parsed.int("limit") ?? 4_000
            guard let app = application(pid: pid) else { throw DriverError.noProcess(pid) }
            var emitted = 0
            dumpTree(app, depth: 0, maximumDepth: maximumDepth, maximumElements: maximumElements, emitted: &emitted)
        case "wait-text":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let query = try parsed.required("text")
            let timeout = parsed.double("timeout") ?? 30
            try wait(timeout: timeout, message: "No accessible text contained ‘\(query)’ for PID \(pid)") {
                findMatch(pid: pid, query: .text(query), maximumElements: 25_000) != nil
            }
            print(query)
        case "wait-missing-text":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let query = try parsed.required("text")
            let timeout = parsed.double("timeout") ?? 30
            try wait(timeout: timeout, message: "Accessible text still contained ‘\(query)’ for PID \(pid)") {
                findMatch(pid: pid, query: .text(query), maximumElements: 25_000) == nil
            }
            print(query)
        case "frame":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let match = try requiredMatch(pid: pid, parsed: parsed)
            let frame = try elementFrame(match.element)
            print(frameDescription(frame))
        case "range-frame":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let needle = try parsed.required("needle")
            let match = try requiredMatch(pid: pid, parsed: parsed)
            print(frameDescription(try rangeFrame(match.element, containing: needle)))
        case "count-role":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let role = try parsed.required("role")
            let minimumX = parsed.cgFloat("min-x") ?? -.greatestFiniteMagnitude
            let frames = try frames(pid: pid, matchingRole: role, minimumX: minimumX)
            print("count=\(frames.count)")
            for frame in frames { print(frameDescription(frame)) }
        case "actions":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let match = try requiredMatch(pid: pid, parsed: parsed)
            print(actionNames(match.element).joined(separator: ","))
        case "press":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let match = try requiredMatch(pid: pid, parsed: parsed)
            try performPress(match)
            print("pressed")
        case "right-click":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let match = try requiredMatch(pid: pid, parsed: parsed)
            let frame = try postRightClick(pid: pid, match: match)
            print(frameDescription(frame))
        case "select":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let match = try requiredMatch(pid: pid, parsed: parsed)
            try select(match)
            print("selected")
        case "disclose":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let match = try requiredMatch(pid: pid, parsed: parsed)
            let expanded = parsed.bool("expanded") ?? true
            try setDisclosed(match, expanded: expanded)
            print(expanded ? "expanded" : "collapsed")
        case "set-value":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let value = try parsed.required("value")
            let match = try requiredMatch(pid: pid, parsed: parsed)
            try setValue(match, value: value)
            print(value)
        case "set-number":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            guard let value = parsed.double("value") else {
                throw DriverError.failed("Invalid --value")
            }
            let match = try requiredMatch(pid: pid, parsed: parsed)
            try setNumber(match, value: value)
            print(value)
        case "value":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let match = try requiredMatch(pid: pid, parsed: parsed)
            print(stringValue(match.element, attribute: kAXValueAttribute) ?? "")
        case "resize":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let width = try parsed.requiredCGFloat("width")
            let height = try parsed.requiredCGFloat("height")
            let window = try requiredWindow(pid: pid)
            try setSize(window, NSSize(width: width, height: height))
            if let x = parsed.cgFloat("x"), let y = parsed.cgFloat("y") {
                try setPosition(window, NSPoint(x: x, y: y))
            }
            try wait(timeout: 3, message: "Window did not reach requested size") {
                guard let size = elementSize(window) else { return false }
                return abs(size.width - width) <= 2 && abs(size.height - height) <= 2
            }
            print(frameDescription(try elementFrame(window)))
        case "window-frame":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            print(frameDescription(try elementFrame(requiredWindow(pid: pid))))
        case "window-id":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            print(try requiredWindowID(pid: pid))
        case "capture":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let path = try parsed.required("path")
            try captureWindow(pid: pid, destination: URL(fileURLWithPath: path))
            print(path)
        case "key":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let key = try parsed.required("key")
            let modifiers = Set((parsed.string("modifiers") ?? "").split(separator: ",").map(String.init))
            try postKey(pid: pid, key: key, modifiers: modifiers)
            print(key)
        case "type":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let text = try parsed.required("text")
            try postText(pid: pid, text: text)
            print(text)
        case "rss":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            print(try residentBytes(pid: pid))
        case "pasteboard":
            print(NSPasteboard.general.string(forType: .string) ?? "")
        case "pasteboard-inspect":
            let value = NSPasteboard.general.string(forType: .string) ?? ""
            let preview = value.prefix(80)
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            print(
                "characters=\(value.count) utf8=\(value.utf8.count) "
                    + "ellipsis=\(value.hasSuffix("…")) preview=\(preview)"
            )
        case "wait-exit":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            let timeout = parsed.double("timeout") ?? 15
            try wait(timeout: timeout, message: "PID \(pid) did not exit") {
                NSRunningApplication(processIdentifier: pid) == nil
            }
            print("exited")
        case "terminate":
            let parsed = try ParsedArguments(arguments)
            let pid = try parsed.requiredPID()
            guard let running = NSRunningApplication(processIdentifier: pid) else {
                print("already-exited")
                return
            }
            guard running.terminate() else { throw DriverError.failed("Could not terminate PID \(pid)") }
            try wait(timeout: parsed.double("timeout") ?? 15, message: "PID \(pid) did not terminate") {
                NSRunningApplication(processIdentifier: pid) == nil
            }
            print("terminated")
        default:
            throw DriverError.failed("Unknown command: \(command)")
        }
    }

    // MARK: - Launching

    private static func makePagedJSON(
        destination: URL,
        itemCount: Int,
        payloadBytes: Int
    ) throws {
        guard itemCount > 256, payloadBytes >= 0 else {
            throw DriverError.failed("Paged JSON requires more than 256 items and a nonnegative payload")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DriverError.failed("Could not create \(destination.path)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("{\n  \"metadata\": {\"fixture\": \"signed Release paging\", \"editable\": true},\n  \"records\": [\n".utf8))
        let payload = Data(repeating: 0x61, count: payloadBytes)
        for index in 0..<itemCount {
            if index > 0 { try handle.write(contentsOf: Data(",\n".utf8)) }
            try handle.write(contentsOf: Data("    {\"id\": \(index), \"marker\": \"record-\(index)\", \"payload\": \"".utf8))
            try handle.write(contentsOf: payload)
            try handle.write(contentsOf: Data("\"}".utf8))
        }
        try handle.write(contentsOf: Data("\n  ],\n  \"tail\": \"selection-target\"\n}\n".utf8))
        try handle.synchronize()
    }

    private static func launch(_ arguments: [String]) throws {
        let parsed = try ParsedArguments(arguments)
        let appURL = URL(fileURLWithPath: try parsed.required("app")).standardizedFileURL
        let fileURL = URL(fileURLWithPath: try parsed.required("file")).standardizedFileURL
        guard FileManager.default.fileExists(atPath: appURL.path),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw DriverError.failed("The app or document path does not exist")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: configuration
        ) { application, error in
            launched = application
            launchError = error
            semaphore.signal()
        }

        let deadline = DispatchTime.now() + .seconds(Int(parsed.double("timeout") ?? 30))
        guard semaphore.wait(timeout: deadline) == .success else {
            throw DriverError.failed("LaunchServices timed out opening \(fileURL.lastPathComponent)")
        }
        if let launchError { throw launchError }
        guard let launched else { throw DriverError.failed("LaunchServices returned no application") }
        print(launched.processIdentifier)
    }

    // MARK: - Accessibility

    private struct ElementMatch {
        let element: AXUIElement
        let ancestors: [AXUIElement]
    }

    private enum Query {
        case text(String)
        case identifier(String)
        case roleAndText(role: String, text: String)
    }

    private static func application(pid: pid_t) -> AXUIElement? {
        guard NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private static func requiredWindow(pid: pid_t) throws -> AXUIElement {
        guard let app = application(pid: pid) else { throw DriverError.noProcess(pid) }
        if let focused: AXUIElement = attribute(app, kAXFocusedWindowAttribute) { return focused }
        if let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute), let first = windows.first { return first }
        throw DriverError.failed("PID \(pid) has no accessible window")
    }

    private static func requiredMatch(pid: pid_t, parsed: ParsedArguments) throws -> ElementMatch {
        let query: Query
        if let identifier = parsed.string("identifier") {
            query = .identifier(identifier)
        } else if let role = parsed.string("role"), let text = parsed.string("text") {
            query = .roleAndText(role: role, text: text)
        } else if let text = parsed.string("text") {
            query = .text(text)
        } else {
            throw DriverError.failed("Element command requires --text, --identifier, or --role with --text")
        }
        guard let match = findMatch(pid: pid, query: query, maximumElements: 25_000) else {
            throw DriverError.failed("Could not find requested accessible element for PID \(pid)")
        }
        return match
    }

    private static func findMatch(pid: pid_t, query: Query, maximumElements: Int) -> ElementMatch? {
        guard let app = application(pid: pid) else { return nil }
        var queue: [(AXUIElement, [AXUIElement])] = [(app, [])]
        var cursor = 0
        var seen = Set<CFHashCode>()
        while cursor < queue.count, cursor < maximumElements {
            let (element, ancestors) = queue[cursor]
            cursor += 1
            let hash = CFHash(element)
            guard seen.insert(hash).inserted else { continue }
            if matches(element, query: query) { return ElementMatch(element: element, ancestors: ancestors) }
            for child in children(of: element) {
                queue.append((child, ancestors + [element]))
            }
        }
        return nil
    }

    private static func frames(pid: pid_t, matchingRole role: String, minimumX: CGFloat) throws -> [CGRect] {
        guard let app = application(pid: pid) else { throw DriverError.noProcess(pid) }
        var queue = [app]
        var cursor = 0
        var seen = Set<CFHashCode>()
        var output: [CGRect] = []
        while cursor < queue.count, cursor < 25_000 {
            let element = queue[cursor]
            cursor += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            if stringValue(element, attribute: kAXRoleAttribute) == role,
               let frame = try? elementFrame(element), frame.maxX > minimumX {
                output.append(frame)
            }
            for child in children(of: element) {
                if let frame = try? elementFrame(child), frame.maxX <= minimumX { continue }
                queue.append(child)
            }
        }
        return output
    }

    private static func matches(_ element: AXUIElement, query: Query) -> Bool {
        switch query {
        case let .identifier(expected):
            return stringValue(element, attribute: kAXIdentifierAttribute) == expected
        case let .text(expected):
            return searchableStrings(element).contains { $0.localizedCaseInsensitiveContains(expected) }
        case let .roleAndText(role, expected):
            return stringValue(element, attribute: kAXRoleAttribute) == role
                && searchableStrings(element).contains { $0.localizedCaseInsensitiveContains(expected) }
        }
    }

    private static func searchableStrings(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
            .compactMap { stringValue(element, attribute: $0) }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var output: [AXUIElement] = []
        for name in [kAXChildrenAttribute, kAXRowsAttribute, kAXVisibleRowsAttribute, kAXColumnsAttribute] {
            if let values: [AXUIElement] = attribute(element, name) {
                output.append(contentsOf: values)
            }
        }
        return output
    }

    private static func dumpTree(
        _ element: AXUIElement,
        depth: Int,
        maximumDepth: Int,
        maximumElements: Int,
        emitted: inout Int
    ) {
        guard emitted < maximumElements else { return }
        emitted += 1
        let role = stringValue(element, attribute: kAXRoleAttribute) ?? "?"
        let subrole = stringValue(element, attribute: kAXSubroleAttribute) ?? ""
        let identifier = stringValue(element, attribute: kAXIdentifierAttribute) ?? ""
        let text = searchableStrings(element)
            .map { $0.replacingOccurrences(of: "\n", with: "\\n") }
            .joined(separator: " | ")
        let frame = (try? elementFrame(element)).map(frameDescription) ?? ""
        let actions = actionNames(element).joined(separator: ",")
        print("\(String(repeating: "  ", count: depth))\(role)\(subrole.isEmpty ? "" : ":\(subrole)") id=\(identifier) frame=\(frame) actions=\(actions) text=\(text)")
        guard depth < maximumDepth else { return }
        var seen = Set<CFHashCode>()
        for child in children(of: element) where seen.insert(CFHash(child)).inserted {
            dumpTree(child, depth: depth + 1, maximumDepth: maximumDepth, maximumElements: maximumElements, emitted: &emitted)
        }
    }

    private static func performPress(_ match: ElementMatch) throws {
        for element in [match.element] + match.ancestors.reversed() {
            if actionNames(element).contains(kAXPressAction as String) {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                guard result == .success else { throw DriverError.ax("press", result) }
                return
            }
        }
        throw DriverError.failed("Element and ancestors do not support AXPress")
    }

    private static func select(_ match: ElementMatch) throws {
        for element in [match.element] + match.ancestors.reversed() {
            if setBooleanAttribute(element, kAXSelectedAttribute, true) { return }
            if actionNames(element).contains(kAXPressAction as String) {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result == .success { return }
            }
        }
        throw DriverError.failed("Element and ancestors could not be selected")
    }

    private static func setDisclosed(_ match: ElementMatch, expanded: Bool) throws {
        for element in [match.element] + match.ancestors.reversed() {
            if setBooleanAttribute(element, kAXDisclosingAttribute, expanded) { return }
        }
        throw DriverError.failed("Element and ancestors do not expose AXDisclosing")
    }

    private static func setValue(_ match: ElementMatch, value: String) throws {
        for element in [match.element] + match.ancestors.reversed() {
            _ = setBooleanAttribute(element, kAXFocusedAttribute, true)
            if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success {
                if actionNames(element).contains(kAXConfirmAction as String) {
                    let result = AXUIElementPerformAction(element, kAXConfirmAction as CFString)
                    guard result == .success else { throw DriverError.ax("confirm", result) }
                } else {
                    let pid = try elementPID(element)
                    try postKey(pid: pid, key: "return", modifiers: [])
                }
                return
            }
        }
        throw DriverError.failed("Element and ancestors do not accept AXValue")
    }

    private static func setNumber(_ match: ElementMatch, value: Double) throws {
        for element in [match.element] + match.ancestors.reversed() {
            _ = setBooleanAttribute(element, kAXFocusedAttribute, true)
            if AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                NSNumber(value: value)
            ) == .success {
                if actionNames(element).contains(kAXConfirmAction as String) {
                    let result = AXUIElementPerformAction(element, kAXConfirmAction as CFString)
                    guard result == .success else { throw DriverError.ax("confirm", result) }
                }
                return
            }
        }
        throw DriverError.failed("Element and ancestors do not accept a numeric AXValue")
    }

    private static func setBooleanAttribute(_ element: AXUIElement, _ name: String, _ value: Bool) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, name as CFString, value as CFBoolean) == .success
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func stringValue(_ element: AXUIElement, attribute name: String) -> String? {
        if let value: String = attribute(element, name) { return value }
        if let value: NSAttributedString = attribute(element, name) { return value.string }
        if let value: NSNumber = attribute(element, name) { return value.stringValue }
        return nil
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private static func elementFrame(_ element: AXUIElement) throws -> CGRect {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else {
            throw DriverError.failed("Element has no accessible frame")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            throw DriverError.failed("Could not decode accessible frame")
        }
        return CGRect(origin: position, size: size)
    }

    private static func rangeFrame(_ element: AXUIElement, containing needle: String) throws -> CGRect {
        guard let value = stringValue(element, attribute: kAXValueAttribute) else {
            throw DriverError.failed("Element has no accessible text value")
        }
        let range = (value as NSString).range(of: needle, options: .backwards)
        guard range.location != NSNotFound else {
            throw DriverError.failed("Accessible text does not contain ‘\(needle)’")
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            throw DriverError.failed("Could not encode accessible text range")
        }
        var rawFrame: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &rawFrame
        )
        guard result == .success, let rawFrame,
              CFGetTypeID(rawFrame) == AXValueGetTypeID() else {
            throw DriverError.ax("range bounds", result)
        }
        let frameValue = rawFrame as! AXValue
        var frame = CGRect.zero
        guard AXValueGetValue(frameValue, .cgRect, &frame) else {
            throw DriverError.failed("Could not decode accessible text range bounds")
        }
        return frame
    }

    private static func elementSize(_ element: AXUIElement) -> CGSize? {
        guard let value: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func setSize(_ element: AXUIElement, _ size: CGSize) throws {
        var mutable = size
        guard let value = AXValueCreate(.cgSize, &mutable) else { throw DriverError.failed("Could not create AX size") }
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        guard result == .success else { throw DriverError.ax("resize", result) }
    }

    private static func setPosition(_ element: AXUIElement, _ position: CGPoint) throws {
        var mutable = position
        guard let value = AXValueCreate(.cgPoint, &mutable) else { throw DriverError.failed("Could not create AX position") }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard result == .success else { throw DriverError.ax("move", result) }
    }

    private static func elementPID(_ element: AXUIElement) throws -> pid_t {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success else { throw DriverError.ax("get PID", result) }
        return pid
    }

    // MARK: - Keyboard, capture, metrics

    private static func postKey(pid: pid_t, key: String, modifiers: Set<String>) throws {
        let normalized = key.lowercased()
        let keyCodes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "g": 5, "z": 6,
            "q": 12, "w": 13, "return": 36, "enter": 36, "tab": 48,
            "escape": 53, "space": 49,
        ]
        guard let code = keyCodes[normalized] else { throw DriverError.failed("Unsupported key: \(key)") }
        var flags: CGEventFlags = []
        if modifiers.contains("command") { flags.insert(.maskCommand) }
        if modifiers.contains("shift") { flags.insert(.maskShift) }
        if modifiers.contains("option") { flags.insert(.maskAlternate) }
        if modifiers.contains("control") { flags.insert(.maskControl) }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw DriverError.failed("Could not create keyboard event")
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.05)
    }

    private static func postText(pid: pid_t, text: String) throws {
        let units = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw DriverError.failed("Could not create text event")
        }
        units.withUnsafeBufferPointer {
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
            up.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
        }
        down.postToPid(pid)
        up.postToPid(pid)
    }

    @discardableResult
    private static func postRightClick(pid: pid_t, match: ElementMatch) throws -> CGRect {
        guard let running = NSRunningApplication(processIdentifier: pid) else {
            throw DriverError.noProcess(pid)
        }
        _ = running.activate(options: [.activateAllWindows])
        let candidates = [match.element] + match.ancestors.reversed()
        let row = candidates.first {
            stringValue($0, attribute: kAXRoleAttribute) == kAXRowRole as String
        }
        let frame = try elementFrame(row ?? match.element)
        guard frame.width > 2, frame.height > 2 else {
            throw DriverError.failed("Requested element has no clickable area")
        }
        let point = CGPoint(
            x: min(frame.maxX - 2, frame.minX + max(24, frame.width * 0.55)),
            y: frame.midY
        )
        guard let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .right
        ), let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: point,
            mouseButton: .right
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: .right
        ) else {
            throw DriverError.failed("Could not create a right-click event")
        }
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.15)
        return frame
    }

    private static func requiredWindowID(pid: pid_t) throws -> CGWindowID {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw DriverError.failed("Could not enumerate windows")
        }
        let candidates = raw.compactMap { info -> (CGWindowID, Int, Double)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
            return (number, layer, width * height)
        }
        guard let best = candidates.filter({ $0.1 == 0 }).max(by: { $0.2 < $1.2 }) else {
            throw DriverError.failed("No on-screen layer-zero window for PID \(pid)")
        }
        return best.0
    }

    private static func captureWindow(pid: pid_t, destination: URL) throws {
        let windowID = try requiredWindowID(pid: pid)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l\(windowID)", destination.path]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw DriverError.failed("screencapture failed for window \(windowID)")
        }
    }

    private static func residentBytes(pid: pid_t) throws -> UInt64 {
        var taskInfo = proc_taskinfo()
        let expected = Int32(MemoryLayout<proc_taskinfo>.size)
        let copied = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, expected)
        }
        guard copied == expected else { throw DriverError.failed("proc_pidinfo failed for PID \(pid)") }
        return taskInfo.pti_resident_size
    }

    private static func frameDescription(_ frame: CGRect) -> String {
        "x=\(Int(frame.origin.x.rounded())) y=\(Int(frame.origin.y.rounded())) width=\(Int(frame.width.rounded())) height=\(Int(frame.height.rounded()))"
    }

    private static func wait(timeout: TimeInterval, message: String, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        throw DriverError.failed(message)
    }
}

private struct ParsedArguments {
    private var values: [String: String] = [:]

    init(_ raw: [String]) throws {
        var cursor = 0
        while cursor < raw.count {
            let key = raw[cursor]
            guard key.hasPrefix("--"), cursor + 1 < raw.count else { throw DriverError.usage }
            values[String(key.dropFirst(2))] = raw[cursor + 1]
            cursor += 2
        }
    }

    func string(_ key: String) -> String? { values[key] }
    func required(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else { throw DriverError.failed("Missing --\(key)") }
        return value
    }
    func requiredPID() throws -> pid_t {
        guard let raw = values["pid"], let pid = pid_t(raw), pid > 0 else { throw DriverError.failed("Invalid --pid") }
        return pid
    }
    func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }
    func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
    func cgFloat(_ key: String) -> CGFloat? { values[key].flatMap(Double.init).map { CGFloat($0) } }
    func requiredCGFloat(_ key: String) throws -> CGFloat {
        guard let value = cgFloat(key) else { throw DriverError.failed("Invalid --\(key)") }
        return value
    }
    func bool(_ key: String) -> Bool? {
        values[key].flatMap { raw in
            switch raw.lowercased() {
            case "true", "1", "yes": true
            case "false", "0", "no": false
            default: nil
            }
        }
    }
}

private enum DriverError: Error, LocalizedError {
    case usage
    case noProcess(pid_t)
    case failed(String)
    case ax(String, AXError)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: LighTxtRuntimeDriver <command> [--key value ...]"
        case let .noProcess(pid):
            return "No running application for PID \(pid)"
        case let .failed(message):
            return message
        case let .ax(operation, error):
            return "Accessibility \(operation) failed with \(error.rawValue)"
        }
    }
}
#endif
