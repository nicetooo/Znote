# Znote — Project Instructions

## What is Znote
Native Swift macOS menu bar app. Voice→Text (WhisperKit, CoreML), translate selection, notes on a selection (with a way back to where it was made), screenshot, history. All in one app, no Electron, no Python GUI — fully native Swift.

## Build & Run
```bash
# One-shot build + refresh .app + sign with stable Developer ID:
./sign.sh                 # Debug build
./sign.sh release         # Release build
./sign.sh --verify        # Verify the current bundle's signature

# Run:
open build/Znote.app
```

Signing identity: `Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)`. Because the identity is stable across rebuilds, **TCC (Accessibility + Input Monitoring) permissions persist** — no re-granting after every `swift build`.

### Self-test (no mic, key presses or user data involved)
```bash
./selftest/run.sh                              # Build build/Znote.app, run the string check + logic, history, hotkeys, clipboard, editor, notes, voice (~1.5 min)
./selftest/run.sh logic hotkeys                # Only these scenarios
./selftest/run.sh translate                    # Selection translation against Google (needs network; not in the default set)
SKIP_BUILD=1 ./selftest/run.sh                 # Re-run without rebuilding
APP=/Applications/Znote.app ./selftest/run.sh  # Test the installed copy
./selftest/context.sh                          # Diagnostic: what the real apps on this Mac say about where they are (see below)
```
Each scenario launches the real binary in self-test mode (`ZNOTE_SELFTEST` + `ZNOTE_SELFTEST_DIR`, handled at the top of `main.swift` before any UI) and writes `build/selftest/<scenario>/report.json`. Exit 0 = passed. **Run it after any change to non-UI code.**

| Scenario | Covers |
|----------|--------|
| `logic` | `Settings` (language → Whisper args, model migration, hotkey bindings/conflicts), silence gate, `HallucinationFilter`, i18n tables, live dictation's edit diffing / typer / focus gate |
| `history` | `HistoryStore` against a seeded 3000-row old-schema DB (migration, limit, search, filters, deletes) |
| `hotkeys` | `KeyMonitor` gesture state machine, fed synthetic `CGEvent`s (no event tap); Znote's own keys during a hold are ignored |
| `clipboard` | `SystemIntegration`: borrowing the clipboard for ⌘C / ⌘V and restoring every item and type, on a private pasteboard with a fake front app; live dictation's backspace + paste edits against that fake app |
| `editor` | Screenshot annotation (every tool, pixel-checked), undo/redo, export, toolbar + hover-preview placement. Writes `canvas.png` / `toolbar.png` / … to the scenario dir — **look at them** after UI changes |
| `notes` | Selection notes: scroll-to-text links, source labels, the way back, the Translate / Note menu and the note panel (clicked and typed into through `NSWindow.sendEvent`), round trip through the store. Writes `selection-menu.png` / `note-panel.png` — **look at them** after UI changes |
| `voice` | `say`-synthesized WAVs through real `WhisperService` (needs the model cached); three of them also played back in real time through the live-dictation loop (the report has the timeline of what was written when) |
| `translate` | `TranslationService` end to end |

