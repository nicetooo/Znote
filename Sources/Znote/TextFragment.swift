import AppKit

/// Builds "scroll to this text" links: a page address plus a text directive
/// (`#:~:text=…`), which Chrome, Edge, Safari and Firefox read as "open the
/// page, scroll to these words and highlight them".
enum TextFragment {
    /// Selections up to this long, on one line, are matched word for word.
    static let exactLimit = 80
    /// Longer ones are matched by how they begin and end; each end is at least
    /// this many characters and this many words, so it is unlikely to occur
    /// earlier on the page.
    static let anchorMinCharacters = 24
    static let anchorMinWords = 4
    static let anchorMaxCharacters = 80

    /// `page` with a directive that finds `text`. An earlier directive is
    /// replaced; an ordinary `#fragment` (a route in a single-page app, say) is kept.
    static func url(_ page: URL, highlighting text: String) -> URL {
        guard let directive = directive(for: text) else { return page }
        var address = page.absoluteString
        if let old = address.range(of: ":~:") { address = String(address[..<old.lowerBound]) }
        if !address.contains("#") { address += "#" }
        return URL(string: address + ":~:" + directive) ?? page
    }

    /// `text=…` for a selection, or nil when there is nothing to look for.
    static func directive(for text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { collapseWhitespace($0) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last else { return nil }

        if lines.count == 1, first.count <= exactLimit {
            return "text=" + encode(first)
        }
        // A directive's start can't cross a paragraph, so a long or
        // multi-paragraph selection is given as "from … to …".
        let start = anchor(first, fromEnd: false)
        let end = anchor(last, fromEnd: true)
        if lines.count == 1, start.count + end.count >= first.count {
            return "text=" + encode(first)     // the two ends would overlap
        }
        return "text=" + encode(start) + "," + encode(end)
    }

    /// The first (or last) few words of `line`. Cut between words — the
    /// browser only matches whole words — using the system's word breaker, so
    /// Chinese and Japanese are cut sensibly too.
    static func anchor(_ line: String, fromEnd: Bool) -> String {
        var words: [Range<String.Index>] = []
        line.enumerateSubstrings(in: line.startIndex..., options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            words.append(range)
        }
        guard !words.isEmpty else { return line }

        var count = 0
        var cut: String.Index?
        for word in fromEnd ? words.reversed() : words {
            let candidate = fromEnd ? line[word.lowerBound...] : line[..<word.upperBound]
            if candidate.count > anchorMaxCharacters, cut != nil { break }
            cut = fromEnd ? word.lowerBound : word.upperBound
            count += 1
            if count >= anchorMinWords, candidate.count >= anchorMinCharacters { break }
        }
        guard let cut else { return line }
        let piece = fromEnd ? line[cut...] : line[..<cut]
        return piece.trimmingCharacters(in: .whitespaces)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Percent-encode everything but ASCII letters, digits and `._~`. In a
    /// text directive `-`, `,` and `&` are syntax, so they must be encoded
    /// too — which rules out the stock URL character sets.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~")
}

/// Takes the user back to where a selection was made.
enum SourceRestorer {
    enum Action: Equatable {
        /// Open the page, scrolled to the selection, in the browser it was read in.
        case openPage(URL, bundleID: String?)
        /// Open the document in the app it was read in.
        case openDocument(URL, bundleID: String?, find: String?)
        /// Nothing to open: bring the app forward.
        case activateApp(bundleID: String, find: String?)
    }

    /// What going back to `source` means, or nil when there is nowhere to go.
    static func action(for source: SelectionSource, text: String,
                       fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Action? {
        if let page = source.webURL {
            return .openPage(TextFragment.url(page, highlighting: text), bundleID: source.bundleID)
        }
        let find = findString(for: text)
        if let file = source.fileURL, fileExists(file.path) {
            return .openDocument(file, bundleID: source.bundleID, find: find)
        }
        if let bundleID = source.bundleID {
            return .activateApp(bundleID: bundleID, find: find)
        }
        return nil
    }

    /// What to put on the Find pasteboard: the selection's first line, which
    /// ⌘G then finds in most apps.
    static func findString(for text: String) -> String? {
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return String(line.prefix(120))
    }

    /// Returns false when the app or document couldn't be opened.
    @discardableResult
    static func perform(_ action: Action) -> Bool {
        let workspace = NSWorkspace.shared
        func app(_ bundleID: String?) -> URL? {
            bundleID.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        }
        func open(_ url: URL, with bundleID: String?) -> Bool {
            if let application = app(bundleID) {
                workspace.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
            return workspace.open(url)
        }

        switch action {
        case .openPage(let url, let bundleID):
            log("SourceRestorer: opening page in \(bundleID ?? "the default browser")")
            return open(url, with: bundleID)
        case .openDocument(let url, let bundleID, let find):
            setFindPasteboard(find)
            log("SourceRestorer: opening document in \(bundleID ?? "the default app")")
            return open(url, with: bundleID)
        case .activateApp(let bundleID, let find):
            setFindPasteboard(find)
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                log("SourceRestorer: activating \(bundleID)")
                return running.activate()
            }
            guard let application = app(bundleID) else {
                log("SourceRestorer: \(bundleID) is not installed")
                return false
            }
            log("SourceRestorer: launching \(bundleID)")
            workspace.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
    }

    private static func setFindPasteboard(_ text: String?) {
        guard let text else { return }
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
