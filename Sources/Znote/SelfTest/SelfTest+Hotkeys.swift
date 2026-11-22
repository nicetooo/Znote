import CoreGraphics
import Foundation

/// Scenario `hotkeys` — KeyMonitor's gesture state machine. No event tap is
/// created (so no Input Monitoring permission is involved): the probe builds
/// CGEvents carrying the same device-modifier bits real key presses do and
/// hands them straight to `handleEvent`, then checks which callbacks fired.
extension SelfTest {
    // Device-dependent bit | generic modifier bit, as real flagsChanged events carry.
    private static let rightCmd: UInt64 = 0x10 | 0x100000
    private static let leftCmd: UInt64 = 0x08 | 0x100000
    private static let rightOpt: UInt64 = 0x40 | 0x80000
    private static let leftOpt: UInt64 = 0x20 | 0x80000

    /// Main-thread-only record of fired callbacks.
    private final class Fired {
        var events: [String] = []
        var otherKeys = 0
    }

    static func runHotkeys(_ r: inout Report) async {
        let monitor = KeyMonitor()
        let fired = Fired()
        var steps: [(String, Bool, [String: String])] = []

        await MainActor.run {
            monitor.onVoiceInputDown = { fired.events.append("voiceDown") }
            monitor.onVoiceInputUp = { fired.events.append("voiceUp") }
            monitor.onVoiceTranslateDown = { fired.events.append("voiceTranslateDown") }
            monitor.onVoiceTranslateUp = { fired.events.append("voiceTranslateUp") }
            monitor.onToggleHistory = { fired.events.append("toggleHistory") }
            monitor.onTranslate = { fired.events.append("translate") }
            monitor.onScreenshot = { fired.events.append("screenshot") }
            monitor.onOtherKeyDown = { fired.otherKeys += 1 }
            monitor.reloadBindings()   // default bindings from the isolated store
        }

        /// Modifier state changed to `flags` (0 = everything released).
        func modifiers(_ flags: UInt64) async {
            await MainActor.run {
                guard let e = CGEvent(source: nil) else { return }
                e.type = .flagsChanged
                e.flags = CGEventFlags(rawValue: flags)
                monitor.handleEvent(type: .flagsChanged, event: e)
            }
        }
        /// An ordinary key went down while `flags` were held.
        func typeKey(holding flags: UInt64) async {
            await MainActor.run {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true) else { return }
                e.flags = CGEventFlags(rawValue: flags)
                monitor.handleEvent(type: .keyDown, event: e)
            }
        }
        func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        func tap(_ key: UInt64) async { await modifiers(key); await wait(80); await modifiers(0) }
        func snapshot() async -> [String] { await MainActor.run { fired.events } }

        /// Run `body`, give pending timers time to fire, compare callbacks.
        func check(_ name: String, _ want: [String], _ body: () async -> Void) async {
            await MainActor.run { fired.events = [] }
            await body()
            await wait(500)
            let got = await snapshot()
            steps.append((name, got == want, got == want
                ? ["fired": got.joined(separator: ",")]
                : ["fired": got.joined(separator: ","), "want": want.joined(separator: ",")]))
        }
        /// Compare callbacks at a point *inside* a gesture.
        func checkNow(_ name: String, _ want: [String]) async {
            let got = await snapshot()
            steps.append((name, got == want, got == want
                ? ["fired": got.joined(separator: ",")]
                : ["fired": got.joined(separator: ","), "want": want.joined(separator: ",")]))
        }

        // ── Default bindings ──
        // Right ⌘: hold = voice input, tap = history.
        // Right ⌥: hold = voice→English, tap = translate, double-tap = screenshot.

