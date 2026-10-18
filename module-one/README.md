# Module one — milestone 1 validation

**Standalone validation tooling.** The acceptance gates and measurements below describe the milestone-1 checkpoint, not the current app. Use [the main README](../README.md) to build Murmur and the relevant dated files for historical evidence.

Scope: PRD milestone 1. GO for bounded engineering and validation; production/release remains NO-GO. This module contains standalone tools, not an application skeleton.

## Workstreams

- `capture/` and `session/`: shortcut-driven native recording, local transcription, and durable private text recovery. Connected microphone processing passed with synthetic speaker playback; physical-key first-word preservation and real speech quality remain unverified.
- `models/`: exact artifact/runtime pins and reproducible benchmark tooling. Complete transcription-plus-cleanup measurements on the available Mac remain pending; M1/8 GB performance work is optional and deferred.
- [SAFETY_REVIEW.md](SAFETY_REVIEW.md): independent review of insertion, clipboard, secure-field, shortcut, and correction attribution limits.

This directory contains historical milestone-one validation tooling. Its dated results are not current app release clearance.

## Open acceptance gates

- Real microphone/shortcut first-word and disconnection checks; Fn and configurable binding conflicts.
- Real dictation WER/name/number scoring on genuine labeled 5/30/120-second recordings, peak memory and memory pressure, cold/warm latency, and cleanup corpus quality.
- No duplicate uncertain delivery, durable text recovery before insertion, secure-field and permission-revocation cases, clipboard-manager races, and conservative semantic correction promotion.
- Publish per-app learning limitations from measured configurations; unsupported browser/rich-text/code configurations do not imply that every app in the category fails.

No intervention is requested by this checkpoint. Missing device or permission evidence stays explicitly pending rather than being converted into a passing result.
