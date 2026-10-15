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

## Follow-up: chunked offline transcription (October 3, 2026)

A simpler alternative to the streaming encoder: while recording, send finished stretches of audio to the existing warm helper, cut at pauses; on release, transcribe only the last stretch and join. It uses the same offline model, so no new bundle, pins or downloader changes. [Certain]

Measured with a 135 s `say` monologue (414 words, 16 kHz), warm `ModelBench --serve`, joining chunk texts with spaces. The cut is the quietest 0.2 s window within ±5 s of the target. [Certain]

| Split | Chunks | Release wait (last chunk) | WER vs script | Differs from whole-file text |
|---|---|---|---|---|
| Whole file (today) | 1 | 0.97 s | 2.9% | — |
| ~15 s, at pauses | 10 | 0.08 s | 2.9% | 0 words |
| ~25 s, at pauses | 5 | 0.25 s | 2.9% | 0 words |
| ~40 s, at pauses | 4 | 0.08 s | 3.4% | 0.5% |
| ~15 s, blind cut | 9 | 0.14 s | 4.1% | 1.2% |
| ~25 s, blind cut | 6 | 0.07 s | 3.6% | 0.7% |

- **Cutting at pauses matters:** blind cuts split words and add errors; pause cuts at 15–25 s matched the whole-file transcript word for word. [Certain]
- **Release wait** becomes the last chunk's time (under about 0.3 s) instead of growing with length. [Certain]
- **Caveat:** `say` audio has clean, regular pauses. Real speech with background noise and fewer pauses needs a check on real dictations before shipping; keep whole-file offline transcription as the fallback. [Likely]
- **Script:** reproduce with a scratch Python script (stdlib `wave` + the `--serve` protocol); not committed. [Certain]

## Follow-up: cloud cleanup time grows with length (October 3, 2026)

Measured with the app's own request builder (`CleanupPrompt.build` + `GeminiCleanupProvider.makeRequest`, all cleanup options on), Gemini API, two runs each. Transcripts were built from `cleanup-corpus.json` inputs at about 150 words per minute of speech. [Certain]

| Speech length | Words in | Flash-Lite | Gemma 4 (26B A4B) |
|---|---|---|---|
| 15 s | 37 | 0.74 s | 1.4 s |
| 1 min | 150 | 0.97 s | 4.4–7.3 s |
| 2 min | 300 | 1.3 s | 7.9–8.1 s |
| 3 min | 450 | 1.7–1.8 s | 11.3 s |
| 5 min | 750 | 2.2 s | 17.0 s |

- **Flash-Lite** cleanup grows slowly and stays a bit below local transcription time (5 min: 2.2 s cleanup vs 3.3 s transcription). [Certain]
- **Gemma 4** produces about 35 words per second, so long dictations wait 8–17 s once Flash-Lite's daily quota runs out and Murmur fails over. For long messages, this is by far the biggest wait in the pipeline. [Certain]
- **Possible fix:** clean long transcripts in sections of about 100–150 words, sent in parallel, with the guard checking each section, so wall time is close to one section (about 1.5–4 s on Gemma). Risks: a spoken correction or list that spans a section boundary, and per-minute rate limits. Not built. [Likely]
- **Not checked:** whether Gemma still spends tokens on thinking despite `thinkingLevel: minimal`. `usageMetadata.thoughtsTokenCount` in one response would answer it. [Unverified]

## Built: chunked local transcription (October 3, 2026)

- **What:** `Chunker` (`module-one/capture/Capture.swift`) cuts the recording at the quietest 0.2 s within 10–20 s, on the capture queue after the release-cut guard, and writes each chunk to `Application Support/Dictation/chunks` (0700, wiped at launch). `ChunkJob` (`app/Controller.swift`) sends each chunk to the warm helper while recording continues. On release, only the last chunk is left. The full WAV is still written; if any chunk fails, it is transcribed exactly as before. [Certain]
- **Scope:** local transcription only; cloud transcription and the `--test-audio` probe stay whole-file. Recordings were capped at 120 s when this was measured, so the saving was at most about 1 s per dictation (the cap is five minutes since October 6, 2026). [Certain]
- **Measured:** feeding the 135 s synthetic WAV (48 kHz float, 1024-frame buffers) through `Chunker` and `ChunkJob` with the real helper gave 9 chunks, 0.17 s after release (whole file: about 1.0 s), identical words, and no chunk files left. Punctuation differed at 2 of 8 joins (a comma or period). [Certain]
- **Join rule:** a chunk cut at a pause of 0.45 s or more that the model left unpunctuated gets a period. Capitalization is not used as evidence, because every chunk's first word comes back capitalized. The threshold comes from `say` speech (comma pauses 0.2–0.3 s, sentence pauses 0.5–0.7 s) and needs tuning on real voices. [Likely]
- **Failure handling:** a recording's chunks go to the helper one at a time. The first failure drops the rest, so the whole-WAV fallback never waits behind them. [Certain]
- **Not yet verified:** live microphone dictation with real speech and noise. [Unverified]

