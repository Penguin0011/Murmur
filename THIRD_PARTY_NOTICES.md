# Third-party notices

Murmur's own source is covered by the existing [MIT License](LICENSE). Bundled dependency license texts and notices are retained in `app/Licenses/` and copied into `Murmur.app/Contents/Resources/Licenses/` by the build.

The entries below record upstream sources and their verification scope. Bundled license copies are retained in `app/Licenses/`; dates on individual entries describe those checks.

## Bundled in the app

`app/build.sh` copies the `ModelBench` helper into `Murmur.app`. That helper is built from `module-one/models/Runner`, which links FluidAudio. The build also copies FluidAudio's resource bundle when it exists. So FluidAudio ships in binary form inside the app.

### FluidAudio

- Source: https://github.com/FluidInference/FluidAudio
- Pinned revision: `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7` (from `module-one/models/artifact-pins.json` and `module-one/models/Runner/Package.swift`).
- License: Apache License, Version 2.0. Verified from the LICENSE file at the pinned revision: https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/LICENSE
- The LICENSE file has no filled-in copyright line, and there is no NOTICE file at the pinned revision (`NOTICE` returned 404).
- Release duty: include a copy of the Apache-2.0 text with the distributed app.

FluidAudio's package includes these targets, which are linked into the FluidAudio library:

#### fastcluster (via FluidAudio's `FastClusterWrapper` target)

- FluidAudio vendors `Sources/FastClusterWrapper/fastcluster_internal.hpp` from upstream fastcluster. Its header reads: "Until package version 1.1.23: © 2011 Daniel Müllner; All changes from version 1.1.24 on: © Google Inc."
- Upstream license: BSD 2-Clause. Verified at https://github.com/fastcluster/fastcluster/blob/master/LICENSE (upstream master, not a pinned revision).
- Release duty: reproduce the copyright notice, conditions and disclaimer in the documentation of a binary distribution.
- Whether the linker keeps this code in `ModelBench`, which uses only transcription, is unchecked. Including the notice is the safe choice.

#### NemoTextProcessing (via FluidAudio's binary target)

- Prebuilt xcframework from FluidInference/text-processing-rs v0.3.1, per FluidAudio's `Package.swift` at the pinned revision.
- License: Apache-2.0, as declared by the v0.3.1 release's `Cargo.toml`; the exact release `LICENSE`, `NOTICE`, and `THIRD-PARTY-LICENSES.md` are retained in `app/Licenses/Nemo-LICENSE.txt`, `app/Licenses/Nemo-NOTICE.txt`, and `app/Licenses/Nemo-THIRD-PARTY-LICENSES.md`.
- The local Swift 6.4 package dump selected FluidAudio's `Package@swift-6.2.swift`, whose default trait enables `NemoTextProcessing`; build workspace metadata resolves the v0.3.1 xcframework, and the built helper contains FluidAudio `TextNormalizer` symbols.
- These checks do not establish which individual framework components are included in the final executable. Verify that list and its required notices for the exact binary before distribution.

## Downloaded at run time, not bundled

### Parakeet Unified English 0.6B

The model weights are not in the repository or the app bundle. They are downloaded to `~/Library/Caches/Dictation/` from the pinned Hugging Face revision, and file checksums are verified. Settings can download pinned models or use an existing verified model folder.

- Upstream model: `nvidia/parakeet-unified-en-0.6b`, https://huggingface.co/nvidia/parakeet-unified-en-0.6b
  - License: NVIDIA Open Model License Agreement (Hugging Face tag `nvidia-open-model-license`). The card says the model "is ready for commercial/non-commercial use".
  - License text: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/ (last modified October 24, 2025).
  - Section 3 requires anyone who distributes the model or a derivative to include a "Notice" text file with: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License".
- Converted model used by the app: `FluidInference/parakeet-unified-en-0.6b-coreml`, revision `d32e972dd4315f1dc3f6be28fb2aab0ab3e80358`, https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml
  - Its card is tagged `cc-by-4.0`, says "Released under the CC-BY-4.0 license", and names `base_model: nvidia/parakeet-unified-en-0.6b`. It makes no statement about the upstream NVIDIA license.
  - The conversion's CC-BY-4.0 label does not relicense NVIDIA's weights; treat the NVIDIA Open Model License as governing. The differing declarations remain unresolved; review both model cards before redistribution.

Because Murmur downloads the weights rather than redistributing them, the NVIDIA notice duty may not apply to the app itself. The app shows the model license before download, and this notice is reproduced here:

> Licensed by NVIDIA Corporation under the NVIDIA Open Model License

### Parakeet CTC 110M (dictionary support)

