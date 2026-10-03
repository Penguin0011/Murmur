# Streaming transcription: handoff note

The user asked whether Murmur can transcribe while the user is still recording, so long messages don't wait for the whole clip after release. This note records what was measured and found on October 3, 2026. Nothing is implemented yet. [Certain]

## Where the time goes today

Local route, measured on the M3 with the always-loaded helper (`ModelBench --serve`). Synthetic speech from `say`; numbers are wall time for one request. [Certain]

| Audio length | Warm transcription |
|---|---|
| 2.8 s | 0.08 s |
| 16.3 s | 0.23 s |
| 66.5 s | 0.81 s |
| 133.5 s | 1.67 s |
| 267.4 s | 3.31 s |

- **Scaling:** roughly 1.25 s of transcription per minute of speech, linear.
- **Other fixed costs:** the 0.4 s release tail, a cached model check (about 1 ms), insertion, and the cloud cleanup round trip if one is selected (about 0.8 s Gemini Flash-Lite, about 1.2 s Gemma 4).
- **Short dictations:** streaming would save almost nothing under about 30 s.
- **Long dictations:** for a 2–5 minute message it would remove most of the 1.7–3.3 s spent transcribing after release.

## What the speech library already provides

FluidAudio (pinned revision in `module-one/models/Runner/Package.swift`) ships `StreamingUnifiedAsrManager` for the same Parakeet Unified 0.6B model Murmur uses. Source: `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift`. [Certain]

- **API:**
  - `loadModels(from:)`
  - `appendAudio(_ buffer: AVAudioPCMBuffer)`
  - `processBufferedAudio()`
  - `getPartialTranscript()` and `setPartialTranscriptCallback(_:)`
  - `finish() -> String`
  - `reset()`
- **How it works:** the encoder is stateless and re-encodes a `[left | chunk | right]` window; only the RNNT decoder state carries over. The library says the streamed transcript matches offline output "word-for-word on validation audio". Verify that on Murmur's own audio before relying on it. [Likely]
- **Default context:** `[70, 13, 13]` encoder frames, which is 5.6 s left, 1.04 s chunk and 1.04 s right, about 2.1 s theoretical latency. Other tiers are separate encoder bundles. [Certain]
- **Model files:** it needs a different encoder bundle, `parakeet_unified_encoder_streaming_70_13_13.mlmodelc` (or `_int8`). It is **not** in Murmur's pinned folder (`~/Library/Caches/Dictation/module-one/unified-d32e972`), which has only the offline encoders. It must be added to `module-one/models/artifact-pins.json`, the downloader (`app/ModelDownload.swift`) and `verifyAppModels`, with pinned sizes and hashes. [Certain]
- **Vocabulary boosting:** `configureVocabularyBoosting` exists and could later feed Murmur's dictionary. [Certain]

## Suggested design

1. **Pin and download** the streaming encoder next to the offline files. Keep the offline path as the fallback; per the PRD, nothing silently switches routes.
2. **Extend the warm helper** with a streaming session over stdin. Example: `start`, then raw PCM chunks (or paths to short chunk files), then `finish`. It answers partial lines and a final line. Capture already runs on its own queue (`module-one/capture/Capture.swift`); fan its buffers out to the helper while still writing the WAV, so retry audio and the offline fallback keep working.
3. **On release,** call `finish()` and use its text. If streaming fails or the result looks wrong, transcribe the saved WAV offline as today.
4. **Optional:** show partial text in the indicator. This is a product decision, because the current indicator shows dots only.
5. **Cloud cleanup** still needs the final transcript. Streaming only removes the local transcription wait, not the 0.8–1.2 s cleanup round trip.

## Things to check before building

- **Accuracy:** compare streamed and offline transcripts on a few real long dictations; offline is the quality baseline. [Unverified]
- **CPU and energy:** streaming re-encodes overlapping windows during the whole recording. [Unverified]
- **Interactions with recent fixes:**
  - the shortcut-thread release cut (`Capture.cut(after:)`), which trims audio after a hold's release
  - the early capture for back-to-back dictations
  - the double-press toggle

  The streamed audio must follow the same trimming.
- **Cloud transcription:** Gemini routes stay batch. Their docs offer a separate Live API, which would need its own disclosure review.
