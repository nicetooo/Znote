#!/bin/bash
set -uo pipefail

# ── Znote agent self-test ───────────────────────────────────
#
# One command: build → seed → run each scenario in the app's self-test mode →
# print a verdict. Each scenario is a separate launch of the real binary.
#
#   logic     settings, hotkey bindings, silence gate, hallucination filter, i18n
#   history   SQLite store against a seeded 3000-row old-schema database
#   hotkeys   tap / hold / double-tap state machine, fed synthetic key events
#   clipboard ⌘C / ⌘V clipboard borrowing and restoring, on a private pasteboard
#   editor    screenshot annotation tools + History hover preview, rendered off screen
#   voice     synthesized speech through the real Whisper pipeline
#   translate selection translation against Google (needs network; not in the default set)
#   bench     error rate + speed of MODEL on 48 reference clips (a measurement; see selftest/bench.sh)
#
# Nothing here uses the microphone, real key presses, the clipboard, or the
# user's history and saved settings: self-test mode keeps preferences in a
# throwaway defaults domain and its database in build/selftest/. The Whisper
# model cache is reused read-only.
#
# Usage:
#   ./selftest/run.sh                               Build build/Znote.app, run the default scenarios
#   ./selftest/run.sh logic hotkeys                 Run only these
#   ./selftest/run.sh translate                     The network one
#   SKIP_BUILD=1 ./selftest/run.sh                  Re-run without rebuilding
#   APP=/Applications/Znote.app ./selftest/run.sh   Test an installed copy (never builds)
#
# Env:
#   APP       .app bundle to test              (default build/Znote.app)
#   CONFIG    debug | release, for the build   (default debug)
#   MODEL     Whisper variant for `voice`      (default large-v3)
#   LANGS     recognition languages, `voice`   (default zh-Hans,en)
#   TIMEOUT   seconds to wait per scenario     (default 600)
#
# Exit: 0 all passed · 1 something failed · 2 environment problem
# ────────────────────────────────────────────────────────────

cd "$(dirname "$0")/.."

DEFAULT_APP="build/Znote.app"
APP="${APP:-$DEFAULT_APP}"
CONFIG="${CONFIG:-debug}"
export MODEL="${MODEL:-large-v3}"
export LANGS="${LANGS:-zh-Hans,en}"
TIMEOUT="${TIMEOUT:-600}"
SKIP_BUILD="${SKIP_BUILD:-0}"
if (( $# > 0 )); then SCENARIOS=("$@"); else SCENARIOS=(logic history hotkeys clipboard editor voice); fi

OUT="$PWD/build/selftest"
MODEL_DIR="$HOME/Library/Application Support/Znote/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-$MODEL"
REAL_DB="$HOME/Library/Application Support/Znote/history.sqlite"

info() { echo "▸ $*"; }
die()  { echo "✖ $*" >&2; exit 2; }

command -v python3 >/dev/null || die "python3 not found"
if [[ " ${SCENARIOS[*]} " == *" voice "* || " ${SCENARIOS[*]} " == *" bench "* ]]; then
    command -v say >/dev/null || die "\`say\` not found — the voice and bench scenarios need macOS"
    if [[ ! -d "$MODEL_DIR" && "${ALLOW_DOWNLOAD:-0}" != "1" ]]; then
        die "model '$MODEL' is not downloaded ($MODEL_DIR). Download it in Znote's Settings, or pass MODEL=<a cached one>."
    fi
fi

# ── Build (only for the default dev bundle) ─────────────────
mkdir -p build
if [[ "$APP" == "$DEFAULT_APP" && "$SKIP_BUILD" != "1" ]]; then
    info "Building + signing ($CONFIG)..."
    if ! ./sign.sh "$CONFIG" > build/selftest-build.log 2>&1; then
        grep -E "error:" build/selftest-build.log | head -30 >&2
        tail -15 build/selftest-build.log >&2
        die "build failed — full log: build/selftest-build.log"
    fi
fi
BIN="$APP/Contents/MacOS/Znote"
[[ -x "$BIN" ]] || die "no executable at $BIN"

# Fingerprint the user's real data so we can show it was left alone.
fingerprint() {
    { stat -f "%m %z" "$REAL_DB" 2>/dev/null; defaults read com.znote.app 2>/dev/null; } | shasum | cut -d' ' -f1
}
BEFORE="$(fingerprint)"

info "Testing $APP"
rm -rf "$OUT"
APP_PID=""
trap '[[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null' EXIT

RESULTS=()
OVERALL=0

# Every L("key") used in the sources must exist in both string tables.
if python3 selftest/check_strings.py; then
    RESULTS+=("strings: PASSED")
else
    RESULTS+=("strings: FAILED")
    OVERALL=1
fi
for scenario in "${SCENARIOS[@]}"; do
    dir="$OUT/$scenario"
    mkdir -p "$dir"
    python3 selftest/seed.py "$dir" "$scenario" || die "seed failed for $scenario"

    ZNOTE_SELFTEST="$scenario" ZNOTE_SELFTEST_DIR="$dir" "$BIN" > "$dir/stdout.log" 2>&1 &
    APP_PID=$!

    deadline=$((SECONDS + TIMEOUT))
    problem=""
    while [[ ! -f "$dir/report.json" ]]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then problem="app exited without writing a report"; break; fi
        if (( SECONDS > deadline )); then problem="timed out after ${TIMEOUT}s"; kill "$APP_PID" 2>/dev/null; break; fi
        sleep 0.5
    done
    wait "$APP_PID" 2>/dev/null
    APP_PID=""

    if [[ -n "$problem" ]]; then
        echo; echo "━━ $scenario ━━"
        tail -15 "$dir/app.log" 2>/dev/null | sed 's/^/  /'
        tail -5 "$dir/stdout.log" 2>/dev/null | sed 's/^/  /'
        echo "  → ERROR: $problem (logs: $dir)"
        RESULTS+=("$scenario: ERROR — $problem")
        OVERALL=1
        continue
    fi

    summary="$(python3 selftest/summarize.py "$dir/report.json")" || OVERALL=1
    echo "$summary" | grep -v '^VERDICT '
    RESULTS+=("$scenario: $(echo "$summary" | sed -n 's/^VERDICT //p')")

    if [[ "$scenario" == "voice" ]]; then
        echo "  filter / retry activity in $dir/app.log:"
        grep -E "stripped trailing hallucination|filtered pure hallucination|dropping segment|language mismatch|converted " "$dir/app.log" \
            | sed 's/^/    /' || echo "    (none)"
    fi
done
trap - EXIT

# ── Summary ─────────────────────────────────────────────────
defaults delete com.znote.app.selftest >/dev/null 2>&1   # belt and braces; the app clears it too
echo
echo "════════════════════════════════════════"
for line in "${RESULTS[@]}"; do echo "  $line"; done
if [[ "$(fingerprint)" == "$BEFORE" ]]; then
    echo "  user data: real history.sqlite and saved settings unchanged"
else
    echo "  user data: real history.sqlite or saved settings CHANGED during the run"
    echo "             (expected only if you were using Znote meanwhile)"
fi
echo "  reports:   $OUT/<scenario>/report.json"
echo "════════════════════════════════════════"
exit $OVERALL
