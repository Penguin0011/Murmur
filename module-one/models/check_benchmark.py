"""Synthetic harness checks; these are not model accuracy results."""
import json
import pathlib
import subprocess
import sys
import tempfile
import wave
from benchmark import edits, words, run

assert edits(words('one two three'), words('one four')) == 2
assert edits([], words('hallucination')) == 1
assert words('Hello, WORLD!') == ['hello', 'world']
assert run([sys.executable, '-c', 'print(\'{"text":"hello"}\')', '{audio}'], 'unused')['text'] == 'hello'
try:
    run([sys.executable, '-c', 'raise SystemExit(7)', '{audio}'], 'unused')
except RuntimeError:
    pass
else:
    raise AssertionError('Failure must propagate')
try:
    run([sys.executable, '-c', 'import time; time.sleep(3)', '{audio}'], 'unused', timeout=0.05)
except TimeoutError:
    pass
else:
    raise AssertionError('Timeout must terminate runner')
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    with wave.open(str(root / 'sample.wav'), 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
        wav.writeframes(b'\0\0' * 16000)
    corpus = root / 'corpus.jsonl'
    corpus.write_text(json.dumps({'id': 'synthetic', 'audio': 'sample.wav', 'reference': 'hello'}) + '\n')
    output = subprocess.check_output([sys.executable, str(pathlib.Path(__file__).with_name('benchmark.py')),
        str(corpus), '--', sys.executable, '-c', 'print(\'{"text":"hello"}\')', '{audio}'], text=True)
    records = [json.loads(line) for line in output.splitlines()]
    assert records[-1]['micro_wer'] == 0
    assert records[1]['audio_seconds'] == 1
    assert records[1]['peak_child_rss_bytes'] > 0
print('Synthetic scoring/resource checks passed; no models evaluated.')
# The integrity gate must reject missing and tampered model bytes.
import hashlib
from verify_artifacts import verify
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    content = b'synthetic bytes'
    manifest = {'models': {'FluidInference/parakeet-unified-en-0.6b-coreml': {
        'batch_files': ['weight.bin'], 'files': [{'rfilename': 'weight.bin', 'size': len(content),
        'lfs': {'sha256': hashlib.sha256(content).hexdigest()}}]}}}
    for bad in (None, b'x' * len(content)):
        if bad is not None:
            (root / 'weight.bin').write_bytes(bad)
        try:
            verify(root, manifest)
        except ValueError:
            pass
        else:
            raise AssertionError('Missing/corrupted model must fail closed')
    (root / 'weight.bin').write_bytes(content)
    verify(root, manifest)
print('Synthetic artifact integrity checks passed.')
