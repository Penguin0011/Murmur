# Documentation guide

Murmur is a pre-release source project. Building the app, publishing its source and distributing a production binary have different verification requirements; a successful build is not a completed live release test. [Certain]

## Start here

| Document | Purpose |
| --- | --- |
| [README](README.md) | Current requirements, source build, first run, privacy boundaries and data removal. [Certain] |
| [Contributing](CONTRIBUTING.md) | Toolchain/SDK setup, offline checks, synthetic UI fixtures, signing and contribution conventions. [Certain] |
| [App reference](app/README.md) | Processing, configuration, fixture flags and dated implementation evidence; run commands from the repository root. [Certain] |
| [Security](SECURITY.md) | Private reporting guidance, secret scanning and development-data precautions. [Certain] |
| [License](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md) | Existing source license, bundled notices and unresolved model/binary redistribution checks. [Certain] |
| [Vocabulary behavior](app/VOCABULARY.md) and [app contributor rules](app/AGENTS.md) | The preserved transcription/dictionary policy, implementation details and regression checks. [Certain] |
| [Product context](PRODUCT.md) and [design system](DESIGN.md) | Product constraints and the in-repository visual/interaction specification. [Certain] |
| [Font notes](app/Fonts/README.md) | Bundled font sources and adjacent license texts. [Certain] |

## Requirements and development evidence

These records explain decisions and measured results. Dates, commits and test configurations bound their claims; earlier “not implemented,” PASS/FAIL, merge instructions or pending tasks are historical, not the current release status or new authorization to act. Local evidence paths identify original artifacts and are not files a new contributor must have. [Certain]

| Document | Scope |
| --- | --- |
| [PRD](PRD.md) | Requirements, proposals, superseding decisions and release acceptance criteria; implementation is not implied by a requirement. [Certain] |
| [Development handoff](HANDOFF.md) | October 2–6 checkpoints, installations and then-open issues. [Certain] |
| [Feature comparison](BETTERWISPR_GAPS.md) | October 14 comparison and work plan against pinned source revisions. [Certain] |
| [Streaming investigation](STREAMING_TRANSCRIPTION.md) | October 3–15 investigation, then implemented chunked transcription and live preview. [Certain] |
| [Model research](MODEL_RESEARCH.md) and [benchmark](MODEL_BENCHMARK.md) | Dated selection rationale and bounded read-speech measurements, not current market rankings or spontaneous-dictation guarantees. [Certain] |
| [Provider research](app/PROVIDERS.md) | Dated external API, pricing and data-use research; recheck official provider terms before use. [Certain] |
| [Insertion review](app/INSERTION_REVIEW.md) and [visual verification](VISUAL_VERIFICATION.md) | October 5 delivery/recovery review and measured synthetic UI results; retain their unrun live cases. [Certain] |
| [PR #45 test plan](PR45_TEST_HANDOFF.md) and [results](PR45_TEST_RESULTS.md) | Vocabulary-policy evaluation and follow-ups. PR #45 was subsequently merged; historical test verdicts remain bounded by their evidence. [Certain] |
| [Security remediation record](security_best_practices_report.md) | October 5 audit and remediation, not a continuously refreshed security certification. [Certain] |
| [UI development record](.impeccable/surfaces/app-ui-swift.md) | October 16 implementation and fixture checks supporting the design system. [Certain] |

## Standalone probes and model tooling

These tools share some code with the app but have their own storage and behavior. The READMEs distinguish synthetic checks from commands that observe fields, listen for shortcuts, record audio or insert text. Use disposable fields and synthetic content for live probes. [Certain]

- [Feasibility spike](spike/README.md) and [dated feasibility report](spike/FEASIBILITY.md). [Certain]
- [Milestone-one overview](module-one/README.md) and [dated interaction-safety review](module-one/SAFETY_REVIEW.md). [Certain]
- [Capture harness](module-one/capture/README.md), [shortcut/session harness](module-one/session/README.md) and [model validation tooling](module-one/models/README.md). [Certain]

## Before a production binary release

The source-publication review does not clear binary redistribution. Resolve exact prebuilt dependency notices/composition and any model-weight redistribution rights; use Developer ID signing and notarization; verify microphone/call capture, permissions, secure fields, insertion/recovery, clipboard interactions and each offered provider route on the intended release build. Publish only the compatibility and performance results actually measured. [Certain]
