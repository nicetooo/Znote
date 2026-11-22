import AppKit
import ApplicationServices

/// Where a selection was made: the app, its window and — when the app can
/// say — the page or document that was open.
struct SelectionSource: Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    /// The page (http/https) or document (file) that was open.
    var url: String?

    var isEmpty: Bool { appName == nil && bundleID == nil && windowTitle == nil && url == nil }

    /// The page URL, when the selection was made on a web page.
    var webURL: URL? {
        guard let url, let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return parsed
    }

    /// The document, when the selection was made in a file.
    var fileURL: URL? {
        guard let url, let parsed = URL(string: url), parsed.isFileURL else { return nil }
        return parsed
    }

    /// One line for the UI: "github.com · Page title", "notes.txt · TextEdit",
    /// "Slack · #general", or just the app.
    var label: String {
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let host = webURL?.host {
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return [site, title].compactMap { $0 }.joined(separator: " · ")
        }
        if let file = fileURL {
            return [file.lastPathComponent, appName].compactMap { $0 }.joined(separator: " · ")
        }
        return [appName, title].compactMap { $0 }.joined(separator: " · ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Reads a `SelectionSource` from a running app.
///
/// The window title and the document or page address come from the
/// Accessibility API (the app already holds that permission for its hotkeys).
/// A browser whose window doesn't carry its page address is asked over Apple
/// Events instead — which macOS confirms with the user once per browser.
enum SelectionSourceReader {
    enum BrowserFamily: Equatable {
        case safari, chromium

        /// AppleScript expression for the address of the page in front.
        var urlExpression: String {
            switch self {
            case .safari: return "URL of front document"
            case .chromium: return "URL of active tab of front window"
            }
        }
    }

    static func browserFamily(bundleID: String?) -> BrowserFamily? {
        guard let bundleID else { return nil }
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return .safari
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
             "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
             "com.microsoft.edgemac.Dev", "com.brave.Browser", "com.brave.Browser.beta",
             "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser",
             "company.thebrowser.dia":
            return .chromium
        default:
            return nil
        }
    }

    /// Read `app` off the main thread and deliver the result on the main queue.
    static func read(_ app: NSRunningApplication, completion: @escaping (SelectionSource) -> Void) {
        let pid = app.processIdentifier, name = app.localizedName, bundleID = app.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let source = read(pid: pid, appName: name, bundleID: bundleID)
            DispatchQueue.main.async { completion(source) }
        }
    }

    /// Blocking: an unresponsive app costs up to `axTimeout`, a slow browser
    /// up to `browserTimeout`. Don't call on the main thread.
    static func read(pid: pid_t, appName: String?, bundleID: String?) -> SelectionSource {
        var source = SelectionSource(appName: appName, bundleID: bundleID)
        let window = focusedWindow(pid: pid)
        if let window {
            source.windowTitle = string(window, kAXTitleAttribute)?.nilIfEmpty
            source.url = string(window, kAXDocumentAttribute)?.nilIfEmpty
        }
        if let url = source.url, !isUsable(url) { source.url = nil }
        // Chrome and its relatives put the page address in the window's
        // AXDocument, so they are answered already. Safari keeps it on the
        // web area inside the window. Failing both, the browser is asked.
        if source.webURL == nil, let family = browserFamily(bundleID: bundleID), let bundleID {
            if let window, let found = webAreaURL(in: window), isUsable(found) {
                source.url = found
            } else if let asked = askBrowser(bundleID: bundleID, family: family), isUsable(asked) {
                source.url = asked
            }
        }
        return source
    }

    /// Only addresses that can be opened again are worth keeping.
    static func isUsable(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    // MARK: - Accessibility

    static let axTimeout: Float = 0.6

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        return element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The address of the first web page found inside `window`: a bounded
    /// breadth-first walk for an AXWebArea, which carries AXURL.
    static func webAreaURL(in window: AXUIElement, maxNodes: Int = 400) -> String? {
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let node = queue.removeFirst()
            visited += 1
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                return string(node, kAXURLAttribute)
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        return nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let text = value as? String { return text }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    // MARK: - Apple Events

    static let browserTimeout: TimeInterval = 1.5

    /// Ask a browser for the address of its front page. Runs `osascript` so
    /// the wait happens in another process and can be cut short; macOS still
    /// attributes the request to Znote. Returns nil on refusal, timeout, or
    /// when the browser has no window.
    static func askBrowser(bundleID: String, family: BrowserFamily,
                           timeout: TimeInterval = browserTimeout) -> String? {
        let result = runAppleScript("tell application id \"\(bundleID)\" to get \(family.urlExpression)",
                                    timeout: timeout)
        if let error = result.error { log("SelectionSource: \(bundleID) didn't give its URL — \(error)") }
        return result.output?.nilIfEmpty
    }

    static func runAppleScript(_ script: String, timeout: TimeInterval) -> (output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return (nil, "couldn't start osascript: \(error.localizedDescription)") }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (nil, "no answer within \(timeout) s")
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, message?.nilIfEmpty ?? "osascript exited with \(process.terminationStatus)")
        }
        return (output, nil)
    }
}
