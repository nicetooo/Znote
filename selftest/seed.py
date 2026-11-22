#!/usr/bin/env python3
"""Generate deterministic seed data for one Znote self-test scenario.

  voice    Speech WAVs from macOS `say` (16-bit / 48 kHz mono, the format
           AudioRecorder produces) + manifest.json. Some get a tail of
           low-level noise, imitating the pause before the push-to-talk key
           is released — where Whisper tends to hallucinate "Thank you.".
  bench    Reference sentences (Chinese / English / mixed), each as a clean
           clip and one with white noise mixed in, for measuring a model.
  history  history.sqlite in the OLD schema (no image_path column) with a few
           thousand rows + manifest.json describing what the probe should find.
  others   Nothing to seed.

Usage: seed.py <out_dir> <scenario>
Env:   MODEL (default large-v3), LANGS (default "zh-Hans,en") — voice and bench
       ALLOW_DOWNLOAD=1 — bench only: let the app download MODEL if missing
"""

import json
import os
import random
import re
import sqlite3
import subprocess
import sys
import wave
from pathlib import Path

# ── voice ────────────────────────────────────────────────────

RATE = 48_000
NOISE_SEED = 20261121
NOISE_AMPLITUDE = 24  # of 32768 — roughly a quiet room

# Phrases Whisper is known to append on silence; a result must never end in one
# when the speaker did not say it.
HALLUCINATED_ENDINGS = ["thank you", "thanks for watching", "you", "bye"]

EN_YOU = "I will send the file to you."
ZH_DISCUSS = "我们今天就先讨论到这里。"

# fmt: off
VOICE_CASES = [
    # English sentences that END in a blacklisted phrase — these were truncated.
    dict(id="en-ends-you",        lang="en", text=EN_YOU,                               ends="to you"),
    dict(id="en-ends-thank-you",  lang="en", text="I just wanted to say thank you.",     ends="say thank you"),
    dict(id="en-ends-music",      lang="en", text="Let me play some music.",             ends="some music"),
    dict(id="en-ends-the-end",    lang="en", text="Please read it to the end.",          ends="to the end"),
    # Same, with a pause before key release.
    dict(id="en-ends-you-pause",  lang="en", text=EN_YOU,                               ends="to you", tail=4.0),
    # Right ⌥ hold (Whisper task=translate): output is always English.
    dict(id="en-translate-you",   lang="en", text=EN_YOU,                               ends="to you", translate=True),
    dict(id="zh-translate",       lang="zh", text="我明天把这份报告发给你。",             translate=True),
    # Chinese: must come through intact, and must not gain an English tail.
    dict(id="zh-plain",           lang="zh", text="今天下午我们开会，会后我把文件发给你。", contains=["开会"], ends="发给你", not_ends=HALLUCINATED_ENDINGS),
    dict(id="zh-pause",           lang="zh", text=ZH_DISCUSS,                           contains=["讨论到这里"], not_ends=HALLUCINATED_ENDINGS, tail=4.0),
    # The hallucination itself, spoken aloud so it reliably reaches the filter:
    # a Chinese sentence followed by a stand-alone "Thank you." must lose it.
    dict(id="zh-then-thank-you",  lang="zh", text=ZH_DISCUSS + "Thank you.",            contains=["讨论到这里"], not_ends=HALLUCINATED_ENDINGS),

    # ── Other language settings (per-case override of the recognition languages) ──
    # Only Traditional selected → forced zh, output converted to Traditional.
    dict(id="only-traditional",   lang="zh", text=ZH_DISCUSS, languages=["zh-Hant"],             contains=["討論"], not_contains=["讨论"]),
    # Only Simplified selected → forced zh, output converted to Simplified.
    dict(id="only-simplified",    lang="zh", text=ZH_DISCUSS, languages=["zh-Hans"],             contains=["讨论"], not_contains=["討論"]),
    # Both scripts selected → forced zh, no conversion; just must be Chinese.
    dict(id="both-scripts",       lang="zh", text=ZH_DISCUSS, languages=["zh-Hans", "zh-Hant"],  contains=["今天"]),
    # Only English selected → forced en.
    dict(id="only-english",       lang="en", text=EN_YOU,     languages=["en"],                  ends="to you"),
    # English speech while only Chinese + Japanese are selected: auto-detect
    # yields English, the language check must notice and retry exactly once.
    dict(id="unexpected-language-retries", lang="en", text=EN_YOU, languages=["zh-Hans", "ja"],   retry=True, any_text=True),

    # ── Live dictation: long enough for several previews while "recording" ──
    dict(id="live-en",            lang="en", live=True, contains=["second section", "client"],
         text="I spent the morning reading the report, and I think the second section needs more data before we send it to the client."),
    dict(id="live-zh-mixed",      lang="zh", live=True, contains=["开会", "release"],
         text="今天下午我们开会讨论新版本的发布计划，会后我把 release notes 发到群里，大家有问题可以直接回复。"),
    # Speech, then four seconds of room noise before the key is released:
    # previews made during the pause must not grow a made-up ending.
    dict(id="live-en-pause",      lang="en", live=True, text=EN_YOU, ends="to you", tail=4.0),
]
# fmt: on

