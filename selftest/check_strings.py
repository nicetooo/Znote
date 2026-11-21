#!/usr/bin/env python3
"""Check that every L("key") in the Swift sources exists in both string tables.

Only literal keys are checked; a key built at run time (L("editor.tool.\\(x)"))
is checked by prefix — at least one key with that prefix must exist.
Exit 0 if nothing is missing.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLES = {lang: ROOT / f"Sources/Znote/Resources/{lang}.lproj/Localizable.strings" for lang in ("en", "zh-Hans")}


def keys_in(table: Path) -> set:
    return set(re.findall(r'^"((?:[^"\\]|\\.)+)"\s*=', table.read_text(encoding="utf-8"), flags=re.M))


def main() -> int:
    literal, prefixes = {}, {}
    for path in sorted((ROOT / "Sources/Znote").rglob("*.swift")):
        if path.name == "Localization.swift":
            continue   # its doc comment uses made-up keys as examples
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for key in re.findall(r'\bL\("((?:[^"\\]|\\.)*)"', line):
                where = f"{path.relative_to(ROOT)}:{n}"
                if "\\(" in key:
                    prefixes.setdefault(key.split("\\(")[0], where)
                else:
                    literal.setdefault(key, where)

    problems = []
    for lang, table in TABLES.items():
        have = keys_in(table)
        for key, where in sorted(literal.items()):
            if key not in have:
                problems.append(f"{lang}: missing \"{key}\"  (used at {where})")
        for prefix, where in sorted(prefixes.items()):
            if not any(k.startswith(prefix) for k in have):
                problems.append(f"{lang}: no key starts with \"{prefix}\"  (built at {where})")

    for p in problems:
        print("  " + p)
    print(f"strings: {len(literal)} literal keys + {len(prefixes)} run-time prefixes used in code, "
          f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
