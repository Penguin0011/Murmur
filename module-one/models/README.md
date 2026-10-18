# Model verification and benchmarks

Run commands from the repository root. `artifact-pins.json` records immutable revisions, file sizes and checksums. The app uses the local ModelBench helper built from `Runner/`; model weights are downloaded separately. See [third-party notices](../../THIRD_PARTY_NOTICES.md) for licensing and the [read-speech benchmark](../../MODEL_BENCHMARK.md) for a measured comparison and its limitations.

## Runnable checks and preparation

```sh
python3 module-one/models/check_benchmark.py
swift build --package-path module-one/models/Runner -c release
```

The Swift build downloads runtime/package dependencies, not model weights. Supply a separately downloaded, pinned Unified model directory; resolve URLs use `https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/resolve/d32e972dd4315f1dc3f6be28fb2aab0ab3e80358/<file>` for each `batch_files` entry.

Use the verifier wrapper before loading; it fails closed on any missing file, wrong size, or checksum mismatch.

```sh
python3 module-one/models/verify_artifacts.py /absolute/model-directory -- \
  python3 module-one/models/benchmark.py /absolute/corpus.jsonl -- \
  module-one/models/Runner/.build/release/ModelBench /absolute/model-directory '{audio}' \
  > /absolute/results.jsonl
```

JSONL corpus records use `{"id":"name-5s","audio":"recordings/name-5s.wav","reference":"I called Morgan at 5."}`; paths are relative to the corpus file, audio is uncompressed PCM WAV, and IDs must be unique. Include real 5/30/120-second dictation, silence, accent/name/number/negation/noise cases; do not score synthetic TTS as dictation evidence. Record machine model, RAM, macOS, microphone, audio conditions, open apps, power mode, and model directory provenance alongside results.

Runner output separates load, audio preparation, first inference, and second inference using the same loaded manager. The harness measures whole child wall time, CPU time and child-process peak RSS, raw output and simple punctuation/case-insensitive word edit distance; silent references use null WER plus emitted-word counts. WER uses this harness's normalization, not NVIDIA/FluidAudio's normalizer, so published WER is not directly comparable.

The child RSS metric excludes external Core ML/ANE service memory and is not total system memory; cold/warm here refers to model load/first versus repeated inference within one process, not cache-cleared OS launches. ANE utilization, memory pressure, energy, end-to-end cleanup/insertion latency, sentence omissions and repeated-process statistics still need device measurement.

## Single-file inference

Append `--single` to `ModelBench MODEL_DIRECTORY AUDIO_FILE` to return one JSON record with text, load, audio preparation and first-inference timings. Verify model integrity before invoking the runner.

`check_benchmark.py` exercises synthetic scoring, command failure, timeout, WAV duration/resource collection and missing/corrupted artifacts. Raw output can contain transcript text; keep it private. The harness and verifier make no network requests, but an external command supplied to the harness may do so.
