# Third-party notices

Murmur's own source is intended to be MIT-licensed. The LICENSE file is not added yet, because the copyright holder's legal name has not been supplied (PRD section 10, item 4). [Certain]

Licenses below were checked on October 3, 2026 by fetching the listed pages. This file is a record for release, not legal advice. [Certain]

## Bundled in the app

`app/build.sh` copies the `ModelBench` helper into `Murmur.app`. That helper is built from `module-one/models/Runner`, which links FluidAudio. The build also copies FluidAudio's resource bundle when it exists. So FluidAudio ships in binary form inside the app. [Certain]

### FluidAudio

- Source: https://github.com/FluidInference/FluidAudio [Certain]
- Pinned revision: `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7` (from `module-one/models/artifact-pins.json` and `module-one/models/Runner/Package.swift`). [Certain]
- License: Apache License, Version 2.0. Verified from the LICENSE file at the pinned revision: https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/LICENSE [Certain]
- The LICENSE file has no filled-in copyright line, and there is no NOTICE file at the pinned revision (`NOTICE` returned 404). [Certain]
- Release duty: include a copy of the Apache-2.0 text with the distributed app. [Likely]

FluidAudio's package includes these targets, which are linked into the FluidAudio library:

#### fastcluster (via FluidAudio's `FastClusterWrapper` target)

- FluidAudio vendors `Sources/FastClusterWrapper/fastcluster_internal.hpp` from upstream fastcluster. Its header reads: "Until package version 1.1.23: © 2011 Daniel Müllner; All changes from version 1.1.24 on: © Google Inc." [Certain]
- Upstream license: BSD 2-Clause. Verified at https://github.com/fastcluster/fastcluster/blob/master/LICENSE (upstream master, not a pinned revision). [Certain]
- Release duty: reproduce the copyright notice, conditions and disclaimer in the documentation of a binary distribution. [Likely]
- Whether the linker keeps this code in `ModelBench`, which uses only transcription, is unchecked. [Guessing] Including the notice is the safe choice.

#### NemoTextProcessing (via FluidAudio's binary target)

- Prebuilt xcframework from FluidInference/text-processing-rs v0.3.1, per FluidAudio's `Package.swift` at the pinned revision. [Certain]
- License: Apache-2.0, as declared on https://github.com/FluidInference/text-processing-rs. I checked the repository's current page, not the v0.3.1 tag. [Likely for v0.3.1]
- `Package.swift` says it is always linked on Swift tools before 6.2, and that `Package@swift-6.2.swift` makes it an opt-out trait. Whether the Mac build (Swift 6.3.3) links it by default is unchecked. [Guessing]

## Downloaded at run time, not bundled

### Parakeet Unified English 0.6B

The model weights are not in the repository or the app bundle. They are downloaded to `~/Library/Caches/Dictation/` from the pinned Hugging Face revision, and file checksums are verified. Today the model folder is chosen manually; the in-app downloader is in progress. [Certain]

- Upstream model: `nvidia/parakeet-unified-en-0.6b`, https://huggingface.co/nvidia/parakeet-unified-en-0.6b [Certain]
  - License: NVIDIA Open Model License Agreement (Hugging Face tag `nvidia-open-model-license`). The card says the model "is ready for commercial/non-commercial use". [Certain]
  - License text: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/ (last modified October 24, 2025). [Certain]
  - Section 3 requires anyone who distributes the model or a derivative to include a "Notice" text file with: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License". [Certain]
- Converted model used by the app: `FluidInference/parakeet-unified-en-0.6b-coreml`, revision `d32e972dd4315f1dc3f6be28fb2aab0ab3e80358`, https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml [Certain]
  - Its card is tagged `cc-by-4.0`, says "Released under the CC-BY-4.0 license", and names `base_model: nvidia/parakeet-unified-en-0.6b`. It makes no statement about the upstream NVIDIA license. [Certain]
  - The conversion's CC-BY-4.0 label does not relicense NVIDIA's weights; treat the NVIDIA Open Model License as governing. [Likely] This mismatch is unresolved, as MODEL_RESEARCH.md notes. [Certain]

Because Murmur downloads the weights rather than redistributing them, the NVIDIA notice duty may not apply to the app itself. [Guessing] The PRD still requires the app to show the model license before download, and this notice is reproduced here:

> Licensed by NVIDIA Corporation under the NVIDIA Open Model License

