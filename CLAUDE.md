# Znote — Project Instructions

## What is Znote
Native Swift macOS menu bar app. Voice→Text (WhisperKit, CoreML), translate selection, screenshot, history. All in one app, no Electron, no Python GUI — fully native Swift.

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
./selftest/run.sh                              # Build build/Znote.app, run the string check + logic, history, hotkeys, clipboard, editor, voice (~1.5 min)
./selftest/run.sh logic hotkeys                # Only these scenarios
./selftest/run.sh translate                    # Selection translation against Google (needs network; not in the default set)
SKIP_BUILD=1 ./selftest/run.sh                 # Re-run without rebuilding
APP=/Applications/Znote.app ./selftest/run.sh  # Test the installed copy
```
Each scenario launches the real binary in self-test mode (`ZNOTE_SELFTEST` + `ZNOTE_SELFTEST_DIR`, handled at the top of `main.swift` before any UI) and writes `build/selftest/<scenario>/report.json`. Exit 0 = passed. **Run it after any change to non-UI code.**

| Scenario | Covers |
|----------|--------|
| `logic` | `Settings` (language → Whisper args, model migration, hotkey bindings/conflicts), silence gate, `HallucinationFilter`, i18n tables |
| `history` | `HistoryStore` against a seeded 3000-row old-schema DB (migration, limit, search, filters, deletes) |
| `hotkeys` | `KeyMonitor` gesture state machine, fed synthetic `CGEvent`s (no event tap) |
| `clipboard` | `SystemIntegration`: borrowing the clipboard for ⌘C / ⌘V and restoring every item and type, on a private pasteboard with a fake front app |
| `editor` | Screenshot annotation (every tool, pixel-checked), undo/redo, export, toolbar + hover-preview placement. Writes `canvas.png` / `toolbar.png` / … to the scenario dir — **look at them** after UI changes |
| `voice` | `say`-synthesized WAVs through real `WhisperService` (needs the model cached) |
| `translate` | `TranslationService` end to end |

- In self-test mode `Settings.store` is a throwaway defaults domain and `HistoryStore` opens its DB in the scenario dir — **new code must go through `Settings.store`, never `UserDefaults.standard`**, or tests will write to the user's real settings.
- A step marked `known:` in a probe is a documented, unfixed bug (shows as `KNOWN`, doesn't fail the run). Remove the mark when fixing it.
- `./selftest/bench.sh <model>…` compares Whisper models (character error rate + ms/clip on 48 reference clips). A measurement, not a pass/fail. Results so far: `docs/tests/2026-11-21-model-bench.md`.
- Probes live in `Sources/Znote/SelfTest/`; seed data comes from `selftest/seed.py`.
- Self-test runs on a `CFRunLoopRun()` main thread; anything that creates AppKit views/windows must go through `MainActor.run` (see the `editor` case in `SelfTest.run`).
- Don't edit `selftest/run.sh` while a run is in progress — bash reads it as it goes.
- Not covered: mic capture, real key presses through the event tap, ⌘C/⌘V simulation, real `screencapture`/recording, real pointer interaction with any UI.

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
| Right ⌥ tap | Translate selection (has 0.3s delay for double-tap detection) |
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

## Translation
- Show result in **floating overlay** (NOT paste in-place). User reads it or clicks Copy.
- Google Translate free endpoint. Direction comes from `TranslationService.plan(for:)`: Chinese → English, everything else → Chinese.
- **Mixed Chinese/English text** is the tricky case. NLLanguageRecognizer misreads it (it mostly sees the Latin letters), so direction is decided from the text's makeup: which language supplies the grammar words, then which script starts and ends it, then bulk. And Google's `sl=auto` calls anything containing Chinese characters Chinese, so an English sentence with Chinese words must be sent with `sl=en` or it comes back untouched.
- The query text is percent-encoded with a strict allow-list — `.urlQueryAllowed` lets `&` and `+` through and truncates the selection.
- When changing any of this, run `./selftest/run.sh logic translate` (63 texts).

## UI Style
- All overlays (recording, translation, history) use **dark floating panel** style: borderless NSPanel, dark background, rounded corners
- History panel: NOT native macOS window — matches overlay theme
- Recording overlay: waveform animation with `sqrt(rms) * 2.5` for dynamic range; two-layer shadow stack for uniform glow

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
├── SelfTest/               # Agent self-test probes, one file per scenario (only run under ZNOTE_SELFTEST)
├── TranslationService.swift # NLLanguageRecognizer + Google Translate
├── SystemIntegration.swift # Simulate Cmd+C/V, clipboard save/restore
├── RecordingOverlay.swift  # Floating waveform animation panel (two-layer glow)
├── TranslationOverlay.swift # Loading dots → result + Copy button
├── HistoryStore.swift      # SQLite CRUD
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