        await check("right ⌘ tap → history", ["toggleHistory"]) {
            await tap(rightCmd)
            await wait(50)
            // No double-tap is bound to this key, so the tap must not wait.
            await checkNow("right ⌘ tap fires without delay", ["toggleHistory"])
        }
        await check("right ⌘ hold → voice down, then up on release", ["voiceDown", "voiceUp"]) {
            await modifiers(rightCmd)
            await wait(150)
            await checkNow("right ⌘ held 150 ms: nothing yet", [])
            await wait(450)
            await checkNow("right ⌘ held 600 ms: voice down", ["voiceDown"])
            await modifiers(0)
        }
        await check("right ⌥ tap → translate", ["translate"]) {
            await tap(rightOpt)
            await wait(100)
            // Double-tap is bound here too, so the tap waits to see if a second follows.
            await checkNow("right ⌥ tap waits for a possible second tap", [])
        }
        await check("right ⌥ double-tap → screenshot only", ["screenshot"]) {
            await tap(rightOpt)
            await wait(100)
            await tap(rightOpt)
        }
        await check("right ⌥ hold → voice-translate down/up", ["voiceTranslateDown", "voiceTranslateUp"]) {
            await modifiers(rightOpt)
            await wait(600)
            await modifiers(0)
        }
        await check("⌘+key shortcut is not a tap", []) {
            await modifiers(rightCmd)
            await wait(50)
            await typeKey(holding: rightCmd)   // e.g. Right ⌘ + C
            await wait(50)
            await modifiers(0)
        }
        await check("left ⌘ (unbound) does nothing", []) {
            await tap(leftCmd)
            await modifiers(leftCmd)
            await wait(600)
            await modifiers(0)
        }

        // ── Keys Znote presses itself while the hotkey is held (live dictation) ──
        await MainActor.run { fired.otherKeys = 0 }
        await check("Znote's own backspace and ⌘V during a hold don't end it", ["voiceDown", "voiceUp"]) {
            await modifiers(rightCmd)
            await wait(600)
            await MainActor.run {
                // As posted for real: no modifiers on the backspace, plain ⌘
                // on the V — neither carries the right-⌘ bit that is "held".
                for (key, command) in [(SystemIntegration.keyBackspace, false), (CGKeyCode(9), true)] {
                    if let e = SystemIntegration.keyEvent(key, down: true, command: command) {
                        monitor.handleEvent(type: .keyDown, event: e)
                    }
                }
            }
            await wait(100)
            await checkNow("…the recording is still going after them", ["voiceDown"])
            await modifiers(0)
        }
        let ownKeysReported = await MainActor.run { fired.otherKeys }
        steps.append(("Znote's own keys are not reported as the user's", ownKeysReported == 0, ["reported": "\(ownKeysReported)"]))
        await check("the user's own key during a hold is reported", ["voiceDown", "voiceUp"]) {
            await modifiers(rightCmd)
            await wait(600)
            await typeKey(holding: rightCmd)
            await modifiers(0)
        }
        let userKeysReported = await MainActor.run { fired.otherKeys }
        steps.append(("…exactly once", userKeysReported == 1, ["reported": "\(userKeysReported)"]))

        // ── Self-healing when the system drops events ──
        await check("lost release, healed by the next key press", ["voiceDown", "voiceUp"]) {
            await modifiers(rightCmd)
            await wait(600)
            // The release never arrives; the user types a letter with no modifiers down.
            await typeKey(holding: 0)
        }
        await check("lost release, healed by the next modifier change", ["voiceDown", "voiceUp", "translate"]) {
            await modifiers(rightCmd)
            await wait(600)
            await modifiers(rightOpt)           // ⌘ bit is gone, ⌥ is now down
            await wait(80)
            await modifiers(0)
        }

        // ── Rebinding at runtime ──
        await check("reload during a press cancels the pending hold", []) {
            await modifiers(rightCmd)
            await wait(100)
            await MainActor.run { monitor.reloadBindings() }
            await wait(500)
            await modifiers(0)
        }
        await MainActor.run {
            // Move screenshot to Left ⌥ tap; Right ⌥ now has no double-tap.
            Settings.shared.setHotkeyBinding(HotkeyBinding(side: .left, modifier: .option, gesture: .tap), for: .screenshot)
            monitor.reloadBindings()
        }
        await check("after rebind: right ⌥ tap → translate", ["translate"]) {
            await tap(rightOpt)
            await wait(50)
            await checkNow("after rebind: right ⌥ tap no longer waits", ["translate"])
        }
        await check("after rebind: left ⌥ tap → screenshot", ["screenshot"]) {
            await tap(leftOpt)
        }
        await check("after rebind: right ⌥ double-tap → two translates", ["translate", "translate"]) {
            await tap(rightOpt)
            await wait(100)
            await tap(rightOpt)
        }
        await MainActor.run { Settings.shared.resetHotkeys() }

        for (name, ok, detail) in steps { r.step(name, ok: ok, detail) }
    }
}
