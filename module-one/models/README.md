# Module one: model validation checkpoint

The complete transcription + cleanup pipeline on the available Mac remains unverified. M1/8 GB performance work is deferred by user decision and does not block development or release. [Certain]

## Exact artifacts and API

`artifact-pins.json` records live Hugging Face immutable repository revisions, byte sizes, LFS SHA-256 checksums, and Git blob SHA-1 IDs for non-LFS files; weights have not been downloaded. [Certain] [Hugging Face metadata API](https://huggingface.co/docs/hub/api#get-apimodelsrepoidrevisionrevision)

FluidAudio is pinned to `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7`. Its batch Unified API is `UnifiedAsrManager()` → `loadModels(from:)` → `transcribe(AVAudioPCMBuffer)` returning `String`; the current conversion-card `fromHub()` / `result.text` example differs from this pinned source. [Certain] [Pinned manager](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/Unified/UnifiedAsrManager.swift)

The manager computes mel features in Swift, defaults to INT8, constrains the INT8 encoder to CPU+ANE when configured `.all`, and can fall back to FP16 on load failure. [Certain] The selected batch manifest therefore contains both encoders plus decoder, single-step joint, vocab, metadata/config; their total is **1,801,783,964 bytes** (~1.80 GB decimal), compared with **11,249,362,739 bytes** for the complete multi-variant conversion repository. [Certain] These are transfer-file totals, not measured installed/working memory. [Certain] [Pinned loader](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/Unified/UnifiedAsrManager.swift)

The manifest also snapshots V2 (`ee09c569f73759e6d44c9bd16766f477b2b36d39`, complete repository 2,575,138,422 bytes) and WhisperKit's `openai_whisper-large-v3_turbo` subset (`0f63a7800b00dd0226abd051b906c246e1907482`, 3,195,115,988 bytes). [Certain] V2 includes legacy/alternative bundles; this total is not its eventual selected download footprint. [Certain] Neither comparator has an executable adapter here yet. [Certain] [V2 source](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/tree/ee09c569f73759e6d44c9bd16766f477b2b36d39), [WhisperKit source](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-large-v3_turbo)

Upstream Unified metadata lists NVIDIA Open Model License, while FluidInference conversion metadata lists CC-BY-4.0. [Certain] This checkpoint does not resolve the discrepancy or authorize redistribution; release stays gated on correct license/notices. [Certain] [Upstream](https://huggingface.co/nvidia/parakeet-unified-en-0.6b), [conversion](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml)

## Runnable checks and preparation

```sh
python3 module-one/models/check_benchmark.py
swift build --package-path module-one/models/Runner -c release
```

The Swift build downloads runtime/package dependencies, not model weights. [Certain] Supply a separately downloaded, pinned Unified model directory; resolve URLs use `https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/resolve/d32e972dd4315f1dc3f6be28fb2aab0ab3e80358/<file>` for each `batch_files` entry. [Certain]

Use the verifier wrapper before loading; it fails closed on any missing file, wrong size, or checksum mismatch. [Certain]

```sh
python3 module-one/models/verify_artifacts.py /absolute/model-directory -- \
  python3 module-one/models/benchmark.py /absolute/corpus.jsonl -- \
  module-one/models/Runner/.build/release/ModelBench /absolute/model-directory '{audio}' \
  > /absolute/results.jsonl
```

JSONL corpus records use `{"id":"name-5s","audio":"recordings/name-5s.wav","reference":"I called Aakash at 5."}`; paths are relative to the corpus file, audio is uncompressed PCM WAV, and IDs must be unique. [Certain] Include real 5/30/120-second dictation, silence, accent/name/number/negation/noise cases; do not score synthetic TTS as dictation evidence. Record machine model, RAM, macOS, microphone, audio conditions, open apps, power mode, and model directory provenance alongside results.

Runner output separates load, audio preparation, first inference, and second inference using the same loaded manager. [Certain] The harness measures whole child wall time, CPU time and child-process peak RSS, raw output and simple punctuation/case-insensitive word edit distance; silent references use null WER plus emitted-word counts. [Certain] WER uses this harness's normalization, not NVIDIA/FluidAudio's normalizer, so published WER is not directly comparable. [Certain]

The child RSS metric excludes external Core ML/ANE service memory and is not total system memory; cold/warm here refers to model load/first versus repeated inference within one process, not cache-cleared OS launches. [Certain] ANE utilization, memory pressure, energy, end-to-end cleanup/insertion latency, sentence omissions and repeated-process statistics still need device measurement. [Certain]

## Cleanup and cloud follow-up

Begin with deterministic/no-model cleanup as the quality/control baseline, then a small instruct-model candidate only after its exact quantized artifact/runtime and corpus are pinned; no local LLM has passed quality/memory acceptance here. [Certain]

Fireworks documents hosted Whisper speech transcription, including `whisper-v3-turbo` through its audio endpoint. [Certain] [Official guide](https://docs.fireworks.ai/guides/querying-asr-models)

OpenRouter now documents a dedicated `POST /api/v1/audio/transcriptions`, in addition to audio chat input; its provider-specific privacy/retention still needs route-by-route review. [Certain] This corrects the prior assumption that OpenRouter would only be a cleanup route. [Certain] [Official transcription tutorial](https://openrouter.ai/blog/tutorials/transcription-on-openrouter/), [privacy](https://openrouter.ai/privacy)

Gemini documents audio understanding/transcription, but different current official pages describe different inline size limits; implementation must verify the selected API path's limit rather than treating a search snippet as authoritative. [Certain] [Audio guide](https://ai.google.dev/gemini-api/docs/audio), [Google file-limit announcement](https://blog.google/innovation-and-ai/technology/developers-tools/gemini-api-new-file-limits/)

These are endpoint capability findings, not verified provider integrations; exact pricing/models, retention, API keys, real request/error/cancellation checks, and cleanup-corpus comparisons remain open. [Certain]

## Verification at this checkpoint

`check_benchmark.py` passes synthetic scoring, command failure, timeout, WAV duration/resource collection, and missing/corrupted model integrity checks; these do not establish inference quality. [Certain] The harness defaults to a 300-second per-utterance timeout (`--timeout` overrides it) and writes raw dictation/reference text locally to stdout, so keep output files private and outside commits. [Certain] The harness and verifier send no telemetry/network requests; the external command's behavior is the tester's responsibility. [Certain]

The Swift release build was attempted and stopped after roughly two minutes while downloading the 87,267,919-byte NemoTextProcessing dependency artifact; compilation and the Swift runner are **unverified**. [Certain] Its interface was checked against pinned upstream source, but a successful build and real inference are still required before calling the adapter operational. [Certain]