VOICE_PREFERENCE = {
    "en": ("en_US", ["Samantha", "Alex", "Reed", "Flo", "Eddy"]),
    "zh": ("zh_CN", ["Tingting", "Meijia", "Flo", "Eddy"]),
}


def pick_voices() -> dict:
    listing = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    by_locale = {}
    for line in listing.splitlines():
        m = re.match(r"^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#", line)
        if m:
            by_locale.setdefault(m.group(2), []).append(m.group(1).strip())
    chosen = {}
    for lang, (locale, preferred) in VOICE_PREFERENCE.items():
        available = by_locale.get(locale, [])
        match = next((v for p in preferred for v in available if v == p or v.startswith(p + " ")), None)
        if match is None:
            sys.exit(f"seed: no usable `say` voice for {locale} (looked for {preferred})")
        chosen[lang] = match
    return chosen


def append_noise(path: Path, seconds: float) -> None:
    with wave.open(str(path), "rb") as r:
        params, frames = r.getparams(), r.readframes(r.getnframes())
    if (params.nchannels, params.sampwidth, params.framerate) != (1, 2, RATE):
        sys.exit(f"seed: unexpected WAV format from say: {params}")
    rng = random.Random(NOISE_SEED)
    noise = b"".join(
        rng.randint(-NOISE_AMPLITUDE, NOISE_AMPLITUDE).to_bytes(2, "little", signed=True)
        for _ in range(int(seconds * RATE))
    )
    with wave.open(str(path), "wb") as w:
        w.setparams(params)
        w.writeframes(frames + noise)


