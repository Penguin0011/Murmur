#!/usr/bin/env python3
"""Local capture processor: verify models, transcribe, durably save, then remove retry audio."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RUNNER = ROOT / 'module-one/models/Runner/.build/release/ModelBench'
DEFAULT_HISTORY = Path.home() / 'Library/Application Support/DictationCaptureSpike/history'


def private_directory(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('History path must be a real directory')
    directory.chmod(0o700)


def save_transcript(directory, text, recorded_at, metrics):
    """Keep raw/final identical until cleanup is implemented; never attempt insertion."""
    private_directory(directory)
    session = str(uuid.uuid4())
    record = {'id': session, 'recorded_at': recorded_at, 'saved_at': time.time(),
              'raw_text': text, 'final_text': text, 'route': 'local/unified',
              'insertion_status': 'saved-not-inserted', 'metrics': metrics}
    fd, temporary = tempfile.mkstemp(prefix='.pending-', dir=directory)
    target = directory / (session + '.json')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return target


def purge_history(directory, now=None):
    """This standalone checkpoint uses only the approved default thirty-day policy."""
    private_directory(directory)
    cutoff = (time.time() if now is None else now) - 30 * 24 * 60 * 60
    for path in directory.glob('*.json'):
        if path.is_symlink():
            continue
        try:
            recorded_at = json.loads(path.read_text())['recorded_at']
            if isinstance(recorded_at, (float, int)) and recorded_at <= cutoff:
                path.unlink()
        except (OSError, ValueError, KeyError, TypeError):
            # Malformed recovery is retained rather than deleted on a parsing guess.
            continue


def verify_models(directory):
    verifier_path = ROOT / 'module-one/models/verify_artifacts.py'
    spec = importlib.util.spec_from_file_location('dictation_model_verifier', verifier_path)
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    manifest = json.loads((verifier_path.parent / 'artifact-pins.json').read_text())
    verifier.verify(directory, manifest)


def run_transcription(runner, models, audio, timeout):
    # A private file avoids logging speech or accumulating arbitrary runner output in RAM.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        child = subprocess.Popen([str(runner), str(models), str(audio), '--single'],
                                 stdout=output, stderr=errors, start_new_session=True)
        def stop(_signum, _frame):
            raise InterruptedError('Processing canceled')
        previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            child.wait(timeout=timeout)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        if child.returncode != 0:
            raise RuntimeError('Local model runner failed; retry audio retained')
        output.seek(0)
        # Runtime diagnostics can precede JSON. Read only the final record.
        last = None
        for line in output:
            if line.strip():
                last = line
        if last is None:
            raise ValueError('Runner produced no result')
        result = json.loads(last)
        text = result.get('text')
        if not isinstance(text, str) or not text.strip():
            raise ValueError('Runner produced no usable text; retry audio retained')
        metrics = {key: value for key, value in result.items()
                   if key.endswith('_seconds') and isinstance(value, (int, float))}
        return text, metrics


def process(models, audio, runner, history, timeout=300):
    if audio.is_symlink() or not audio.is_file():
        raise ValueError('Audio must be a regular local file')
    stat = audio.stat()
    recorded_at = getattr(stat, 'st_birthtime', stat.st_mtime)
    if time.time() - recorded_at >= 24 * 60 * 60 or recorded_at > time.time():
        raise ValueError('Retry audio is outside the twenty-four-hour recovery window')
    verify_models(models)
    purge_history(history)
    text, metrics = run_transcription(runner, models, audio, timeout)
    saved = save_transcript(history, text, recorded_at, metrics)
    # No audio deletion before durable text exists. Failure here leaves redundant recovery.
    audio.unlink()
    return saved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('models', type=Path)
    parser.add_argument('audio', type=Path)
    parser.add_argument('--runner', type=Path, default=DEFAULT_RUNNER)
    parser.add_argument('--history', type=Path, default=DEFAULT_HISTORY)
    parser.add_argument('--timeout', type=float, default=300)
    args = parser.parse_args()
    if not 0 < args.timeout <= 600:
        parser.error('Timeout must be greater than zero and at most 600 seconds')
    try:
        saved = process(args.models, args.audio, args.runner, args.history, args.timeout)
        print(f'processing=saved history={saved}; audio=deleted; insertion=not-attempted')
    except (Exception, KeyboardInterrupt) as error:
        # Do not echo runtime output, filenames from exceptions, or transcript content.
        print(f'processing=failed kind={type(error).__name__}; recovery retained where available', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
