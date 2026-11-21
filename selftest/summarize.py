#!/usr/bin/env python3
"""Print a readable verdict for a Znote self-test report. Exit 0 if it passed."""

import json
import os
import sys

NAME_WIDTH = 50
MAX_DETAIL = 160
VERBOSE = os.environ.get("VERBOSE") == "1"


def describe(step: dict) -> str:
    detail = step.get("detail") or {}
    if "spoken" in detail:  # voice case
        line = f"[{detail.get('mode', '')}] \"{detail['spoken']}\" → \"{detail.get('text', '')}\""
        extras = [f"{k}={detail[k]}" for k in ("languages", "retries") if k in detail]
        return line + (f"   ({', '.join(extras)})" if extras else "")
    if "target" in detail:  # translate case
        return f"{detail.get('detected', '?')} → {detail['target']}: \"{detail.get('text', '')}\""
    return ", ".join(f"{k}={v}" for k, v in detail.items() if v != "" and k != "failed")


def bench_stats(report: dict) -> dict:
    """Mean character error rate and time per clip, overall and per group/condition."""
    clips = [s for s in report["steps"] if "cer" in (s.get("detail") or {})]
    def mean(xs):
        xs = list(xs)
        return sum(xs) / len(xs) if xs else float("nan")
    stats = {"clips": len(clips),
             "cer": mean(float(c["detail"]["cer"]) for c in clips),
             "ms": mean(c["ms"] for c in clips),
             "exact": sum(1 for c in clips if float(c["detail"]["cer"]) == 0),
             "retried": sum(1 for c in clips if int(c["detail"].get("retries", 0)) > 0),
             "retried_by_group": {g: sum(1 for c in clips if c["detail"]["group"] == g and int(c["detail"].get("retries", 0)) > 0)
                                  for g in sorted({c["detail"]["group"] for c in clips})}}
    for key in ("group", "condition"):
        for value in sorted({c["detail"][key] for c in clips}):
            stats[value] = mean(float(c["detail"]["cer"]) for c in clips if c["detail"][key] == value)
    return stats


def print_bench(report: dict) -> None:
    env, st = report.get("env", {}), bench_stats(report)
    print(f"\n━━ bench ━━  model: {env.get('model')}   on disk: {env.get('modelSize', '?')}   "
          f"load: {env.get('loadMs', '?')} ms")
    if not st["clips"]:
        return
    print(f"  character error rate: {st['cer'] * 100:.2f}%   "
          f"({st['exact']}/{st['clips']} clips exact)   mean {st['ms']:.0f} ms/clip")
    print("  by group:     " + "   ".join(f"{g} {st[g] * 100:.2f}%" for g in ("zh", "en", "mixed") if g in st))
    print("  by condition: " + "   ".join(f"{c} {st[c] * 100:.2f}%" for c in ("clean", "noisy") if c in st))
    print(f"  language-check retries: {st['retried']}/{st['clips']} clips  " +
          "  ".join(f"{g} {n}" for g, n in st["retried_by_group"].items()))
    wrong = [s for s in report["steps"] if float((s.get("detail") or {}).get("cer", 0)) > 0]
    for s in sorted(wrong, key=lambda s: -float(s["detail"]["cer"]))[:12 if not VERBOSE else None]:
        d = s["detail"]
        print(f"    {float(d['cer']) * 100:5.1f}%  {s['name']:<16} \"{d['reference']}\"\n"
              f"            {'':<16} \"{d['text']}\"")


def main() -> int:
    with open(sys.argv[1], encoding="utf-8") as f:
        report = json.load(f)

    if report["scenario"] == "bench":
        print_bench(report)
        for err in report["errors"]:
            print(f"  error: {err}")
        verdict = "MEASURED" if report["passed"] else "FAILED"
        print(f"  → {verdict}")
        print(f"VERDICT {verdict}")
        return 0 if report["passed"] else 1

    env = report.get("env", {})
    steps = report["steps"]
    known = [s for s in steps if not s["ok"] and s.get("known")]
    failed = [s for s in steps if not s["ok"] and not s.get("known")]

    print(f"\n━━ {report['scenario']} ━━  {report['elapsedMs']} ms   " +
          "   ".join(f"{k}: {v}" for k, v in sorted(env.items()) if k != "binary"))

    hidden = 0
    for step in steps:
        detail = step.get("detail") or {}
        # Plain passing checks are collapsed into a count unless VERBOSE=1;
        # anything that failed, took time, or carries a transcript is shown.
        if step["ok"] and not VERBOSE and not step["ms"] and "spoken" not in detail and "target" not in detail:
            hidden += 1
            continue
        mark = "yes" if step["ok"] else ("KNOWN" if step.get("known") else "NO")
        ms = step["ms"] if step["ms"] else ""
        text = describe(step)
        if len(text) > MAX_DETAIL:
            text = text[:MAX_DETAIL] + "…"
        print(f"  {mark:<5} {step['name'][:NAME_WIDTH]:<{NAME_WIDTH}} {ms:>6}  {text}")
        if detail.get("failed"):
            print(f"        ✗ {detail['failed']}")
    if hidden:
        print(f"  yes   … and {hidden} more passing checks (VERBOSE=1 to list)")

    for err in report["errors"]:
        print(f"  error: {err}")

    verdict = ("PASSED, with known issues" if known else "PASSED") if report["passed"] else "FAILED"
    counts = f"{len(steps) - len(known) - len(failed)}/{len(steps)} ok"
    if known:
        counts += f", {len(known)} known issue(s): " + ", ".join(sorted({s['known'] for s in known}))
    if failed:
        counts += f", {len(failed)} FAILED"
    print(f"  → {verdict}  ({counts})")
    print(f"VERDICT {verdict}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