def seed_voice(out: Path) -> str:
    audio_dir = out / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    voices = pick_voices()

    cases = []
    for case in VOICE_CASES:
        wav = audio_dir / f"{case['id']}.wav"
        subprocess.run(
            ["say", "-v", voices[case["lang"]], "-o", str(wav),
             "--file-format=WAVE", f"--data-format=LEI16@{RATE}", case["text"]],
            check=True,
        )
        if case.get("tail"):
            append_noise(wav, case["tail"])
        with wave.open(str(wav), "rb") as r:
            seconds = r.getnframes() / r.getframerate()
        cases.append({
            "id": case["id"],
            "audio": str(wav),
            "spoken": case["text"],
            "translate": case.get("translate", False),
            "languages": case.get("languages"),
            "expectEndsWith": case.get("ends"),
            "expectContains": case.get("contains", []),
            "mustNotContain": case.get("not_contains", []),
            "mustNotEndWith": case.get("not_ends", []),
            "expectRetry": case.get("retry", False),
            "anyText": case.get("any_text", False),
            "live": case.get("live", False),
            "audioSeconds": round(seconds, 2),
        })

    manifest = {
        "model": os.environ.get("MODEL", "large-v3"),
        "languages": [s for s in os.environ.get("LANGS", "zh-Hans,en").split(",") if s],
        "voices": voices,
        "cases": cases,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return f"{len(cases)} speech cases (voices: {voices['en']} / {voices['zh']})"


# ── bench ────────────────────────────────────────────────────

# Reference sentences for measuring a model. No digits or dates: "三点" vs "3点"
# is a spelling choice, not a recognition error.
# fmt: off
BENCH_SENTENCES = {
    "zh": [
        "今天下午我们开会讨论下个季度的产品规划。",
        "请把昨天的会议纪要整理好发到群里。",
        "这个问题我需要再确认一下，稍后回复你。",
        "天气预报说明天有雨，记得带伞。",
        "我觉得这个方案的成本太高了，需要重新评估。",
        "麻烦帮我订一张下周去上海的高铁票。",
        "他昨天晚上加班到很晚，今天请假休息。",
        "我们先把最重要的功能做完，其他的以后再说。",
    ],
    "en": [
        "Please send me the updated report before the end of the day.",
        "I think we should postpone the launch until the tests are stable.",
        "The quarterly numbers look better than we expected.",
        "Can you review my pull request when you have a minute?",
        "Let's schedule a call with the design team tomorrow morning.",
        "The server went down last night and we are still investigating.",
        "I will be out of the office on Friday afternoon.",
        "This feature needs more documentation before we ship it.",
    ],
    # Chinese sentences carrying English terms, read by the Chinese voice.
    "mixed": [
        "这个 API 的 response 格式不对。",
        "我们用 React 和 TypeScript 写前端。",
        "请帮我 review 一下这个 pull request。",
        "明天的 meeting 改到下午了。",
        "这个 bug 已经修复了，可以重新 deploy。",
        "把 log level 调成 debug 再跑一次。",
        "老板说这个 feature 下周要上线。",
        "服务器的 CPU 占用太高了，需要优化。",
    ],
}
# fmt: on
BENCH_SNR_DB = 10


def mix_noise(src: Path, dst: Path, snr_db: float, seed: int) -> None:
    """Copy `src` to `dst` with white noise added at the given signal-to-noise ratio."""
    import array
    import math
    with wave.open(str(src), "rb") as r:
        params = r.getparams()
        samples = array.array("h", r.readframes(r.getnframes()))
    rms = math.sqrt(sum(s * s for s in samples) / max(1, len(samples)))
    # Uniform noise in [-a, a] has RMS a/sqrt(3).
    amplitude = rms / (10 ** (snr_db / 20)) * math.sqrt(3)
    rng = random.Random(seed)
    noisy = array.array("h", (
        max(-32768, min(32767, int(s + rng.uniform(-amplitude, amplitude)))) for s in samples
    ))
    with wave.open(str(dst), "wb") as w:
        w.setparams(params)
        w.writeframes(noisy.tobytes())


def seed_bench(out: Path) -> str:
    audio_dir = out / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    voices = pick_voices()

    clips = []
    for group, sentences in BENCH_SENTENCES.items():
        voice = voices["en" if group == "en" else "zh"]
        for n, sentence in enumerate(sentences, 1):
            clean = audio_dir / f"{group}-{n:02d}-clean.wav"
            subprocess.run(
                ["say", "-v", voice, "-o", str(clean),
                 "--file-format=WAVE", f"--data-format=LEI16@{RATE}", sentence],
                check=True,
            )
            noisy = audio_dir / f"{group}-{n:02d}-noisy.wav"
            mix_noise(clean, noisy, BENCH_SNR_DB, NOISE_SEED + len(clips))
            for condition, path in (("clean", clean), ("noisy", noisy)):
                with wave.open(str(path), "rb") as r:
                    seconds = r.getnframes() / r.getframerate()
                clips.append({
                    "id": path.stem, "audio": str(path), "reference": sentence,
                    "group": group, "condition": condition, "audioSeconds": round(seconds, 2),
                })

    manifest = {
        "model": os.environ.get("MODEL", "large-v3"),
        "languages": [s for s in os.environ.get("LANGS", "zh-Hans,en").split(",") if s],
        "allowDownload": os.environ.get("ALLOW_DOWNLOAD") == "1",
        "voices": voices,
        "snrDb": BENCH_SNR_DB,
        "clips": clips,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return f"{len(clips)} clips ({len(clips) // 2} sentences × clean / {BENCH_SNR_DB} dB SNR)"


# ── history ──────────────────────────────────────────────────

# The table as Znote created it before screenshots existed. The app must add
# image_path itself when it opens this file.
OLD_HISTORY_SCHEMA = """
CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL,
    input_text TEXT,
    output_text TEXT NOT NULL,
    source_lang TEXT,
    target_lang TEXT,
    timestamp REAL NOT NULL,
    duration REAL
);
CREATE INDEX idx_history_timestamp ON history(timestamp);
"""

HISTORY_VOICE_ROWS = 2000
HISTORY_TRANSLATION_ROWS = 1000
NEEDLE_OUTPUT = "needle-alpha"   # appears in voice output_text
NEEDLE_INPUT = "needle-beta"     # appears ONLY in translation input_text
BASE_TIME = 1_760_000_000        # Oct 2025 — older than anything the probe adds


def seed_history(out: Path) -> str:
    db_path = out / "history.sqlite"
    db_path.unlink(missing_ok=True)
    rng = random.Random(20261121)
    rows = []
    for i in range(HISTORY_VOICE_ROWS):
        text = f"voice note #{i:05d} 会议记录 meeting notes"
        if i % 100 == 0:
            text += f" {NEEDLE_OUTPUT}"
        if i % 400 == 7:
            text += " progress 100% done"
        if i % 500 == 9:
            text += " file_name.txt"
        if i % 500 == 11:
            text += " file name.txt"    # would match "file_name" if _ were a wildcard
        rows.append(("voice", None, text, None, None, round(rng.uniform(0.6, 40.0), 1)))
    for i in range(HISTORY_TRANSLATION_ROWS):
        source = f"source sentence #{i:05d}"
        if i % 150 == 3:
            source += f" {NEEDLE_INPUT}"
        rows.append(("translation", source, f"译文 #{i:05d}", "en", "zh-CN", None))
    # Interleave types the way real use would, one row a minute.
    rng.shuffle(rows)

    db = sqlite3.connect(db_path)
    db.executescript(OLD_HISTORY_SCHEMA)
    db.executemany(
        "INSERT INTO history (type, input_text, output_text, source_lang, target_lang, timestamp, duration)"
        " VALUES (?, ?, ?, ?, ?, ?, ?)",
        [(t, i, o, s, g, BASE_TIME + n * 60, d) for n, (t, i, o, s, g, d) in enumerate(rows)],
    )
    db.commit()
    db.close()

    manifest = {
        "total": len(rows),
        "voice": HISTORY_VOICE_ROWS,
        "translation": HISTORY_TRANSLATION_ROWS,
        "needleOutput": NEEDLE_OUTPUT,
        "needleOutputRows": sum(1 for r in rows if NEEDLE_OUTPUT in r[2]),
        "needleInput": NEEDLE_INPUT,
        "needleInputRows": sum(1 for r in rows if r[1] and NEEDLE_INPUT in r[1]),
        "newestText": rows[-1][2],
        "percentRows": sum(1 for r in rows if "100%" in r[2]),
        "underscoreRows": sum(1 for r in rows if "file_name" in r[2]),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return f"{len(rows)} history rows in the old schema"


# ── main ─────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    out, scenario = Path(sys.argv[1]).resolve(), sys.argv[2]
    out.mkdir(parents=True, exist_ok=True)
    seeders = {"voice": seed_voice, "history": seed_history, "bench": seed_bench}
    summary = seeders[scenario](out) if scenario in seeders else "nothing to seed"
    print(f"seed[{scenario}]: {summary}")


if __name__ == "__main__":
    main()
