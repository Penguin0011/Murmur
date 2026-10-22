#!/usr/bin/env python3
"""Per-dictation diagnostic digest from Murmur's local History, for the developer to read.

THIS TOOL PRINTS DICTATION TEXT (raw transcript, model output, final text, what you changed after
pasting) from ~/Library/Application Support/Dictation/history. Run it only on your own Mac and do not
paste its output into a shared place. Unlike dictation_health.py it is not content-free.

Usage: python3 -I app/tools/dictation_digest.py [-n 20] [--since 2h|1d|2026-10-22T09:00] [--json] [--self-check]
Entries made before October 22, 2026 lack the diagnostic fields and show them empty.
"""
import datetime
import json
import os
import re
import sys

HISTORY = os.path.expanduser("~/Library/Application Support/Dictation/history")
APPLE_EPOCH = 978307200  # Swift Date's reference date, in Unix seconds.


def load(directory=HISTORY):
    rows = []
    for name in os.listdir(directory) if os.path.isdir(directory) else []:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                entry = json.load(handle)
            entry["_unix"] = float(entry["recordedAt"]) + APPLE_EPOCH
            rows.append(entry)
        except (OSError, ValueError, KeyError, TypeError):
            continue  # unreadable files are the app's to quarantine
    return sorted(rows, key=lambda e: e["_unix"])


def parse_since(text, now):
    match = re.fullmatch(r"(\d+(?:\.\d+)?)([smhd])", text)
    if match:
        return now - float(match.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[match.group(2)]
    return datetime.datetime.fromisoformat(text).timestamp()


def num(value, spec=".2f", unit=""):
    return "-" if value is None else format(value, spec) + unit


def block(e):
    t, c, a, tm = e.get("transcription") or {}, e.get("cleanup") or {}, e.get("afterPaste") or {}, e.get("timing") or {}
    when = datetime.datetime.fromtimestamp(e["_unix"]).strftime("%Y-%m-%d %H:%M:%S")
    out = [f"=== {when}  {e['id'][:8]}  {num(e.get('seconds'), '.1f', 's')}  app={e.get('app') or '-'}  status={e.get('insertionStatus')}"]
    out.append(f"  route: stt={e.get('transcriptionProvider') or '-'}/{e.get('transcriptionModel') or '-'}  "
               f"cleanup={e.get('cleanupProvider') or '-'}/{e.get('cleanupModel') or '-'}  mode={e.get('writingModeName') or '-'}  v{e.get('appVersion') or '-'}")
    opts = e.get("cleanupOptions")
    out.append(f"  cleanup: path={e.get('cleanupOutcome') or '-'}  verdict={c.get('guardVerdict') or '-'}  reason={e.get('cleanupFallback') or '-'}  "
               f"prompt={c.get('promptHash') or '-'}  error={c.get('providerError') or '-'}  edited={e.get('edited', '-')}"
               + (f"  options={json.dumps(opts, sort_keys=True)}" if opts else ""))
    ctx = c.get("contextChars")
    out.append(f"  context: used={c.get('contextUsed', '-')}  app={c.get('contextApp') or '-'}  chars={json.dumps(ctx, sort_keys=True) if ctx else '-'}  "
               f"terms={', '.join(c['dictionaryTerms']) if c.get('dictionaryTerms') else '-'}")
    out.append(f"  clip: {num(t.get('clipSeconds'), '.1f', 's')}  peak p50={num(t.get('peakP50'), '.4f')} p90={num(t.get('peakP90'), '.4f')}  "
               f"silence peak={num(t.get('silencePeak'), '.4f')}/{num(t.get('silenceThreshold'), '.4f')}  precheck={t.get('precheck') or '-'}")
    out.append(f"  timing: stt={num(tm.get('transcription'), '.2f', 's')} cleanup={num(tm.get('cleanup'), '.2f', 's')} "
               f"insert={num(tm.get('insertion'), '.2f', 's')} total={num(tm.get('total'), '.2f', 's')}")
    out.append(f"  raw     : {e.get('rawText')!r}")
    if c.get("input"):
        out.append(f"  dict    : {c['input']!r}")
    if c.get("modelOutput") is not None:
        out.append(f"  model   : {c['modelOutput']!r}")
    if e.get("cleanupRejectedOutput"):
        out.append(f"  rejected: {e['cleanupRejectedOutput']!r}")
    out.append(f"  final   : {e.get('finalText')!r}")
    if a:
        seen = a.get("text")
        note = "lost" if seen is None else "CHANGED" if a.get("changed") else "unchanged"
        out.append(f"  pasted→ : {note} ({a.get('route') or '-'}, {a.get('endReason') or '-'})" + (f" {seen!r}" if a.get("changed") else ""))
    for i, s in enumerate(t.get("segments") or [], 1):
        out.append(f"  seg {i}: {num(s.get('start'), '.1f')}-{num(s.get('end'), '.1f')}s  logprob={num(s.get('avgLogprob'))} no_speech={num(s.get('noSpeechProb'), '.3f')} "
                   f"compr={num(s.get('compressionRatio'))} loud={s.get('loudWindows', '-')}{'  DROPPED' if s.get('dropped') else ''}  {s.get('text')!r}")
    if e.get("recordingFile"):
        out.append(f"  recording: history/recordings/{e['recordingFile']}")
    return "\n".join(out)


def select(rows, count, since):
    return [e for e in rows if e["_unix"] >= since] if since is not None else rows[-count:]


def self_check():
    now = 1_800_000_000
    rows = [{"id": f"{i:08d}-0000-0000-0000-000000000000", "recordedAt": now - APPLE_EPOCH - i * 100, "_unix": now - i * 100,
             "rawText": "hi", "finalText": "Hi.", "insertionStatus": "verified"} for i in range(5)]
    old = block(rows[0])
    assert "raw     : 'hi'" in old and "prompt=-" in old and "pasted" not in old, old
    rich = dict(rows[1], cleanup={"modelOutput": "Hi.", "guardVerdict": "cleaned", "promptHash": "0123abcd"}, afterPaste={"text": "Hi!", "changed": True, "route": "ax"},
                transcription={"segments": [{"start": 0, "end": 1, "avgLogprob": -0.3, "noSpeechProb": 0.1, "loudWindows": 4, "dropped": True, "text": " Thanks."}]}, timing={"total": 1.5})
    text = block(rich)
    assert "model   : 'Hi.'" in text and "CHANGED" in text and "DROPPED" in text and "total=1.50s" in text, text
    assert len(select(rows, 2, None)) == 2 and len(select(rows, 9, now - 250)) == 3
    assert parse_since("2h", now) == now - 7200
    print("dictation_digest self-check passed")


def main(argv):
    if "--self-check" in argv:
        return self_check()
    count, since, as_json = 20, None, "--json" in argv
    now = datetime.datetime.now().timestamp()
    for flag, value in zip(argv, argv[1:]):
        if flag == "-n":
            count = int(value)
        elif flag == "--since":
            since = parse_since(value, now)
    rows = select(load(), count, since)
    if as_json:
        print(json.dumps([{k: v for k, v in e.items() if k != "_unix"} for e in rows], indent=2, ensure_ascii=False))
    else:
        print("\n\n".join(block(e) for e in rows) if rows else "No dictations in History for that range.")


if __name__ == "__main__":
    main(sys.argv[1:])
