# Znote

Native macOS menu bar app for voice-to-text, voice → English translation, screen capture (screenshot + recording), and translation of selected text. 100% on-device speech via [WhisperKit](https://github.com/argmaxinc/WhisperKit) — no cloud APIs, no subscriptions, no Python.

🌐 [Project site](https://nicetooo.github.io/Znote/) · 📥 [Latest release](https://github.com/nicetooo/Znote/releases/latest)

## What it does

| Shortcut | Action |
|----------|--------|
| **Hold Right ⌘** | Push-to-talk → transcribes speech → pastes text at cursor |
| **Tap Right ⌘** | Toggle History window |
| **Hold Right ⌥** | Push-to-talk → translates speech to English → pastes |
| **Tap Right ⌥** | Translate selected text (auto-detected source ↔ English/Chinese) |
| **Double-tap Right ⌥** | Region capture → pick 📷 Capture, ✏️ Annotate or 🎥 Record |

All hotkeys are rebindable in Settings — pick side, modifier, and gesture per action.

- **Voice → text**: WhisperKit (CoreML) on the Apple Neural Engine / GPU. Multi-language, with optional language pinning for best accuracy.
- **Voice → English** *(any language)*: Same push-to-talk flow but Whisper runs `task=translate` — speak Chinese / Japanese / French / etc., get English. Requires Large V3 (Turbo doesn't support translate).
- **Region capture**: Drag a rectangle (works across external displays), then a small picker asks Capture, Annotate or Record.
  - Keyboard: **↵** = Capture, **E** = Annotate, **R** = Record, **ESC** = cancel
  - Annotate → the screenshot opens in place with pen, arrow, rectangle, ellipse, text and mosaic tools, 6 colours, 3 widths, undo/redo. **↵** flattens it to the clipboard and History, **ESC** discards it
  - Screenshot → PNG saved to disk + image on the clipboard
  - Recording → MOV (H.264 video + AAC system audio) via ScreenCaptureKit; the floating stop pill in the corner finalizes the file
- **Translation overlay**: Google Translate free endpoint. Chinese → English, everything else → Chinese; mixed Chinese/English text is handled (direction is decided from which language supplies the sentence's grammar). Result floats in a dark panel with a Copy button.
- **History**: SQLite + on-disk media. Filter pills: All / Voice / Translation / Screenshot / Recording. Hovering a screenshot row shows a preview beside the panel; expanded rows show inline previews, recordings play in an embedded AVPlayer, the Folder button reveals media in Finder.

## Requirements

- Apple Silicon Mac (M1 / M2 / M3 / M4)
- macOS 14 (Sonoma) or later
- That's it — no Python, no pip, no ffmpeg, no brew

## Install

**From release** *(recommended)*

Download from [Releases](https://github.com/nicetooo/Znote/releases/latest) or the [download button on the site](https://nicetooo.github.io/Znote/). Both `.dmg` and `.zip` are signed + notarized by Apple — double-click to run.

**Build from source**

```bash
git clone git@github.com:nicetooo/Znote.git
cd Znote
./sign.sh             # debug build + sign + refresh build/Znote.app
./sign.sh --install   # also copy to /Applications and relaunch
```

`sign.sh` uses the project's stable Developer ID identity. You'll need your own certificate if you fork — see `CLAUDE.md` for the manual `codesign` command.

## Permissions

Znote needs four macOS permissions (System Settings → Privacy & Security):

1. **Accessibility** — to simulate Cmd+C/V for clipboard operations
2. **Input Monitoring** — to detect Right ⌘ and Right ⌥ key events
3. **Microphone** — for voice input
4. **Screen Recording** — for region capture (screenshot + recording)

The menu bar icon shows orange warnings for missing Accessibility / Input Monitoring. Microphone / Screen Recording trigger the standard system dialogs on first use.

> Releases are signed with a stable Developer ID Application certificate, so TCC permissions persist across upgrades. If you rebuild locally with ad-hoc signing, permissions reset on each rebuild — use `./sign.sh` to keep them.

## Settings

Click the waveform icon in the menu bar → Settings:

- **Languages** — pick which language(s) you speak. Exactly one selected → Whisper is pinned to that language (best accuracy). Multiple → auto-detect with cross-verification + retry.
- **Whisper Model** — download / switch between models. Default is `large-v3`. Stored at `~/Library/Application Support/Znote/Models/`.
- **Silence Filter** — microphone sensitivity + minimum recording duration to suppress Whisper's silence hallucinations.
- **Hotkeys** — for each of the 5 actions, choose side (L/R) + modifier (⌘/⌥/⌃) + gesture (Tap / Double-tap / Hold). Voice Input and Voice → English are locked to Hold.

### Available models

| Model | Size | Notes |
|-------|------|-------|
| **Large V3** | ~3 GB | Best quality · multilingual · proper punctuation · supports translate |
| Large V3 Compact | ~950 MB | Large V3 in a third of the disk space · slower and less accurate in noise · supports translate |
| Large V3 Turbo | ~1.6 GB | ~8× faster · multilingual · weaker punctuation · **no translate** |
| Large V3 Turbo Compact | ~630 MB | Turbo in under half the disk space · slower than Turbo · **no translate** |
| Small | ~500 MB | Lightweight · English-focused (Chinese accuracy degraded) |

> Voice → English needs `task=translate`, which Turbo dropped when it pruned the decoder for speed. Use Large V3 for that hotkey.

## How it works

- **Speech recognition**: `AVAudioEngine` records audio, WhisperKit transcribes via CoreML on ANE / GPU. The model preloads at app startup. Output is cleaned (special-token strip, multi-line merge), with optional Hans ↔ Hant conversion.
- **Voice translation**: Same audio pipeline, but `DecodingOptions.task = .translate`. Output is always English regardless of source; language verification / Hans-Hant conversion are skipped.
- **Translation overlay**: `TranslationService.plan(for:)` picks the direction (NLLanguageRecognizer for single-script text; grammar-word counts for mixed Chinese/English, which the recognizer misreads) → Google's free `translate.googleapis.com/translate_a/single?client=gtx` endpoint, with the source language named explicitly when the target is Chinese → dark floating panel.
- **Region capture**: A custom NSPanel overlay per NSScreen handles the drag. Crosshair cursor is forced via a tracking area + `cursorUpdate(with:)` (because `addCursorRect` is unreliable on borderless nonactivating panels). Selected rect is in NSScreen coords (bottom-left); converted to top-left primary-display pixels for `screencapture -R -o -x`, and to display-local top-left for `SCStreamConfiguration.sourceRect`.
- **Screen recording**: `SCStream` cropped to the selection at the native scale of whichever screen the region's center sits on. Output through `AVAssetWriter` (H.264 video + AAC 48kHz stereo for system audio). `SCContentFilter` excludes all Znote-owned windows so the floating stop pill isn't baked into the recording.
- **History**: SQLite at `~/Library/Application Support/Znote/history.sqlite` with an `image_path` column reused for both PNG screenshots and MOV recordings; `delete()` cleans the on-disk file too. Inline previews via `NSImageView` for images and `AVPlayerView` for video.
- **Hotkeys**: Global `CGEventTap` on `.flagsChanged` + `.keyDown`. The state machine syncs from `event.flags` on every event so a missed press/release self-heals on the next event (e.g. after a `tapDisabledByUserInput` drop). Multiple gestures (tap / double-tap / hold) can coexist on the same physical key.

## Project structure

```
Sources/
├── CSQLite/                       # C shim for system sqlite3
└── Znote/
    ├── main.swift                 # App entry, custom log()
    ├── AppDelegate.swift          # Menu bar + service coordinator + recording mode
    ├── KeyMonitor.swift           # CGEventTap, multi-gesture flag-sync state machine
    ├── AudioRecorder.swift        # AVAudioEngine + RMS level
    ├── WhisperService.swift       # WhisperKit transcribe / translate
    ├── HallucinationFilter.swift  # Strips Whisper's trailing "Thank you."-style hallucinations
    ├── TranslationService.swift   # Direction planning + Google Translate
    ├── SystemIntegration.swift    # Cmd+C/V simulation + clipboard save/restore
    ├── RecordingOverlay.swift     # Waveform animation panel (+ "→ English" hint)
    ├── TranslationOverlay.swift   # Translation result panel
    ├── RegionSelector.swift       # Multi-display region selector (dim + crosshair + W×H label)
    ├── CaptureActionPicker.swift  # 📷 Capture / ✏️ Annotate / 🎥 Record / ✕ picker, ↵/E/R/ESC shortcuts
    ├── AnnotationDocument.swift   # Screenshot annotations: model, undo/redo, drawing, PNG export
    ├── ScreenshotEditor.swift     # Annotation canvas + toolbar shown over the captured region
    ├── ScreenRecorder.swift       # SCStream + AVAssetWriter pipeline (video + audio)
    ├── RecordingStopButton.swift  # Floating stop pill with elapsed counter
    ├── HistoryStore.swift         # SQLite CRUD + on-disk media cleanup
    ├── HistoryWindow.swift        # Dark panel: search, filter pills, inline previews + AVPlayer
    ├── HistoryHoverPreview.swift  # Hover-aware table + floating screenshot preview
    ├── Settings.swift             # UserDefaults, hotkey + model + language types
    ├── SettingsWindow.swift       # Settings UI
    └── SelfTest/                  # Self-test probes (only run under ZNOTE_SELFTEST)
```

## Testing

```bash
./selftest/run.sh              # build, then run logic + history + hotkeys + editor + voice (~1 min)
./selftest/run.sh translate    # selection translation against Google (needs network)
./selftest/bench.sh large-v3 large-v3-v20240930   # compare models: error rate + speed
```

Each scenario launches the real binary in a self-test mode with its own preferences domain and history database — no microphone, key presses, clipboard or user data involved. Voice cases use speech synthesized by `say`. Not covered: real mic capture, real key presses, screen capture itself, and pointer interaction with the UI.

## Troubleshooting

**"Failed to create event tap"** — Grant Input Monitoring permission and restart.

**Voice input produces no text** — Check the menu bar for orange permission warnings; ensure the model is downloaded in Settings.

**Voice → English outputs original-language text** — Your active model is Turbo. Turbo doesn't support `task=translate` — switch to Large V3 in Settings.

**Recording fails with "Couldn't start recording"** — First-time use needs Screen Recording permission; the alert links to the right settings page. After granting, relaunch the app.

**First launch is slow** — CoreML compiles the model for your hardware on first use. One-time; cached afterwards.

**"Loading model..." overlay during recording** — Model is still warming up; switches to the live waveform automatically once ready.

**Chinese output is traditional** — In Settings → Languages, pick "简体中文 (Simplified)" only (not both). Output auto-converts simplified.

## License

MIT