Optional download from Settings → Dictionary. It rescores on-device transcripts toward the user's dictionary. It is not bundled; Murmur downloads the pinned files to FluidAudio's model folder (`~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`) and verifies their checksums.

- Upstream model: `nvidia/parakeet-tdt_ctc-110m`, https://huggingface.co/nvidia/parakeet-tdt_ctc-110m. Its Hugging Face card is tagged `cc-by-4.0`.
- Converted model used by the app: `FluidInference/parakeet-ctc-110m-coreml`, revision `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`, https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml. Its card is tagged `cc-by-4.0` and names `base_model: nvidia/parakeet-tdt_ctc-110m`. Both checked October 4, 2026 through the Hugging Face model API.
- License: Creative Commons Attribution 4.0 International, https://creativecommons.org/licenses/by/4.0/. It is recorded in `module-one/models/artifact-pins.json`, so the app shows it as pinned before download.
- Attribution: "Parakeet TDT-CTC 110M" by NVIDIA, converted to Core ML by FluidInference, used under CC BY 4.0. Murmur uses the files unmodified.

### Speaker diarization, pyannote community-1 (speaker separation)

Optional download from Settings → Meetings → "Separate speakers after a meeting". It is not bundled; Murmur downloads the pinned files to `~/Library/Caches/Dictation/module-one/speaker-diarization-df2625a` and verifies their checksums. The helper loads them directly; FluidAudio's own downloader is never used for them.

- Converted models used by the app: `FluidInference/speaker-diarization-coreml`, revision `df2625ac79a7ac6b65ad868fee6d80f320da4232` (the revision FluidAudio `0b1f462` pins in `ModelNames.swift`), https://huggingface.co/FluidInference/speaker-diarization-coreml. Files: `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc` and `plda-parameters.json`, 21 files, 21,599,417 bytes. The legacy online files (`pyannote_segmentation`, `wespeaker*`) and `PLDA.mlmodelc` are not downloaded.
- License: Creative Commons Attribution 4.0 International, https://creativecommons.org/licenses/by/4.0/. The repository's `NOTICE.md` at that revision scopes CC-BY-4.0 to exactly these Community-1-derived files, and its `LICENSE` is the CC-BY-4.0 text. Checked October 16, 2026.
- Upstream: the pyannote speaker-diarization-community-1 pipeline, published by pyannote under CC-BY-4.0, https://huggingface.co/pyannote/speaker-diarization-community-1. The PLDA parameters come from Brno University of Technology / BUT Speech@FIT, licensed CC-BY-4.0 by the rights holder.
- Modification: Fluid Inference converted the PyTorch components to Core ML, fixed and enumerated input shapes, applied mixed-precision storage, separated the FBank frontend from the embedding backend, and compiled them for Apple platforms. Murmur uses the converted files unmodified.
- Attribution, shown in Settings and in the download sheet: "Speaker separation uses modified Core ML conversions by Fluid Inference of the pyannote speaker-diarization-community-1 pipeline (pyannote segmentation, WeSpeaker embeddings) with PLDA parameters from BUT Speech@FIT, licensed under CC-BY-4.0."
- Citations retained from the repository's README:
  - Plaquet, A. and Bredin, H. "Powerset multi-class cross entropy loss for neural speaker diarization." Proc. INTERSPEECH 2023.
  - Wang, H., Liang, C., Wang, S., Chen, Z., Zhang, B., Xiang, X., Deng, Y. and Qian, Y. "Wespeaker: A research and production oriented speaker embedding learning toolkit." ICASSP 2023.
  - Landini, F., Profant, J., Diez, M. and Burget, L. "Bayesian HMM clustering of x-vector sequences (VBx) in speaker diarization: theory, implementation and analysis on standard tasks." Computer Speech & Language, 2022.

## Cloud services

Gemini API and any custom OpenAI-compatible endpoint the user configures are optional services reached with the user's own API keys. No provider code or SDK is bundled; Murmur sends plain HTTPS requests. Their terms apply to the user's account, not to redistribution. See [provider integration](app/PROVIDERS.md) for data flows, and review the selected provider’s current terms.

## Bundled fonts and retained dependency notices

DM Sans and Instrument Serif are bundled under the SIL Open Font License; their license texts are in `app/Fonts/` and ship beside the fonts.

`app/Licenses/` retains FluidAudio's Apache-2.0 text and all five notices from `ThirdPartyLicenses/` at the pinned revision, plus the text-processing-rs v0.3.1 license, NOTICE and dependency list. Including a notice does not imply every optional subsystem is used by Murmur.

Before distributing a binary, review the exact linked Rust dependency license texts and the upstream/conversion model-license mismatch described above. These notices do not resolve ownership questions or grant permissions beyond the upstream licenses.
