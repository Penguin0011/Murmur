#!/usr/bin/env python3
"""Verify the selected Unified batch files against pinned HF metadata, then optionally run a command."""
import hashlib
import json
import pathlib
import subprocess
import sys


def verify(directory, manifest):
    model = manifest['models']['FluidInference/parakeet-unified-en-0.6b-coreml']
    expected = {f['rfilename']: f for f in model['files']}
    for name in model['batch_files']:
        info = expected[name]
        path = directory / name
        if not path.is_file() or path.stat().st_size != info['size']:
            raise ValueError(f'Missing or wrong size: {name}')
        digest = hashlib.sha256() if 'lfs' in info else hashlib.sha1()
        if 'lfs' not in info:
            digest.update(f'blob {info["size"]}\0'.encode())
        with path.open('rb') as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
        checksum = info['lfs']['sha256'] if 'lfs' in info else info['git_blob_sha1']
        if digest.hexdigest() != checksum:
            raise ValueError(f'Checksum mismatch: {name}')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit('Usage: verify_artifacts.py MODEL_DIRECTORY [-- COMMAND ...]')
    verify(pathlib.Path(sys.argv[1]), json.loads(pathlib.Path(__file__).with_name('artifact-pins.json').read_text()))
    print('Pinned Unified batch checksums verified.', file=sys.stderr)
    if len(sys.argv) > 2:
        if sys.argv[2] != '--' or len(sys.argv) < 4:
            raise SystemExit('Expected -- COMMAND ...')
        raise SystemExit(subprocess.call(sys.argv[3:]))
