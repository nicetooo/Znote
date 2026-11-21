#!/bin/bash
set -uo pipefail

# ── Compare Whisper models on the same reference clips ──────
#
# Runs the `bench` self-test scenario once per model and prints one table:
# character error rate (overall, per language group, clean vs noisy), time per
# clip, load time, size on disk. Models must be in Settings.popularModels.
#
# Usage:
#   ./selftest/bench.sh large-v3 large-v3_947MB
#   ALLOW_DOWNLOAD=1 ./selftest/bench.sh large-v3-v20240930_626MB   # fetch it first if missing
#   APP=/Applications/Znote.app ./selftest/bench.sh large-v3
#
# The first run of a freshly downloaded model includes CoreML's one-time
# specialization, so its load time is not representative — run it twice.
# ────────────────────────────────────────────────────────────

cd "$(dirname "$0")/.."
(( $# > 0 )) || { sed -n '4,17p' "$0"; exit 2; }

OUT="build/selftest-bench"
mkdir -p "$OUT"
BUILD_DONE="${SKIP_BUILD:-0}"

for model in "$@"; do
    echo "▸ bench: $model"
    MODEL="$model" SKIP_BUILD="$BUILD_DONE" ./selftest/run.sh bench > "$OUT/$model.log" 2>&1
    status=$?
    BUILD_DONE=1   # build once, reuse for the remaining models
    if [[ -f build/selftest/bench/report.json ]]; then
        cp build/selftest/bench/report.json "$OUT/$model.json"
    fi
    (( status == 0 )) || { echo "  ✖ failed — see $OUT/$model.log"; tail -5 "$OUT/$model.log" | sed 's/^/    /'; }
done

python3 - "$OUT" "$@" <<'PY'
import json, os, sys
sys.path.insert(0, "selftest")
from summarize import bench_stats

out, models = sys.argv[1], sys.argv[2:]
rows = []
for m in models:
    path = os.path.join(out, m + ".json")
    if not os.path.exists(path):
        continue
    report = json.load(open(path, encoding="utf-8"))
    st, env = bench_stats(report), report.get("env", {})
    if st["clips"]:
        rows.append((m, env, st))

print()
print(f"{'model':<28} {'disk':>8} {'load':>7} {'ms/clip':>8} {'CER':>7} {'zh':>7} {'en':>7} {'mixed':>7} {'clean':>7} {'noisy':>7} {'exact':>7} {'retried':>8}")
for m, env, st in rows:
    pct = lambda k: f"{st[k] * 100:.2f}%"
    print(f"{m:<28} {env.get('modelSize', '?'):>8} {int(env.get('loadMs', 0)) / 1000:>6.1f}s {st['ms']:>8.0f} "
          f"{pct('cer'):>7} {pct('zh'):>7} {pct('en'):>7} {pct('mixed'):>7} {pct('clean'):>7} {pct('noisy'):>7} "
          f"{st['exact']:>4}/{st['clips']} {st['retried']:>5}/{st['clips']}")
print(f"\nreports: {out}/<model>.json   (CER = character error rate, lower is better)")
PY