- In self-test mode `Settings.store` is a throwaway defaults domain and `HistoryStore` opens its DB in the scenario dir — **new code must go through `Settings.store`, never `UserDefaults.standard`**, or tests will write to the user's real settings.
- A step marked `known:` in a probe is a documented, unfixed bug (shows as `KNOWN`, doesn't fail the run). Remove the mark when fixing it.
- `./selftest/bench.sh <model>…` compares Whisper models (character error rate + ms/clip on 48 reference clips). A measurement, not a pass/fail. Results so far: `docs/tests/2026-11-21-model-bench.md`.
- Probes live in `Sources/Znote/SelfTest/`; seed data comes from `selftest/seed.py`.
- **Tests must not compete with the system for focus**: no key windows on the real screen, no real key presses, no activating apps. Windows are ordered in off every display and driven with `NSWindow.sendEvent`; anything that opens or activates is replaced by a recorder.
- Self-test runs on a `CFRunLoopRun()` main thread; anything that creates AppKit views/windows must go through `MainActor.run` (see the `editor` case in `SelfTest.run`).
- Don't edit `selftest/run.sh` while a run is in progress — bash reads it as it goes.
- `./selftest/context.sh` is a diagnostic, not part of the default set: it starts the app through LaunchServices (so it has Znote's real Accessibility grant) and asks the running browsers and apps for their window title / document / page address. The report records only the shape of each answer, never a title or address. Run it after touching `SelectionSource.swift`. `PANEL=1` (the real note panel on screen, taking the keyboard, with real key presses) and `OPEN=1` (opens a tab in Chrome) **take focus away from whoever is using the Mac — never run them as an agent; they are for the user to run by hand**. They are also flaky when something else is competing for focus.
- `ZNOTE_LINK_SAMPLES=<json of {page,text}> ./selftest/run.sh notes` writes the links Znote would open to `build/selftest/notes/links.json`, for checking against a real browser.
- Not covered: mic capture, real key presses through the event tap, ⌘C/⌘V simulation, live dictation's keys arriving in a real app while the hotkey is physically held, real `screencapture`/recording, real pointer interaction with any UI (the selection menu appearing at the real pointer included).

### Manual build (when not using sign.sh)
```bash
swift build                          # Debug
swift build -c release               # Release

cp .build/debug/Znote build/Znote.app/Contents/MacOS/Znote
cp Sources/Znote/Resources/Info.plist build/Znote.app/Contents/Info.plist
cp Sources/Znote/Resources/Znote.icns build/Znote.app/Contents/Resources/Znote.icns
codesign --force --deep --options runtime \
    --sign "Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)" \
    --entitlements Sources/Znote/Resources/Znote.entitlements \
    build/Znote.app
```

## Release
```bash
./release.sh v0.9.0 --dry-run          # Run every check, change nothing
./release.sh v0.9.0 --notes notes.md   # The whole release, from this machine
./release.sh --list                    # List tags
```
`release.sh` checks the tree / gh login / notary access, runs the self-test, stamps the version into `Info.plist` and the site (committing if it changed), runs `package.sh` + `dmg.sh`, pushes main and the tag, creates the GitHub Release with `Znote.dmg` + `Znote.zip`, then downloads the published DMG and compares it with the local one. It asks once before pushing (`-y` to skip).

- Releases are published **only** from here — the app must be signed and notarized with the local Developer ID. CI (`.github/workflows/build.yml`) just verifies the tag builds; it publishes nothing.
- The site's download button points at the latest release's `Znote.dmg`, so a release without the DMG breaks the site. `release.sh` always uploads it.
- Notarization needs the Mac unlocked (the keychain profile is unreadable while the screen is locked) and Apple's developer agreements current — the scripts print Apple's actual error.

## Distribution (local signed + notarized)
```bash
./package.sh             # Produces dist/Znote.zip (signed + notarized + stapled)
./dmg.sh                 # Produces dist/Znote.dmg (signed + notarized + stapled)
```
One-time setup (stores Apple ID app-specific password in Keychain):
```bash
xcrun notarytool store-credentials "Znote-notary" \
    --apple-id "nicetooo.a@gmail.com" \
    --team-id "ZVZ4AP4H2T"
```

## Key Architecture

- **Fully native Swift** — WhisperKit (CoreML) replaces previous Python mlx_whisper dependency
- **No extra apps** — one self-contained .app bundle
- **Logging**: Use `log()` function (writes to `/tmp/znote.log`, mode 0600, rotated to `.1` past 2 MB), NOT `print()`. It records dictated and selected text — keep it private
- **App name**: "Znote" everywhere — bundle name, menu, window titles
- **Bundle identifier**: `com.znote.app`

## Hotkeys (Right-side modifier keys only — defaults; user can rebind side+modifier in Settings)
| Gesture | Action |
|---------|--------|
| Right ⌘ hold (>0.3s) | Push-to-talk recording |
| Right ⌘ tap (<0.3s) | Toggle History window |
| Right ⌥ tap | Selection menu: Translate / Note (has 0.3s delay for double-tap detection). Tap again while the menu is up = Translate |
| Right ⌥ double-tap | Drag a region → Capture (↵) / Annotate (E) / Record (R) |

Key codes: Right ⌘ = keyCode 54, Right ⌥ = keyCode 61. Device flags: NX_DEVICERCMDKEYMASK = 0x10, NX_DEVICERALTKEYMASK = 0x40.

## Whisper Behavior
- **Engine**: WhisperKit (Swift + CoreML), models cached at `~/Library/Application Support/Znote/Models/`
- **Compute units**: large models → `cpuAndGPU`; smaller models → `cpuAndNeuralEngine` (ANE)
- **Speed flags**: `withoutTimestamps=true`, `wordTimestamps=false`, `temperatureFallbackCount=0`, `prewarm=true`
- **Language detection**: Do NOT force language unless exactly 1 language selected in Settings (after deduplication — zh-Hans and zh-Hant both map to "zh"). Multiple selected → auto-detect → verify with NLLanguageRecognizer → retry with forced language if mismatch.
- **Token cleanup**: Strip `<\|...\|>` tokens via regex; merge multi-line output into single line
- **Chinese simplified/traditional**: Separate options in Settings. Only simplified → `CFStringTransform("Hant-Hans")`. Only traditional → `CFStringTransform("Hans-Hant")`. Both → no conversion.
- **Silence/hallucination**: Audio level threshold (peak RMS) + minimum duration check + expanded hallucination phrase blacklist (incl. "thank"/"thanks" variants)

## Live dictation
- With "Type While Speaking" on (`Settings.liveDictation`, default on), text is written at the cursor while the hotkey is still held, and corrected as recognition changes. Whisper is not a streaming model: `LiveDictation` re-transcribes everything recorded so far, pass after pass (`WhisperService.transcribePreview`), so text arrives once per pass (2–3 s on Large V3) and trails the voice by about that much. On release the whole recording is transcribed once more, as before, and what was written is corrected into that.
- **How it is written** (`SystemIntegration.apply(_: LiveEdit)`): backspaces for what goes, clipboard + ⌘V for what comes. Not Unicode key events — with a Chinese input method on, typed Latin letters would be taken as pinyin. The clipboard is borrowed once per dictation and given back by `endLive()`; fragments carry `org.nspasteboard.TransientType`.
- **No backspace while the hotkey is held.** Explicit flags are not enough: in a real app (seen in an Electron one) a backspace posted while ⌘ was physically down deleted the whole line, i.e. arrived as ⌘⌫. So in another app previews only ever add text (`LiveTyper(correctsWhileSpeaking: false)`): the last word of each preview waits for the next pass; a preview that hears some written words differently still has its continuation appended (`LiveText.continuation`, lined up by edit distance — holding such previews back froze the text after a few words in real use); and the single correction comes with the final text — after release, and only if no ⌘/⌥/⌃ is down then. The note panel involves no keys and is corrected freely.
- **Keys are posted while the hotkey is held.** Every event Znote posts gets its flags set explicitly (a backspace that inherited ⌘ would delete to the start of the line) and carries `SystemIntegration.syntheticEventTag`; `KeyMonitor` skips tagged events — it syncs modifier state from key-down flags, so otherwise the first backspace would read as "hotkey released". Build key events only through `SystemIntegration.keyEvent`.
- **Safety gate** (`LiveTarget`): corrections are backspaces, and in a list of mail a backspace deletes. Live writing happens only when the focused element has a text selection (`AXSelectedTextRange`), or is the window / app / web area, or the app names nothing; otherwise the text is pasted once on release, as before. A click, a key press of the user's own or another app coming forward during the dictation stops all taking-back: from then on text is only added.
- In the note panel it is written directly (`NoteInputPanel.apply`), no keys involved.
- Previews are written without closing punctuation (`LiveText.interim`) — Whisper ends whatever it has heard with a full stop and takes it back on the next pass. And a new preview keeps what is already written wherever the two differ only in punctuation, spacing or capitals (`LiveText.settled`): those flip from pass to pass (Turbo especially) and each flip would mean retyping everything after it. Only the final text is written exactly.
- When changing any of this, run `./selftest/run.sh logic hotkeys clipboard notes voice`. Typing into a real app with the real hotkey held can only be seen by using it.

## Translation
- Show result in **floating overlay** (NOT paste in-place). User reads it or clicks Copy.
- Google Translate free endpoint. Direction comes from `TranslationService.plan(for:)`: Chinese → English, everything else → Chinese.
- **Mixed Chinese/English text** is the tricky case. NLLanguageRecognizer misreads it (it mostly sees the Latin letters), so direction is decided from the text's makeup: which language supplies the grammar words, then which script starts and ends it, then bulk. And Google's `sl=auto` calls anything containing Chinese characters Chinese, so an English sentence with Chinese words must be sent with `sl=en` or it comes back untouched.
- The query text is percent-encoded with a strict allow-list — `.urlQueryAllowed` lets `&` and `+` through and truncates the selection.
- When changing any of this, run `./selftest/run.sh logic translate` (63 texts).

## Selection notes
- Right ⌥ tap reads the selection **and where it was made** (`SelectionSource`: app, bundle id, window title, page or document URL), then shows `SelectionMenu` beside the pointer. Translate goes on as before; Note opens `NoteInputPanel`. Both are saved to History with the source.
- **Where** comes from the Accessibility API, which the app already has: the focused window's `AXTitle` and `AXDocument` (Chrome puts the page URL there; document apps put a `file://` URL), and for Safari the `AXURL` of the `AXWebArea` inside the window. Apple Events (`osascript`, off the main thread) is only the fallback for a known browser that gave neither — that is the one path needing the Automation permission (`NSAppleEventsUsageDescription` + the `automation.apple-events` entitlement).
- **The way back** (`SourceRestorer`): a web page is reopened in the same browser with a text directive (`#:~:text=…`, built by `TextFragment`) so the browser scrolls to the selection and highlights it; a document is reopened in its app with the selection's first line on the Find pasteboard (⌘G); otherwise the app is brought forward.
- Text directives match whole words only, and `-` `,` `&` are syntax: `TextFragment` cuts its start/end anchors with the system word breaker and percent-encodes everything but `A-Za-z0-9._~`. An existing `#fragment` is kept (`#route:~:text=…`).
- The menu never takes the keyboard (the selection in the other app would lose focus). The note panel must — it is a `.nonactivatingPanel` that becomes key, so Znote is still not activated (`NSApp.isActive` reads true then; look at `NSWorkspace.frontmostApplication` instead). ↵ saves, ⇧↵ breaks the line, esc cancels; while an input method is composing those keys are the input method's. A click outside does not close it.
- Dictation while the note panel has the keyboard is written straight into the note (`NoteInputPanel.insert`), not pasted.
- **No main menu → no ⌘V**: ⌘V/⌘C/⌘X/⌘A/⌘Z are key equivalents of an app's Edit menu, not something text fields handle. `EditMenu.install()` gives this menu-bar app an Edit menu that is never shown, so they work in the note panel, the History search field and the screenshot editor's text tool. Don't remove it.
- When changing any of this, run `./selftest/run.sh notes history`. That the real panel gets the real keyboard can only be seen on screen — leave that to the user.

## UI Style
- All overlays (recording, translation, history) use **dark floating panel** style: borderless NSPanel, dark background, rounded corners
- History panel: NOT native macOS window — matches overlay theme
- Recording overlay: waveform animation with `sqrt(rms) * 2.5` for dynamic range; two-layer shadow stack for uniform glow. After release it stays up as a rolling wave (`showProcessing()`) until the text is written — no text labels for status

## Model Management
- Dropdown for **browsing/managing** (NOT activating). Separate "Activate" button.
- Five models listed: Large V3, Large V3 Compact (`large-v3_947MB`), Large V3 Turbo, Large V3 Turbo Compact (`large-v3-v20240930_626MB`), Small. Measured: the compact variants save disk but are slower and worse in noise than their originals; uncompressed Turbo matched Large V3's accuracy at 2.4× the speed (no translate task).
- WhisperKit downloads to `~/Library/Application Support/Znote/Models/models/argmaxinc/whisperkit-coreml/<variant>/`

## Known Constraints
- **Both permissions needed**: CGEventTap needs Input Monitoring (key events) AND Accessibility (simulating Cmd+C/V)
- **NSView `tag` conflict**: Cannot override `tag` with stored property in NSView subclass — use different name (e.g., `index`)
- **SMAppService**: Requires app in /Applications for Launch at Login
- **First launch after signing identity change**: TCC entries are tied to the signing identity. If you ever switch certs (e.g. revoke + recreate), all permissions need to be re-added once. Subsequent rebuilds keep TCC because the identity stays the same.
- **Entitlements XML must NOT contain comments** — AMFI parser rejects them and codesign fails

## GitHub
- **Repo**: `nicetooo/Znote` (SSH: `git@github.com:nicetooo/Znote.git`)
- **Actions**: `.github/workflows/build.yml` — build check on `v*` tag push + manual dispatch; publishes nothing (`contents: read`)

## Project Structure
```
Sources/Znote/
├── main.swift              # Entry, custom log(), NSApplication setup
├── AppDelegate.swift       # Menu bar, coordinates all services, screenshot
├── KeyMonitor.swift        # CGEventTap: Right ⌘/⌥ tap/hold/double-tap, flag-sync state machine
├── AudioRecorder.swift     # AVAudioEngine, mono mixdown, RMS level
├── WhisperService.swift    # WhisperKit, onModelReady callback, ANE/GPU compute selection
├── HallucinationFilter.swift # Strips trailing "Thank you."-style Whisper hallucinations
├── LiveDictation.swift     # Writing text while it is spoken: preview loop, edit diffing, typer, focus gate
├── SelfTest/               # Agent self-test probes, one file per scenario (only run under ZNOTE_SELFTEST)
├── TranslationService.swift # NLLanguageRecognizer + Google Translate
├── SystemIntegration.swift # Simulate Cmd+C/V, clipboard save/restore, live edits (backspace + paste)
├── RecordingOverlay.swift  # Floating waveform animation panel (two-layer glow)
├── TranslationOverlay.swift # Loading dots → result + Copy button
├── SelectionSource.swift   # Where a selection was made: app, window title, page/document URL (AX, Apple Events fallback)
├── SelectionMenu.swift     # Translate / Note menu beside the pointer
├── NoteInputPanel.swift    # Note panel: quoted selection, source line, text input
├── TextFragment.swift      # Scroll-to-text links + SourceRestorer (the way back to a source)
├── HistoryStore.swift      # SQLite CRUD (voice, translation, screenshot, recording, note)
├── HistoryWindow.swift     # Dark floating panel: search, date pills, expand rows
├── HistoryHoverPreview.swift # Hover-aware table + floating image preview beside the History panel
├── AnnotationDocument.swift # Screenshot annotations: model, undo/redo, drawing, PNG export (no views)
├── ScreenshotEditor.swift  # Annotation canvas, toolbar and the two panels shown over the captured region
├── Settings.swift          # UserDefaults, hotkey customization types, model list
├── SettingsWindow.swift    # Hotkey pills, language select, model manage, Launch at Login
└── Resources/
    ├── Info.plist           # com.znote.app, LSUIElement=true
    ├── Znote.entitlements   # Hardened runtime entitlements (mic, WhisperKit relaxations)
    └── Znote.icns
```

Root-level scripts:
- `sign.sh` — build + refresh bundle + sign with stable Developer ID
- `package.sh` — produces signed + notarized + stapled `dist/Znote.zip`
- `dmg.sh` — produces signed + notarized + stapled `dist/Znote.dmg`
- `release.sh` — the whole release: checks, self-test, version stamp, package, tag, GitHub Release, verification
- `install.sh` — legacy build-from-source installer (predates DMG distribution)
