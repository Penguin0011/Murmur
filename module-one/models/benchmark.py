#!/usr/bin/env python3
"""Run an explicit command per labeled audio; JSON stdout must contain text.
Corpus JSONL: {"id":"…", "audio":"path.wav", "reference":"…"}.
No audio/network/model downloads. resource.wait4 measures this child only.
"""
import argparse
import json
import os
import platform
import re
import subprocess
import tempfile
import time
import threading
import wave


def words(text):
    return re.findall(r"\w+(?:['’]\w+)?", text.casefold())


def edits(reference, hypothesis):
    row = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        nxt = [i]
        for j, actual in enumerate(hypothesis, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j - 1] + (expected != actual)))
        row = nxt
    return row[-1]


def run(command, audio, timeout=300):
    argv = [part.replace('{audio}', audio) for part in command]
    started = time.monotonic()
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        child = subprocess.Popen(argv, stdout=out, stderr=err)
        expired = threading.Event()
        def stop():
            expired.set()
            try:
                child.kill()
            except ProcessLookupError:
                pass
        timer = threading.Timer(timeout, stop)
        timer.start()
        try:
            _, status, usage = os.wait4(child.pid, 0)
        finally:
            timer.cancel()
        child.returncode = os.waitstatus_to_exitcode(status)
        elapsed = time.monotonic() - started
        out.seek(0); err.seek(0)
        stdout, stderr = out.read().decode(), err.read().decode()
    if expired.is_set():
        raise TimeoutError(f'Runner exceeded {timeout} seconds')
    if child.returncode:
        raise RuntimeError(f'Command failed ({child.returncode}): {stderr[-2000:]}')
    result = json.loads(stdout.strip().splitlines()[-1])
    if not isinstance(result.get('text'), str):
        raise ValueError('Runner must return a JSON object with string text')
    result.update(wall_seconds=elapsed, cpu_seconds=usage.ru_utime + usage.ru_stime,
                  peak_child_rss_bytes=usage.ru_maxrss * (1 if platform.system() == 'Darwin' else 1024))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, default=300, help='Seconds per utterance (default: 300)')
    parser.add_argument('corpus')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('Timeout must be positive')
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not any('{audio}' in x for x in command):
        parser.error('Provide a command with an {audio} argument')
    records = [json.loads(line) for line in open(args.corpus) if line.strip()]
    if not records or len({r['id'] for r in records}) != len(records):
        raise ValueError('Corpus must have unique IDs and at least one record')
    total_words = total_edits = 0
    print(json.dumps({'type': 'environment', 'platform': platform.platform(),
                      'machine': platform.machine(), 'command': command}))
    for record in records:
        path = os.path.join(os.path.dirname(os.path.abspath(args.corpus)), record['audio'])
        with wave.open(path) as audio:
            duration = audio.getnframes() / audio.getframerate()
        result = run(command, path, args.timeout)
        ref, hyp = words(record['reference']), words(result['text'])
        count = edits(ref, hyp)
        total_words += len(ref); total_edits += count
        result.update(type='utterance', id=record['id'], reference=record['reference'],
                      audio_seconds=duration, word_edits=count, reference_words=len(ref),
                      wer=count / len(ref) if ref else None,
                      silence_output_words=len(hyp) if not ref else None)
        print(json.dumps(result))
    print(json.dumps({'type': 'summary', 'word_edits': total_edits,
                      'reference_words': total_words,
                      'micro_wer': total_edits / total_words if total_words else None}))


if __name__ == '__main__':
    main()