### Parakeet CTC 110M (dictionary support)

Optional download from Settings → Dictionary. It rescores on-device transcripts toward the user's dictionary. It is not bundled; Murmur downloads the pinned files to FluidAudio's model folder (`~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`) and verifies their checksums. [Certain]

- Upstream model: `nvidia/parakeet-tdt_ctc-110m`, https://huggingface.co/nvidia/parakeet-tdt_ctc-110m. Its Hugging Face card is tagged `cc-by-4.0`. [Certain]
- Converted model used by the app: `FluidInference/parakeet-ctc-110m-coreml`, revision `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`, https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml. Its card is tagged `cc-by-4.0` and names `base_model: nvidia/parakeet-tdt_ctc-110m`. [Certain] Both checked October 4, 2026 through the Hugging Face model API. [Certain]
- License: Creative Commons Attribution 4.0 International, https://creativecommons.org/licenses/by/4.0/. It is recorded in `module-one/models/artifact-pins.json`, so the app shows it as pinned before download. [Certain]
- Attribution: "Parakeet TDT-CTC 110M" by NVIDIA, converted to Core ML by FluidInference, used under CC BY 4.0. Murmur uses the files unmodified. [Likely]

### Speaker diarization, pyannote community-1 (speaker separation)

Optional download from Settings → Meetings → "Separate speakers after a meeting" (PRD 11.8, W7d). It is not bundled; Murmur downloads the pinned files to `~/Library/Caches/Dictation/module-one/speaker-diarization-df2625a` and verifies their checksums. The helper loads them directly; FluidAudio's own downloader is never used for them. [Certain]

- Converted models used by the app: `FluidInference/speaker-diarization-coreml`, revision `df2625ac79a7ac6b65ad868fee6d80f320da4232` (the revision FluidAudio `0b1f462` pins in `ModelNames.swift`), https://huggingface.co/FluidInference/speaker-diarization-coreml. Files: `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc` and `plda-parameters.json`, 21 files, 21,599,417 bytes. The legacy online files (`pyannote_segmentation`, `wespeaker*`) and `PLDA.mlmodelc` are not downloaded. [Certain]
- License: Creative Commons Attribution 4.0 International, https://creativecommons.org/licenses/by/4.0/. The repository's `NOTICE.md` at that revision scopes CC-BY-4.0 to exactly these Community-1-derived files, and its `LICENSE` is the CC-BY-4.0 text. Checked October 16, 2026. [Certain]
- Upstream: the pyannote speaker-diarization-community-1 pipeline, published by pyannote under CC-BY-4.0, https://huggingface.co/pyannote/speaker-diarization-community-1. The PLDA parameters come from Brno University of Technology / BUT Speech@FIT, licensed CC-BY-4.0 by the rights holder. [Certain]
- Modification: Fluid Inference converted the PyTorch components to Core ML, fixed and enumerated input shapes, applied mixed-precision storage, separated the FBank frontend from the embedding backend, and compiled them for Apple platforms. Murmur uses the converted files unmodified. [Certain]
- Attribution, shown in Settings and in the download sheet: "Speaker separation uses modified Core ML conversions by Fluid Inference of the pyannote speaker-diarization-community-1 pipeline (pyannote segmentation, WeSpeaker embeddings) with PLDA parameters from BUT Speech@FIT, licensed under CC-BY-4.0." [Certain]
- Citations retained from the repository's README:
  - Plaquet, A. and Bredin, H. "Powerset multi-class cross entropy loss for neural speaker diarization." Proc. INTERSPEECH 2023.
  - Wang, H., Liang, C., Wang, S., Chen, Z., Zhang, B., Xiang, X., Deng, Y. and Qian, Y. "Wespeaker: A research and production oriented speaker embedding learning toolkit." ICASSP 2023.
  - Landini, F., Profant, J., Diez, M. and Burget, L. "Bayesian HMM clustering of x-vector sequences (VBx) in speaker diarization: theory, implementation and analysis on standard tasks." Computer Speech & Language, 2022.

## Cloud services

Gemini API and any custom OpenAI-compatible endpoint the user configures are optional services reached with the user's own API keys. No provider code or SDK is bundled; Murmur sends plain HTTPS requests. Their terms apply to the user's account, not to redistribution. [Certain] See `app/PROVIDERS.md` for data-use terms.
