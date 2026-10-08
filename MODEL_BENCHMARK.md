# Local transcription comparison — October 6, 2026

## Result

On this initial read-speech sample, the current Parakeet Unified model had the lowest word error rate and matched Parakeet V2's inference speed. Keep Unified as the current choice for now; this small clean-speech comparison is not enough to claim it is best for spontaneous dictation. [Certain]

| Model | Pinned artifact | Micro WER | Macro WER | Word edits / reference words | Exact clips | Median ASR time | P95 ASR time | Transfer size |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Parakeet Unified English 0.6B (current) | `FluidInference/parakeet-unified-en-0.6b-coreml` @ `d32e972dd4315f1dc3f6be28fb2aab0ab3e80358` | **1.34%** | **1.74%** | 29 / 2,172 | 79 / 100 | 62 ms | 149 ms | 1.802 GB [Certain] |
| Parakeet TDT V2 English 0.6B | `FluidInference/parakeet-tdt-0.6b-v2-coreml` @ `ee09c569f73759e6d44c9bd16766f477b2b36d39` | 1.93% | 2.01% | 42 / 2,172 | 77 / 100 | **61 ms** | **100 ms** | 464 MB* [Certain] |
| Whisper large-v3 Turbo (WhisperKit Core ML) | `argmaxinc/whisperkit-coreml` @ `0f63a7800b00dd0226abd051b906c246e1907482` | 2.12% | 2.49% | 46 / 2,172 | 76 / 100 | 1.89 s | 3.98 s | 3.195 GB [Certain] |

Unified made 13 fewer word errors than V2 and 17 fewer than Whisper on these 2,172 words. V2's median ASR time was effectively tied with Unified; Whisper's was about 31 times longer. [Certain]

First process load times were 13.93 s for Unified, 0.27 s for V2, and 208.79 s for Whisper. Do not compare these as cold starts: V2's Core ML compilation had already occurred during a failed first scorer startup, while Whisper's run included first-use compilation. [Certain]

\* V2 size is the required four Core ML bundles plus vocabulary, not the whole repository, which contains additional variants. Transfer sizes are model artifact bytes, not memory use. [Certain]

## Method

- Device: MacBook Air `Mac15,12`, Apple M3, 16 GB RAM; macOS 26.6.2 (25G83). [Certain]
- Dataset: LibriSpeech `test-clean`, licensed CC BY 4.0. The deterministic sample used 100 clips distributed round-robin over all 40 test-clean speakers (seed `10052026`): 13.50 minutes and 2,172 reference words. The clips are clean read audiobook speech, not spontaneous speech or user dictation. [Certain] [Dataset source](https://www.openslr.org/12)
- All three runners processed the same 16 kHz mono WAV files and emitted raw ASR text; no dictionary, cleanup, or insertion stage ran. [Certain]
- WER lowercases and tokenizes with `\w+(?:['’]\w+)?`; punctuation is ignored, but spoken numbers and digit forms are not normalized to one another. Results use micro WER across all reference words; exact clips and macro WER are supplemental. [Certain]
- ASR timings are measured inside each long-lived process after its model is loaded. Unified/V2 report transcription time after their explicit audio conversion; WhisperKit's API timing includes its file loading/conversion. These are backend timings, not end-to-end dictation latency. [Certain]
- Runs were sequential, once per model, in Unified → V2 → Whisper order. Thermal state, power mode, system pressure, ANE utilization, and peak memory were not controlled or measured. Murmur's idle model helper was also running. [Certain]
- Unified and V2 used FluidAudio revision `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7`. WhisperKit used commit `a8a40c9444ae4e7263bd41e5e60b35a92e2cbba3` (tag `v0.9.0`), model files at the pinned revision above, and tokenizer metadata from `openai/whisper-large-v3` revision `06f233fe06e710322aca913c1bc4249a0d71fce1`. [Certain]
- Raw audio, references, transcripts, and per-clip outputs remain in the private cache at `~/Library/Caches/Dictation/asr-benchmark/`; they were not added to the repository. [Certain]

## Interpretation and limits

This first pass favors Unified on WER without a measurable inference-time penalty against V2 on the sample. It does not validate live mic capture, accents beyond this dataset's speakers, noise, names/numbers in realistic dictation, short user commands, or Murmur's end-to-end path. [Certain]

License review was completed October 6, 2026: the NVIDIA upstream model terms and FluidInference's CC-BY-4.0 conversion terms are treated as layered obligations for the derivative. See the app's pre-download disclosure and the licensing note in PRD.md. Any future redistribution must include NVIDIA's agreement and required attribution notice. [Certain]

The runner additions are benchmark-only; the installed app and its default model were not changed. [Certain]
