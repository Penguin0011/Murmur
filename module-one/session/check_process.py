"""Synthetic fault checks; no speech, models, or microphone access."""
import json
import os
from pathlib import Path
import stat
import tempfile
import time
from unittest.mock import patch
import process

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    history = root / 'history'
    runner = root / 'runner'
    runner.write_text('#!/usr/bin/env python3\nprint(\'{"text":"Synthetic recovery.","cold_transcribe_seconds":0.1}\')\n')
    runner.chmod(0o700)
    audio = root / 'sample.wav'
    audio.write_bytes(b'synthetic placeholder')
    # Failing the model integrity boundary must prevent runner invocation and retain audio.
    try:
        process.process(root / 'missing-models', audio, runner, history)
    except (ValueError, FileNotFoundError):
        pass
    else:
        raise AssertionError('Missing models must fail')
    assert audio.exists() and not history.exists()
    with patch.object(process, 'verify_models', return_value=None):
        with patch.object(process, 'save_transcript', side_effect=OSError('disk full')):
            try:
                process.process(root, audio, runner, history)
            except OSError:
                pass
            else:
                raise AssertionError('Disk-full error must propagate')
        assert audio.exists(), 'Save failure must retain audio'
        saved = process.process(root, audio, runner, history)
        assert not audio.exists()
        record = json.loads(saved.read_text())
        assert record['raw_text'] == record['final_text'] == 'Synthetic recovery.'
        assert record['insertion_status'] == 'saved-not-inserted'
        assert stat.S_IMODE(saved.stat().st_mode) == 0o600
        assert stat.S_IMODE(history.stat().st_mode) == 0o700
        audio.write_bytes(b'synthetic placeholder')
        runner.write_text('#!/usr/bin/env python3\nimport time\ntime.sleep(10)\n')
        try:
            process.process(root, audio, runner, history, timeout=0.02)
        except process.subprocess.TimeoutExpired:
            pass
        else:
            raise AssertionError('Runner timeout must fail')
        assert audio.exists()
    stamp = record['recorded_at']
    process.purge_history(history, now=stamp + 30 * 86400 - 1)
    assert saved.exists()
    process.purge_history(history, now=stamp + 30 * 86400)
    assert not saved.exists()
print('Session recovery checks passed (integrity rejection, disk failure, timeout, durable save, permissions, retention).')

# Deliver termination during process creation: the handler must defer cancellation
# until Popen returns a handle, then reap the child rather than orphaning it.
real_popen = process.subprocess.Popen
spawned = []
def interrupted_spawn(*args, **kwargs):
    child = real_popen(*args, **kwargs)
    spawned.append(child)
    os.kill(os.getpid(), process.signal.SIGTERM)
    return child
with tempfile.TemporaryDirectory() as directory:
    sleeper = Path(directory) / 'sleeper'
    sleeper.write_text('#!/usr/bin/env python3\nimport time\ntime.sleep(10)\n')
    sleeper.chmod(0o700)
    with patch.object(process.subprocess, 'Popen', side_effect=interrupted_spawn):
        try:
            process.run_transcription(sleeper, Path(directory), Path('synthetic'), 1)
        except InterruptedError:
            pass
        else:
            raise AssertionError('Signal during spawn must cancel')
    assert spawned[0].poll() is not None, 'Canceled runner must be reaped'
print('Signal-during-spawn cancellation check passed.')
