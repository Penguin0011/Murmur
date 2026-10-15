# PR #45 test results

**Overall: FAIL — the handoff's no-loss spelling criterion is not met.** A fresh run completed all 30 audio pairs and six real guarded-cleanup calls on the correct candidate. All deterministic checks, the build, and strict signature verification passed. [Certain]

## Decision

Keep PR #45 unmerged pending a decision on the Faithful-mode spelling regression. Preserve the user-selected no-prompt/no-deletion policy while evaluating that regression; this test makes no production changes and does not authorize restoring the old prompt or filter.

Removing the prompt eliminated unspoken dictionary additions on the six direct silence/noise calls, but neither arm added vocabulary during the 24 speech calls. Faithful exact preferred spellings fell from A 18/18 to B 6/18. Standard guarded cleanup recovered B to 18/18 word spellings ignoring capitalization, and 16/18 exact preferred spellings including capitalization. [Certain]

## Provenance and environment

- Candidate actually compiled and tested: `fb555574108ba55d6f41f1966246df89d1046b0d`; baseline request builder extracted directly from `b19124b3dbded1d74407ebc1afc529a780f6afa0`. The candidate contains `ba5f5e2`. [Certain]
- Repository: `/Users/aakash/.codex/worktrees/833a/Murmur`; date: October 14, 2026, America/Los_Angeles; macOS 27.0.1, Apple Swift 6.4. [Certain]
- A locally modified completed report appeared during this request. It and its synthetic audio evidence were preserved under `prior-results-file.md` and `prior-audio-evidence/` before this independent rerun. The metrics below come from the fresh run, not the older report or the stale-checkout run. [Certain]
- Initial dirty state: only `PR45_TEST_RESULTS.md` modified; production source files remained identical to the candidate throughout this run. [Certain]
- Local evidence directory: `/Users/aakash/.codex/worktrees/833a/Murmur/runtime/pr45-validation-20261014-230047`. It contains source harnesses, generated audio, per-call results, request audits, command lists, environment metadata, and logs. [Certain]
- Transcription: configured Custom Provider, `api.groq.com`, model `whisper-large-v3-turbo`, language `en`, temperature `0`, response format `json`. Both arms used the configured destination-bound `.customTranscription` credential through `CustomAPIKeyBinding.read`; no binding override or preference change was used. [Certain]
- Cleanup: configured `api.cerebras.ai`, `gpt-oss-120b`, destination-bound `.customCleanup` credential, explicitly selected Standard options in an isolated processor. The live cleanup measurements do not cover Polish or Professional. [Certain]
- Audio: eight freshly generated Samantha macOS TTS fixtures, PCM16 mono 16 kHz WAV; C02 has five seconds of appended silence before normal preprocessing. C09 is two seconds of digital silence; C10 is two seconds of seeded low-level noise. No private History, microphone recording, or existing user dictionary was used. [Certain]
- Freshly built executable SHA-256: `096a2a79ae4cfdf74b0d3d190542aae4cc3cda44289a03b881ff3c257cebdae5`. The installed app was neither replaced nor used as the measured cloud test harness. [Certain]

## Commands and checks

Exact commands and source lists: `commands.txt` in the evidence directory. Every command below exited 0; actual output is retained in the corresponding log and `.exit` file. [Certain]

| Check | Result | Evidence file |
|---|---|---|
| Provider requests/transport/disclosures | PASS, 592 assertions. [Certain] | `providers.log` |
| Routes and correction integration | PASS, 169 checks. [Certain] | `routes.log` |
| Processing | PASS, 132 checks. [Certain] | `processing.log` |
| Dictionary/learning | PASS, 177 checks. [Certain] | `dictionary.log` |
| Cleanup | PASS, 425-utterance suite; 2,349/2,349 adversarial outputs rejected; 2,685/2,685 punctuation transfers preserved words. [Certain] | `cleanup.log` |
| Optimized app/helper build | PASS. [Certain] | `build.log` |
| Strict signature verification | PASS. [Certain] | `signature.log` |
| Harness preflight | PASS; exact request comparison, isolated correction checks, zero silent-fixture uploads. [Certain] | `preflight.log` |
| Diff whitespace check | PASS. [Certain] | `diff-check.log` |

The checks confirm preservation of spoken names/lists on custom, Gemini LLM and Gemini ASR routes, Gemini structured vocabulary, manual and learned variants without cleanup, preferred-only mock cleanup correction, and correction on mocked provider failure. [Certain]

## Controlled audio method

`Validate.swift` uses the real candidate provider/request builder and an exact extracted baseline `BaselineTranscriptionFormat.swift`. Before sending, it verifies for all ten fixtures that request URL, headers, and multipart body are identical after deleting A's exact prompt part. A sends `Vocabulary: Aakash, spaceyboi, Shelfmate.`; B has no prompt field. [Certain]

Each fixture was prepared once with candidate `CloudAudio.prepare`; identical prepared bytes were reused in every A/B pair. Pair order was AB, BA, AB for each clip. Calls were paced 3.5 seconds apart plus request time. All 60 requests returned HTTP 200; there were zero failures, retries, exclusions, or hash mismatches. [Certain]

