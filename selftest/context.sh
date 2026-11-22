#!/bin/bash
set -euo pipefail

# ── Znote: where-am-I diagnostic ────────────────────────────
#
# Asks the apps running on this Mac for their window title, document and page
# address, exactly as a selection note does, and prints which answered.
# The report records only the shape of each answer (scheme, length) — never a
# title or an address.
#
# Unlike the other scenarios this one needs Znote's real permissions
# (Accessibility, and Automation for each browser), so the app is started
# through LaunchServices instead of as a child of this shell. The first run
# against a browser makes macOS ask "Znote wants to control …" — answer it.
#
#   ./selftest/context.sh                              Test build/Znote.app
#   APP=/Applications/Znote.app ./selftest/context.sh  Test the installed copy
#
# The two below TAKE OVER THE KEYBOARD / THE SCREEN for a few seconds. Run them
# yourself, when you are not in the middle of typing. They are not for
# automated runs and agents must not run them on their own.
#   PANEL=1 ./selftest/context.sh   Show the note panel for ~3 s; it takes the keyboard and real keys are pressed in it
#   OPEN=1  ./selftest/context.sh   Go back to a page for real: opens one tab in Chrome and brings Chrome forward
#   ASK=1   ./selftest/context.sh   Also ask each browser over Apple Events (may prompt)
# ────────────────────────────────────────────────────────────

cd "$(dirname "$0")/.."
APP="${APP:-$PWD/build/Znote.app}"
DIR="$PWD/build/selftest/context"
TIMEOUT="${TIMEOUT:-90}"

[[ -d "$APP" ]] || { echo "no app at $APP — run ./sign.sh first" >&2; exit 2; }
rm -rf "$DIR"; mkdir -p "$DIR"

# -g: start it in the background — Znote is never the active app in real use.
open -g -n "$APP" --env ZNOTE_SELFTEST=context --env ZNOTE_SELFTEST_DIR="$DIR" \
    --env ZNOTE_CONTEXT_PANEL="${PANEL:-0}" --env ZNOTE_CONTEXT_OPEN="${OPEN:-0}" --env ZNOTE_CONTEXT_ASK="${ASK:-0}"

deadline=$((SECONDS + TIMEOUT))
while [[ ! -f "$DIR/report.json" ]]; do
    (( SECONDS > deadline )) && { echo "timed out after ${TIMEOUT}s — is a permission prompt waiting? (log: $DIR/app.log)" >&2; exit 2; }
    sleep 0.5
done
VERBOSE=1 python3 selftest/summarize.py "$DIR/report.json"
