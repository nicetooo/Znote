import AppKit
import Foundation

// A self-test run keeps its log next to its report instead of in the app's log.
private let logPath = SelfTest.request?.dir.appendingPathComponent("app.log").path ?? "/tmp/znote.log"

// Log to file since stdout is swallowed in GUI apps
func log(_ msg: String) {
    let line = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
    NSLog("%@", msg)
}

log("main.swift starting")

// Agent self-test (selftest/run.sh): run the probe and exit before any UI,
// event tap or microphone is set up.
if let request = SelfTest.request {
    log("Self-test mode: \(request.scenario) → \(request.dir.path)")
    Task.detached {
        exit(await SelfTest.run(request))
    }
    // A run loop, not dispatchMain(): that would hand the main queue to
    // another thread, and AppKit insists its views are made on this one.
    CFRunLoopRun()
    exit(2)
}

let app = NSApplication.shared
log("NSApplication created")

app.setActivationPolicy(.accessory)
log("Activation policy set to .accessory")

let delegate = AppDelegate()
app.delegate = delegate
log("Delegate set, calling app.run()")

app.run()
