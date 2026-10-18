# Transcription model selection

**Dated development record.** Statements, task instructions and validation limits below apply to their recorded checkpoints. They are not current release clearance or authorization to merge or change settings. See [README.md](README.md) for current setup.

Research date: October 2, 2026. This is desk research, not a benchmark run on our minimum hardware.

## Selected default

Select **NVIDIA `parakeet-unified-en-0.6b`** for local English transcription, using the **FluidInference Core ML conversion through FluidAudio's Swift runtime**, initially in batch mode after recording stops. This is the project selection; shipped artifact/version selection remains subject to validation.

It is the strongest fit among the researched choices for English accuracy, speed, and native Apple Silicon integration. That judgment is an inference from published results, not proof on M1/8 GB.

## What the reference tools use

| Tool | Verified model/runtime choices |
|---|---|
| OpenWhispr | Current main-branch documentation lists Whisper through whisper.cpp; Parakeet V3 and Unified English; Nemotron English/multilingual streaming; and Cohere Transcribe through sherpa-onnx. These are source-documented choices, not independently verified installed-release behavior. ([source](https://github.com/OpenWhispr/openwhispr/blob/main/CLAUDE.md)) |
| Handy | Public model docs recommend Parakeet V3, list English-only V2 and SenseVoice, and discuss Whisper, Moonshine, Canary, and GigaAM. Docs describe Parakeet as CPU-only in that implementation and Whisper as Metal-accelerated on macOS; this does not mean Parakeet cannot use Apple's Neural Engine through another runtime. ([docs](https://handy.computer/docs/models)) |
| Superwhisper | Offers local Parakeet V2/V3, Cohere Transcribe, and Whisper variants, plus a separate optional language-model stage. Its on-device comparison is measured on M4, not M1. ([models and methodology](https://superwhisper.com/models)) |
| MacParakeet | Source documents FluidAudio/Core ML Parakeet V2/V3/Unified and Cohere, alongside WhisperKit Turbo and Nemotron. Published results include comparable English accuracy and Mac speed/memory measurements. ([source and benchmarks](https://github.com/moona3k/macparakeet#asr-benchmarks)) |
| Wispr Flow | Official documentation says transcription runs in the cloud. The examined documentation does not establish a downloadable local checkpoint we can reuse; do not assume its name means it uses an unmodified Whisper model. ([privacy](https://wisprflow.ai/privacy)) |

## Accuracy evidence

NVIDIA's same-table evaluation reports normalized offline English WER of **5.91% for Unified**, **6.04% for Parakeet V2**, and **6.92% for Nemotron English** across the stated OpenASR datasets. Lower WER is better; Unified's V2 improvement is modest, not transformational. Unified includes punctuation/capitalization, although the cited WER table excludes their scoring. ([model card](https://huggingface.co/nvidia/parakeet-unified-en-0.6b))

MacParakeet reports full LibriSpeech test-clean/test-other macro WER: ([benchmark](https://github.com/moona3k/macparakeet#asr-benchmarks))

| Model | Macro WER |
|---|---:|
| Cohere Transcribe q8 | 2.07% |
| Parakeet Unified | 2.38% |
| Parakeet V2 | 2.57% |
| Whisper large-v3 turbo | 3.00% |
| Parakeet V3 | 3.22% |

These are different benchmark suites; do not compare the NVIDIA percentages directly with this table or call either one our dictation error rate. Read-speech accuracy alone does not settle accents, names, spontaneous corrections, or noise.

## Speed and hardware evidence

MacParakeet's M4 Pro/48 GB microbenchmark reports Parakeet V2/V3/Unified as a family at roughly **81–93× real time**, Whisper Turbo at **14×**, and Cohere q8 at **11×**, with Cohere around **11.6 GB peak process RSS**. These are runtime-specific measurements, not universal model memory requirements, and process RSS alone does not establish total Core ML/ANE memory. ([benchmark](https://github.com/moona3k/macparakeet#asr-benchmarks))

FluidAudio separately reports Unified batch throughput of **123.3×** on full LibriSpeech test-clean on an M5 Pro, versus **29.1×** for its streaming configuration. These figures exclude our cleanup/insertion path and cannot predict M1 end-to-end latency. ([runtime benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md))

## Why the alternatives are not the default

- **V2:** strong English baseline and useful fallback comparator, but Unified has better published English results and built-in punctuation.
- **V3:** Handy's sensible multilingual default; our English-first product gains little from automatic multilingual detection compared with Unified's English results.
- **Whisper Turbo:** useful broader-language alternative, but the comparable Mac evidence does not justify its slower path as our English default.
- **Cohere Transcribe:** stronger published accuracy, but the measured Mac runtime's startup/memory cost is a poor default for 8 GB and rapid dictation. Revisit as an optional accuracy mode on higher-memory hardware.
- **Nemotron:** suited to streaming; live partial transcripts are not a launch requirement, so its extra streaming tradeoff is unnecessary here.
- **Parakeet Ultra/Phonon-2:** examined newer TDT variants. FluidAudio reports Ultra improving V3 at similar speed and Phonon-2 trading some English accuracy for speed. Neither examined report establishes superiority over Unified on our target task/hardware. ([Ultra](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md), [Phonon-2](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Phonon2.md))

## Implementation and release gates

1. Pin the FluidAudio revision and exact converted model artifacts/checksums. Verify the Unified APIs and complete download footprint rather than borrowing sizes from ONNX or GGUF variants.
2. Benchmark real 5/30/120-second English dictation on M1/8 GB, including model loading, silence, sentence omissions, accents, names/numbers, noise, CPU/ANE usage, energy, and memory pressure. Measure final-output latency with local cleanup enabled and common apps open.
3. Keep batch decoding initially. Streaming is an optimization only if measurements show batch misses the approved latency target; do not sacrifice accuracy for partial text the product does not need.
4. Prove custom-dictionary and learned-term behavior through the selected pipeline. Do not assume TDT-specific vocabulary boosting automatically works with Unified's RNNT decoder. Conservative processing-stage term correction is a candidate, subject to the existing no-unrelated-substitution checks.
5. Resolve license metadata before redistribution: NVIDIA's upstream card lists the NVIDIA Open Model License, while the converted Core ML card labels CC-BY-4.0. Do not treat conversion metadata as permission to relicense upstream weights. FluidAudio itself identifies Apache-2.0. The app's own source remains MIT; preserve dependency/model notices separately. ([upstream](https://huggingface.co/nvidia/parakeet-unified-en-0.6b), [conversion](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml), [runtime](https://github.com/FluidInference/FluidAudio))

This selects the **transcription model**, not a cleanup language model or cloud provider. Filler removal, spoken-correction interpretation, list formatting, and personalization remain separate product logic; the local cleanup model still needs a targeted quality/memory comparison.