## Built: ⌃⌘C copies the latest raw transcript

Pressing ⌃⌘C anywhere copies the raw transcript of the latest dictation since launch (held cleanup, held transcript, not inserted, or inserted). The held-cleanup message says so. When transcription itself fails there is no text, only retry audio, so there is nothing to copy. The event tap swallows ⌃⌘C, so other apps never see it. [Certain]

## Cleanup models at the 2-minute cap (October 3, 2026, minimal thinking, 4 rounds over about 5 minutes)

| Model | Typical | Outliers |
|---|---|---|
| gemini-3.5-flash-lite | 1.1–1.3 s | 4.2–5.5 s |
| gemini-3.5-flash | 1.5–1.8 s | one 503 after 38 s, one 429 |
| gemini-3.6-flash | 1.7–2.3 s | 6.6 s, 13.8 s, one 503 after 21 s |
| gemma-4-26b-a4b-it | 7.7–8.1 s | — |

- **Gemma:** reports 0 thinking tokens with `thinkingLevel: minimal`; it is simply slow, at about 44 output tokens per second. [Certain]
- **Middle tier:** Flash 3.5 or 3.6 between Flash-Lite and Gemma would usually take about 2 s instead of 8 s. Failover today triggers only on quota and rate limits, not on 503, so an overloaded middle model would hold a cleanup rather than fail over. Free-tier daily limits per model are shown only in AI Studio. Not built. [Likely]

## Built: parallel sections on the Gemma fallback (October 4, 2026)

When Flash-Lite is rate limited and cleanup goes to Gemma 4, text of 150 words or more is split at sentence ends into sections of about 100 words (`CleanupSections`), cleaned in parallel, and each section is checked by the guard on its own. Spoken lists ("first … second …") stay whole. Flash-Lite still gets the whole text. [Certain]

- **Measured** on a 300-word transcript (the 2-minute cap), two rounds: whole Gemma 7.7–8.0 s, sectioned Gemma 3.2 s. [Certain]
- **Quality:** the sectioned output kept a few fillers and repeats ("like", "the the", "let's, let's") that whole-text Gemma removed. Nothing was added or reworded, and every section passed the guard. [Certain]
- **Rate limits:** about 3 requests per dictation instead of 1. [Certain]

## Live words: memory and contention on the M3 (October 15, 2026)

Measured for BetterWispr gap #13 with a scratch program on the pinned FluidAudio revision: `UnifiedAsrManager` (offline int8, as the helper loads it) and `StreamingUnifiedAsrManager` [70, 13, 13] int8 in one process, fed 25.8 s of `say` speech at 48 kHz in real time (0.1 s buffers). The streaming encoder files were fetched at the pinned revision; the weights' SHA-256 matches `artifact-pins.json` (590,571,264 bytes). [Certain]

- **Memory:** loading the offline model added no wired memory, because the running Murmur helper already had the same Neural Engine program. Loading the streaming encoder added 0.5–1.2 GB of wired memory (it settles near 0.5–0.6 GB), which roughly doubles the model's memory while it is loaded. The process footprint grew only 40–70 MB. Wired-memory readings are system-wide, so they are noisy. [Certain]
- **Load:** 11.3 s the first time (compiling), then 0.07 s. [Certain]
- **Speed:** 23 windows, mean 0.053 s and at most 0.103 s each, against a 1.04 s budget; `finish()` took 0.06 s. Partial text lags speech by about 2 s. [Certain]
- **Contention:** transcribing the same clip offline while streaming ran back to back took 0.21–0.24 s, against 0.19 s alone. [Certain]
- **Accuracy:** the streamed final text matched the offline text except for two punctuation marks. The model never revises an emitted token without vocabulary boosting; only the last word can still grow ("onboard" → "onboarding"). [Certain]

**Proposed approach (not built; awaiting the user):** a short-lived second helper (`ModelBench MODELS --stream RATE`) started at recording start. Audio is fed from its own queue over a pipe, never disk, and dropped when the pipe falls behind. It prints partial lines and exits at release or cancel, so the extra memory is held only while recording; the warm helper is untouched. The streaming encoder gets its own pinned file list, availability check and optional download, so existing installs keep dictating without it. The preview is display only. [Likely]