Raw text was captured before output filtering, dictionary correction, or cleanup. Both arms were then scored with the same isolated candidate Faithful processor: manual `Aakash` / `Akash`, learned `spaceyboi` / `spacey boy`, preferred-only learned `Shelfmate`. The old output filter was deliberately excluded from raw-ASR measurement. [Certain]

## Results

| Metric | A: original prompt | B: no prompt |
|---|---:|---:|
| Unspoken dictionary additions during speech, C01–C08 | 0/24 [Certain] | 0/24 [Certain] |
| No-hint ordinary-speech subset, C01–C02 | 0/6 [Certain] | 0/6 [Certain] |
| Unspoken dictionary additions on direct silence/noise calls | 6/6 [Certain] | 0/6 [Certain] |
| Multi-term dictionary lists on direct silence/noise | 5/6 [Certain] | 0/6 [Certain] |
| Unspoken literal “Vocabulary” label on silence/noise | 0/6 [Certain] | 0/6 [Certain] |
| Any nonblank direct silence/noise response | 6/6 [Certain] | 6/6 [Certain] |
| Raw rare-term exact preferred spellings, C07/C08 | 12/18 [Certain] | 0/18 [Certain] |
| Raw rare-term spellings ignoring case | 12/18 [Certain] | 3/18 [Certain] |
| Faithful dictionary exact preferred spellings | 18/18 [Certain] | 6/18 [Certain] |
| Faithful dictionary spellings ignoring case | 18/18 [Certain] | 9/18 [Certain] |

All six B rare-term outputs were additionally sent through real Standard model cleanup: 16/18 exact preferred spellings and 18/18 ignoring case; six of six outputs passed the guard without fallback or provider error. A was not sent through model cleanup, so this is a measurement of B's recovery path, not a paired cleanup comparison. [Certain]

The two exact-case misses were `shelfmate` instead of `Shelfmate`; the other previously misheard words were recovered. Faithful-mode losses include genuine spelling differences, not only capitalization. [Certain]

## Concrete observations

- C07 A: `Send the Shelfmate report to Akash and spaceyboi.` Faithful correction supplies `Aakash`. [Certain]
- C07 B: `Send the shelfmate report to Akash and Spassyboy.` Faithful correction supplies `Aakash` but leaves `Spassyboy`; Standard model cleanup recovers `spaceyboi`, with `shelfmate` lowercased in two of three outputs. [Certain]
- C08 B: `Please ask Akash to call Spassyboy about Shelfmet.` Faithful fixes only `Akash`; all three Standard cleanup outputs become `Please ask Aakash to call spaceyboi about Shelfmate.` [Certain]
- C09 A returns `Aakash, spaceyboi, Sselfmate.`; B returns `Thank you.` C10 B returns `.`; A includes unspoken dictionary names in every response, sometimes only `Aakash`. [Certain]
- For C09/C10 the normal candidate `CloudTranscription.run` returns `.noSpeech(skipped: true)` with **zero uploads**. Thus the direct-provider hallucination reduction was measured on fixtures the app normally skips, and does not reproduce the original long-dictation echo. [Certain]
- C03–C06 raw outputs retain spoken names/list content with spelling differences. Route regression tests verify the candidate does not delete that content; no real app insertion was attempted. [Certain]

## Evidence map and limits

- `fresh-calls.jsonl`: 60 timestamped raw HTTP-200 transcription results, clip/repetition/order, host/model/parameters and prepared hashes. [Certain]
- `fresh-cleanup.jsonl`: six B cleanup provider outputs, final texts, guard/fallback and safe provider-error fields. [Certain]
- `request-audit-live.json`: source/prepared audio hashes, durations, exact prompt-only request comparison, and normal-route silent upload counts. [Certain]
- `references.json`, `audio/`, `Validate.swift`, `BaselineTranscriptionFormat.swift`, `score.py`, `summary.json`, `live.log`: reproducible synthetic corpus, harness and scoring evidence. [Certain]
- Spelling scores use whole-word preferred forms; exact scores include capitalization and separate case-insensitive scores exclude it. Echo classification was checked against the actual synthetic references and unique outputs, not just a substring matching the word “vocabulary.” [Certain]

One synthetic voice, one transcription model/provider, and one cleanup mode do not establish general human-speech or provider-wide accuracy. No original failing recording, physical microphone, UI insertion, Polish/Professional cleanup, or WER benchmark was tested. [Certain] The run establishes both a silence/noise prompt-echo mechanism and a Faithful spelling cost on this corpus; it does not establish that prompt removal fixes the historical long-dictation tail. [Certain]

## State and summary

Production code, real dictionary/history/settings, installed app and normal running app were not changed. Only this report and linked review notes are intended repository edits; bulky synthetic evidence stays local in the directory above. [Certain] PR #45 must remain unmerged for the user to review these results.

**Recommendation:** treat the test as a completed failure of the no-loss acceptance criterion, not a build or regression-suite failure. Retain the user-selected no-prompt/no-deletion implementation while deciding how to handle useful rare spellings in Faithful mode. Standard cleanup recovered all tested word spellings, but cannot be assumed available in Faithful mode or on cleanup failure. [Certain]
